"""Judge failures must neither park exhausted workers nor become training labels."""
import io
import json
import os
import tempfile
import unittest
import urllib.error
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack, redirect_stdout
from pathlib import Path
from unittest.mock import patch

from pipeline import llm
from pipeline import judge


QUESTIONS = {'q': {'type': 'choice', 'instructions': 'Is it supported?',
                   'criteria': {'yes': 'Supported', 'no': 'Unsupported'}}}
ANSWERS = {'q': {'type': 'choice', 'choice': 'yes', 'probabilities': {'yes': 0.9, 'no': 0.1}}}
FREE_ANSWER = {'results': [{'dimensions': {'d0': {'label': 'yes',
                                                'scores': {'yes': 0.9, 'no': 0.1}}}}]}


def limited(seconds='59'):
    return urllib.error.HTTPError('https://example.invalid', 429, 'limited',
                                  {'Retry-After': seconds}, io.BytesIO(b'{"error":"busy"}'))


class ScriptedOpener:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.calls = []

    def open(self, request, **kwargs):
        self.calls.append((request, kwargs))
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        if callable(response):
            response = response(request)
        return io.BytesIO(json.dumps(response).encode())


class JudgeClient(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        directory = self.stack.enter_context(tempfile.TemporaryDirectory())
        self.stack.enter_context(patch.dict(os.environ, {'JEV_ROUTE': 'paid', 'DATA_DIR': directory}, clear=True))
        self.stack.enter_context(patch.object(llm, '_env', side_effect=lambda name:
            'unit-test-secret' if name in {'LLM_API_KEY', 'VERCEL_AI_GATEWAY_KEY', 'CLASSIFIER_KEY'} else None))
        self.stack.enter_context(patch.object(llm.random, 'random', return_value=0))
        self.sleep = self.stack.enter_context(patch.object(llm.time, 'sleep'))
        self.teacher = self.stack.enter_context(patch.object(llm, '_teacher_log'))
        self.stack.enter_context(patch.object(llm, '_free_breaker', llm._Breaker('test', fails=1)))
        self.output = io.StringIO()
        self.stack.enter_context(redirect_stdout(self.output))

    def use(self, *responses):
        opener = ScriptedOpener(*responses)
        self.stack.enter_context(patch.object(llm, '_opener', return_value=opener))
        return opener

    def test_explicit_zero_retries_overrides_default_without_final_sleep(self):
        opener = self.use(limited())
        with self.assertRaises(llm.LLMError):
            llm.jev('state', QUESTIONS, retries=0)
        self.assertEqual(len(opener.calls), 1)
        self.sleep.assert_not_called()

    def test_lower_environment_retry_count_is_honored(self):
        os.environ['JEV_RETRIES'] = '1'
        opener = self.use(limited(), limited())
        with self.assertRaises(llm.LLMError):
            llm.jev('state', QUESTIONS)
        self.assertEqual(len(opener.calls), 2)
        self.sleep.assert_called_once_with(59)
        log = self.output.getvalue()
        self.assertIn('HTTP 429', log)
        self.assertIn('等待=59.0s', log)
        self.assertNotIn('unit-test-secret', log)
        self.assertNotIn('Authorization', log)

    def test_success_after_retry_is_validated_and_logged_once(self):
        self.use(limited('2'), {'answers': ANSWERS})
        self.assertEqual(llm.jev('state', QUESTIONS, retries=1), ANSWERS)
        self.teacher.assert_called_once_with('state', QUESTIONS, ANSWERS)
        self.sleep.assert_called_once_with(2)
        self.assertIn('已恢复', self.output.getvalue())

    def test_timeout_exhaustion_has_no_final_sleep(self):
        opener = self.use(TimeoutError('timeout'))
        with self.assertRaises(llm.LLMError):
            llm.jev('state', QUESTIONS, retries=0)
        self.assertEqual(len(opener.calls), 1)
        self.sleep.assert_not_called()

    def test_free_long_retry_advice_falls_back_immediately(self):
        os.environ['JEV_ROUTE'] = 'free-then-paid'
        opener = self.use(limited('59'), {'answers': ANSWERS})
        self.assertEqual(llm.jev('state', QUESTIONS, retries=0), ANSWERS)
        self.assertEqual(len(opener.calls), 2)
        self.assertTrue(llm._free_breaker.open())
        self.sleep.assert_not_called()

    def test_free_exhaustion_has_no_final_sleep(self):
        opener = self.use(limited('1'))
        with self.assertRaises(llm.LLMError):
            llm.jev_free('state', QUESTIONS, retries=0)
        self.assertEqual(len(opener.calls), 1)
        self.sleep.assert_not_called()

    def test_free_valid_response_keeps_wire_contract(self):
        self.use(FREE_ANSWER)
        got = llm.jev_free('state', QUESTIONS, retries=0)
        self.assertEqual(got['q']['choice'], 'yes')
        self.assertEqual(got['q']['probabilities'], {'yes': 0.9, 'no': 0.1})

    def test_free_batches_honor_serialized_unicode_dimension_limit(self):
        # Astral characters occupy two JavaScript string units; quotes and slashes are escaped
        # in JSON. Counting plain question lengths would materially undercount this workload.
        instruction = ('甲😀"\\\n' * 300)
        questions = {f'q{i}': {**QUESTIONS['q'], 'instructions': instruction + str(i)} for i in range(7)}

        def answer(request):
            dimensions = json.loads(request.data)['dimensions']
            return {'results': [{'dimensions': {key: {'label': 'yes', 'scores': {'yes': 0.9, 'no': 0.1}}
                                                for key in dimensions}}]}

        opener = self.use(*([answer] * 7))
        got = llm.jev_free('state', questions, retries=0)
        self.assertEqual(set(got), set(questions))
        self.assertGreater(len(opener.calls), 1)
        instructions = []
        for request, _ in opener.calls:
            dims = json.loads(request.data)['dimensions']
            serialized = json.dumps(dims, ensure_ascii=False)
            self.assertLessEqual(len(serialized.encode('utf-16-le')) // 2, 16_000)
            self.assertLessEqual(len(dims), 20)
            instructions.extend(d['instructions'].split('\nChoose one label:\n')[0] for d in dims.values())
        self.assertEqual(instructions, [q['instructions'] for q in questions.values()])

    def test_free_batches_preserve_twenty_dimension_limit(self):
        questions = {f'q{i}': QUESTIONS['q'] for i in range(41)}
        batches = llm._classifier_batches(questions)
        self.assertEqual([len(keys) for keys, _ in batches], [20, 20, 1])

    def test_free_serialized_dimension_boundary_is_inclusive(self):
        questions = {f'q{i}': {**QUESTIONS['q'], 'instructions': '甲' * 3000 if i < 4 else ''}
                     for i in range(5)}
        dims = llm._classifier_batches(questions)[0][1]
        overhead = len(json.dumps(dims, ensure_ascii=False).encode('utf-16-le')) // 2
        questions['q4']['instructions'] = '甲' * (16_000 - overhead)
        dims = llm._classifier_batches(questions)[0][1]
        self.assertEqual(len(json.dumps(dims, ensure_ascii=False).encode('utf-16-le')) // 2, 16_000)
        questions['q4']['instructions'] += '甲'
        self.assertEqual([len(keys) for keys, _ in llm._classifier_batches(questions)], [4, 1])

    def test_free_instruction_limit_is_checked_before_submission(self):
        question = {**QUESTIONS['q'], 'instructions': '甲' * 4000}
        with self.assertRaisesRegex(llm.LLMError, '4000'):
            llm._classifier_batches({'q': question})

    def test_long_guard_note_is_kept_in_state_with_short_instructions(self):
        note = 'The story so far. ' * 300
        answer = {'g1': {'choice': 'supported', 'probabilities':
                         {'supported': .9, 'beyond_text': .1, 'contradicted': 0}}}
        with patch.object(judge, 'jev', return_value=answer) as call:
            got = judge.guard_texts('source passage', {}, {'saga': note})
        state, questions = call.call_args.args
        self.assertEqual(state['note_g1'], note)
        self.assertNotIn(note, questions['g1']['instructions'])
        self.assertLess(len(questions['g1']['instructions']), 4000)
        self.assertEqual(got['saga']['verdict'], 'ok')

    def test_oversized_single_dimension_goes_paid_without_partial_free_calls(self):
        os.environ['JEV_ROUTE'] = 'free-then-paid'
        questions = {'small': QUESTIONS['q'], 'large': {**QUESTIONS['q'], 'instructions': '甲' * 16_000}}
        answers = {key: ANSWERS['q'] for key in questions}
        opener = self.use({'answers': answers})
        self.assertEqual(llm.jev('state', questions, retries=0), answers)
        self.assertEqual(len(opener.calls), 1)
        self.assertEqual(opener.calls[0][0].full_url, llm.JEV_URL)

    def test_missing_paid_answers_are_not_logged_as_training_labels(self):
        for response in ({}, {'answers': {}}, [], {'error': 'failed'},
                         {'answers': {'other': ANSWERS['q']}}):
            with self.subTest(response=response):
                self.use(response)
                with self.assertRaises(llm.LLMError):
                    llm.jev('state', QUESTIONS, retries=0)
        self.teacher.assert_not_called()
        self.sleep.assert_not_called()

    def test_invalid_paid_scores_are_rejected(self):
        for scores in ({}, {'yes': float('nan')}, {'yes': float('inf')},
                       {'yes': -0.1}, {'yes': 1.1}, {'yes': True},
                       {'yes': '0.9'}, {'yes': 0, 'no': 0}, {'yes': 0.9, 'unexpected': 0.1}):
            with self.subTest(scores=scores):
                self.use({'answers': {'q': {'choice': 'yes', 'probabilities': scores}}})
                with self.assertRaises(llm.LLMError):
                    llm.jev('state', QUESTIONS, retries=0)
        self.teacher.assert_not_called()

    def test_malformed_or_missing_free_dimensions_are_rejected(self):
        for response in ({}, {'results': []}, {'results': [{'dimensions': {}}]},
                         {'results': [{'dimensions': {'d0': []}}]}):
            with self.subTest(response=response):
                self.use(response)
                with self.assertRaises(llm.LLMError):
                    llm.jev_free('state', QUESTIONS, retries=0)

    def test_chat_exhaustion_has_no_final_sleep(self):
        self.use(TimeoutError('timeout'))
        with self.assertRaises(llm.LLMError):
            llm.chat('test-model', [{'role': 'user', 'content': 'test'}], retries=0)
        self.sleep.assert_not_called()

    def test_retry_after_dates_and_invalid_values(self):
        with patch.object(llm.time, 'time', return_value=0):
            self.assertEqual(llm._retry_after({'Retry-After': 'Thu, 01 Jan 1970 00:00:05 GMT'}, 0), 5)
        for value in ('nonsense', 'NaN', 'inf'):
            self.assertEqual(llm._retry_after({'Retry-After': value}, 0), 0.5)
        self.assertIsNone(llm._retry_after({'Retry-After': '120'}, 0, cap=60))


class Breaker(unittest.TestCase):
    def test_cooldown_allows_only_one_recovery_probe(self):
        breaker = llm._Breaker('test', fails=1, cool=10)
        with patch.object(llm.time, 'time', return_value=100), redirect_stdout(io.StringIO()):
            breaker.failed()
            self.assertFalse(breaker.allow())
        with patch.object(llm.time, 'time', return_value=111):
            with ThreadPoolExecutor(12) as pool:
                admissions = list(pool.map(lambda _: breaker.allow(), range(40)))
            self.assertEqual(sum(admissions), 1)
            with redirect_stdout(io.StringIO()):
                breaker.failed()
            self.assertFalse(breaker.allow())
        with patch.object(llm.time, 'time', return_value=122), redirect_stdout(io.StringIO()):
            self.assertTrue(breaker.allow())
            breaker.ok()
            self.assertTrue(breaker.allow())


class TeacherLog(unittest.TestCase):
    def test_parallel_writes_are_complete_and_have_one_state(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(os.environ, {'JUDGE_LOG_DIR': directory, 'JUDGE_LOG': '1'}), \
                patch.object(llm._teacher_log, 'seen', set()):
            state = {'this_passage': '甲' * 5000}
            with ThreadPoolExecutor(12) as pool:
                list(pool.map(lambda _: llm._teacher_log(state, QUESTIONS, ANSWERS), range(60)))
            states = [json.loads(line) for line in (Path(directory) / 'states.jsonl').read_text().splitlines()]
            rows = [json.loads(line) for line in (Path(directory) / 'questions.jsonl').read_text().splitlines()]
            self.assertEqual(len(states), 1)
            self.assertEqual(len(rows), 60)
            self.assertEqual({row['state'] for row in rows}, {states[0]['h']})
            self.assertTrue(all(row['choice'] == 'yes' for row in rows))

    def test_state_deduplication_is_scoped_to_log_directory(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(llm._teacher_log, 'seen', set()):
            for child in ('one', 'two'):
                path = Path(directory) / child
                with patch.dict(os.environ, {'JUDGE_LOG_DIR': str(path), 'JUDGE_LOG': '1'}):
                    llm._teacher_log('same state', QUESTIONS, ANSWERS)
                self.assertTrue((path / 'states.jsonl').exists())

    def test_failed_state_write_is_visible_and_remains_retryable(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(os.environ, {'JUDGE_LOG_DIR': directory, 'JUDGE_LOG': '1'}), \
                patch.object(llm._teacher_log, 'seen', set()):
            output = io.StringIO()
            with patch('builtins.open', side_effect=PermissionError('test')), redirect_stdout(output):
                llm._teacher_log('state', QUESTIONS, ANSWERS)
            self.assertIn('训练日志写入失败', output.getvalue())
            self.assertEqual(llm._teacher_log.seen, set())
            llm._teacher_log('state', QUESTIONS, ANSWERS)
            self.assertTrue((Path(directory) / 'states.jsonl').exists())


if __name__ == '__main__':
    unittest.main()
