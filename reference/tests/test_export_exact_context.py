"""Captured teacher labels must remain bound to the complete input they judged."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    'export_exact_test', Path(__file__).resolve().parents[1] / 'scripts/export_judge_data.py')
export = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(export)


class ExactTeacherContextTests(unittest.TestCase):
    def export_fixture(self, state, radius):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            log = root / 'work/judge'
            log.mkdir(parents=True)
            (log / 'states.jsonl').write_text(json.dumps({'h': 'state', 'state': state}) + '\n')
            q = {'state': 'state', 'instructions': 'Judge the note. NOTE: tail evidence.',
                 'criteria': {'supported': 'Established', 'missing': 'Absent'},
                 'choice': 'supported', 'probabilities': {'supported': .9, 'missing': .1}}
            (log / 'questions.jsonl').write_text(json.dumps(q) + '\n')
            rows = []
            export.from_logs(root, {'book': 'fixture'}, rows, radius)
            return rows[0], q

    def test_zero_window_keeps_tail_beyond_old_cap(self):
        original = 'x' * 13000 + ' decisive tail evidence'
        row, q = self.export_fixture(original, 0)
        self.assertEqual(row['passage'], original)
        self.assertTrue(row['context_exact'])
        self.assertEqual(row['original_passage_sha256'], hashlib.sha256(original.encode()).hexdigest())
        self.assertEqual(row['teacher_input_sha256'],
                         export.decision_id(q['instructions'], original, q['criteria']))

    def test_cropped_context_is_explicitly_unverified(self):
        original = 'x' * 13000 + ' decisive tail evidence'
        row, q = self.export_fixture(original, 300)
        self.assertNotEqual(row['passage'], original)
        self.assertFalse(row['context_exact'])
        self.assertNotEqual(row['teacher_input_sha256'],
                            export.decision_id(q['instructions'], row['passage'], q['criteria']))

    def test_structured_state_preserves_all_sections_and_order(self):
        state = {'characters': 'Hamlet', 'this_passage': 'Horatio enters.', 'notes': ['evidence']}
        row, _ = self.export_fixture(state, 0)
        self.assertEqual(row['passage'], export.state_text(state))
        self.assertIn('[this_passage]\nHoratio enters.', row['passage'])
        self.assertTrue(row['context_exact'])


if __name__ == '__main__':
    unittest.main()
