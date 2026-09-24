"""The training set has to look like what the judge is actually served.

Every check here is a bug we shipped once. They run on synthetic data in a second, no model and no
network, because the failures they catch are invisible in every metric until the thing is deployed:
a model trained on one input format and served another still produces confident numbers, they are
just wrong.
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'scripts'))

from export_judge_data import (anchors, canonical_work, decision_id, focus, from_logs,
                               read_log, shared, state_text, work_of)  # noqa: E402
from gliclass_data import labels_of, phrase_of  # noqa: E402
from judge_server import criteria_of  # noqa: E402
from pipeline.llm import _state_text  # noqa: E402


class StateFormat(unittest.TestCase):
    def test_export_matches_what_the_pipeline_sends(self):
        """Trained on `{"this_passage": …}` and served `[this_passage]\\n…` is a silent disaster."""
        for state in ({'this_passage': '甲乙丙'},
                      {'this_passage': 'x', 'known_characters': ['A', 'B']},
                      {'passages': [{'t': 'a'}], 'note': ''},
                      'already a string'):
            self.assertEqual(state_text(state), _state_text(state))


class Windowing(unittest.TestCase):
    def test_finds_what_the_claim_borrowed_from_the_passage(self):
        # a claim is written in the extractor's own words, so the whole sentence never matches
        passage = '甲' * 900 + '去看悉德·菲尔德的书，他开创了编剧理论。' + '乙' * 900
        ask = 'is this supported? CLAIM: 作者提及悉德·菲尔德是开创编剧理论的大师'
        self.assertIn('悉德·菲尔德', shared('作者提及悉德·菲尔德是开创编剧理论的大师', passage))
        win = focus(passage, ask, 300)
        self.assertIn('悉德·菲尔德', win)
        self.assertLess(len(win), len(passage))

    def test_keeps_the_people_the_question_names(self):
        passage = '丙' * 1200 + '张三对李四说话。' + '丁' * 1200
        ask = 'In this_passage, what kind of tie is between 「张三」 (A) and 「李四」 (B)?'
        self.assertEqual(sorted(anchors(ask, passage)), ['张三', '李四'])
        win = focus(passage, ask, 200, cap=800)
        self.assertIn('张三', win)
        self.assertIn('李四', win)

    def test_no_anchor_keeps_the_passage_rather_than_its_opening(self):
        """Truncating from the start turns a supported claim into an unsupported one."""
        passage = '戊' * 2000
        win = focus(passage, 'CLAIM: 完全不相干的说法', 300, cap=1500)
        self.assertEqual(len(win), 1500)


class Splits(unittest.TestCase):
    def test_full_evidence_and_options_distinguish_questions(self):
        common = 'same beginning ' * 60
        self.assertNotEqual(decision_id('q', common + 'alive', {'a': 'yes'}),
                            decision_id('q', common + 'dead', {'a': 'yes'}))
        self.assertNotEqual(decision_id('q', common, {'a': 'yes'}),
                            decision_id('q', common, {'a': 'no'}))
    def test_reruns_of_one_book_are_one_work(self):
        """Directory names differ per run; putting v9 in test and v10 in train measures memory."""
        names = ['包法利夫人（关系树 v11）', '包法利夫人（裁判做关系 v9）', '包法利夫人（flash-lite 全流程）']
        self.assertEqual(len({work_of(n) for n in names}), 1)
        self.assertNotEqual(work_of('儒林外史'), work_of('包法利夫人'))


class Labels(unittest.TestCase):
    def test_options_become_english_sentences(self):
        """Measured on our judge experiments: natural English separates the classes 3x better than our keys,
        and Chinese labels do worse than English ones even on Chinese text."""
        self.assertEqual(phrase_of('supported', 'whatever'), 'the passage supports this')
        self.assertEqual(phrase_of('kin', 'They are family by blood (parent, child)'),
                         'They are family by blood')

    def test_two_options_never_collapse_into_one_label(self):
        shown, back = labels_of({'a': 'same words', 'b': 'same words'})
        self.assertEqual(len(set(shown)), 2)
        self.assertEqual(set(back.values()), {'a', 'b'})

    def test_round_trip_through_the_wire_format(self):
        """What the pipeline sends → what the model sees → back to the pipeline's own keys."""
        options = {'supported': 'The passage states it.',
                   'not_in_passage': 'The passage does not say.',
                   'contradicted': 'The passage says otherwise.'}
        # this is exactly the shape pipeline.llm.jev_free puts on the wire
        instructions = ('Judging only this_passage: is this supported? CLAIM: 张三是李四的哥哥\n'
                        'Choose one label:\n' + '\n'.join(f'- {k}: {v}' for k, v in options.items()))
        got, question = criteria_of(list(options), instructions)
        self.assertEqual(got, options)
        self.assertNotIn('Choose one label', question)
        shown, back = labels_of(got)
        self.assertEqual(sorted(back.values()), sorted(options))
        self.assertEqual(shown[0], 'the passage supports this')


class LogIntegrity(unittest.TestCase):
    def test_missing_state_is_not_exported_as_empty_passage(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            logs = d / 'work/judge'
            logs.mkdir(parents=True)
            (logs / 'states.jsonl').write_text('')
            q = {'state': 'missing', 'instructions': 'q', 'criteria': {'yes': 'yes'},
                 'choice': 'yes', 'probabilities': {'yes': 1}}
            (logs / 'questions.jsonl').write_text(json.dumps(q) + '\n')
            with self.assertRaisesRegex(ValueError, '不存在的原文'):
                from_logs(d, {'book': 'fixture'}, [])

    def test_corrupt_interior_line_is_not_silently_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'log.jsonl'
            p.write_text('{}\nbroken\n{}\n')
            with self.assertRaisesRegex(ValueError, '日志损坏'):
                list(read_log(p))


if __name__ == '__main__':
    unittest.main()
