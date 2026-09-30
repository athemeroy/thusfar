"""Deterministic calls for Python oracle helpers missed by existing fixtures."""

from __future__ import annotations

import threading
import unittest

from pipeline.judge import read_families
from pipeline.kg import KG
from pipeline.link import _resolve_hint
from pipeline.run import Runner, attr_facts


def person(pid: str, name: str, first: int, *, importance: int = 2) -> dict:
    return {
        'id': pid,
        'name': name,
        'aliases': {name},
        'weak': set(),
        'first': first,
        'last_seg': 1,
        'imp': importance,
        'gender': '女',
        'intro': '初次登场',
        'tagline': '',
    }


def bare_runner() -> Runner:
    """Construct only the state read by these helpers; no disk or model work."""
    runner = Runner.__new__(Runner)
    runner.book = {'lang': 'zh', 'blocks': [{'o': 0, 't': '贾宝玉与宝玉来到园中。'}]}
    runner.kg = KG(runner.book)
    runner.kg.seg = 2
    runner.works = []
    runner.dedupe_seen = set()
    runner.desc_pairs = set()
    runner.lock = threading.RLock()
    return runner


class OraclePureCoverageTests(unittest.TestCase):
    def test_kg_describe_uses_tagline_then_intro(self):
        kg = KG({'lang': 'zh', 'blocks': []})
        kg.people['P1'] = person('P1', '贾宝玉', 1)
        self.assertEqual(kg.describe('P1'), '贾宝玉（初次登场）')
        kg.people['P1']['tagline'] = '荣府公子'
        self.assertEqual(kg.describe('P1'), '贾宝玉（荣府公子）')

    def test_known_name_hint_prefers_canonical_id_then_unique_name(self):
        kg = KG({'lang': 'zh', 'blocks': []})
        kg.people['P1'] = person('P1', '贾宝玉', 1)
        kg.people['P1']['aliases'].add('宝玉')
        kg.people['P2'] = dict(person('P2', '旧称', 2), merged_into='P1')
        kg.people['P3'] = person('P3', '林黛玉', 3)
        self.assertEqual(_resolve_hint(kg, {'known': 'P2', 'known_name': '宝玉'}, {}), 'P1')
        self.assertEqual(
            _resolve_hint(kg, {'known': 'P2', 'known_name': '林黛玉'}, {'林黛玉': {'P3'}}),
            'P3',
        )
        self.assertIsNone(
            _resolve_hint(kg, {'known': 'P2', 'known_name': '林黛玉'}, {'林黛玉': {'P1', 'P3'}})
        )

    def test_dedupe_candidates_invokes_nested_names_without_a_model(self):
        runner = bare_runner()
        runner.kg.people['P1'] = person('P1', '贾宝玉', 1)
        runner.kg.people['P2'] = person('P2', '贾宝玉', 11)
        pairs, dossiers = runner._dedupe_candidates(20, 0)
        self.assertEqual(pairs, [['P2', 'P1']])
        self.assertEqual(set(dossiers), {'P1', 'P2'})

    def test_dossiers_selects_active_cast_and_current_attributes(self):
        runner = bare_runner()
        runner.kg.people['P1'] = person('P1', '贾宝玉', 1, importance=3)
        runner.kg.log = [
            {'t': 'event', 'p': 10, 'who': ['P1'], 'text': '宝玉来到园中', 'imp': 2},
            {'t': 'attr', 'p': 12, 'id': 'P1', 'key': '住处', 'value': '荣府'},
        ]
        dossier, chosen = runner._dossiers(20, 0)
        self.assertEqual(chosen, ['P1'])
        self.assertIn('住处：荣府', dossier)
        self.assertIn('宝玉来到园中', dossier)

    def test_earlier_saga_uses_strict_cutoff_and_fallback(self):
        runner = bare_runner()
        runner.kg.log = [
            {'t': 'saga', 'p': 20, 'text': '第一段前情'},
            {'t': 'saga', 'p': 40, 'text': '第二段前情'},
        ]
        self.assertEqual(runner.earlier_saga(20, '无前情'), '无前情')
        self.assertEqual(runner.earlier_saga(40, '无前情'), '第一段前情')
        self.assertEqual(runner.earlier_saga(41, '无前情'), '第二段前情')

    def test_attr_facts_filters_empty_values_and_resolves_people(self):
        people = {'P1': ('贾宝玉', '荣府公子'), 'P2': ('林黛玉', '寄居荣府')}

        def who_of(pid: str) -> tuple[str, str]:
            return people[pid]

        data = {'attrs': [
            {'who': 'P1', 'key': '住处', 'value': '荣府'},
            {'who': 'P1', 'key': '空值', 'value': ''},
            {'who': 'P2', 'key': '籍贯', 'value': '姑苏'},
        ]}
        self.assertEqual(attr_facts(data, who_of), {
            '0': ('贾宝玉', '荣府公子', '住处', '荣府'),
            '2': ('林黛玉', '寄居荣府', '籍贯', '姑苏'),
        })

    def test_describe_factory_covers_known_and_new_people(self):
        runner = bare_runner()
        runner.kg.people['P1'] = person('P1', '贾宝玉', 1)
        describe = runner._describe_factory(
            {'new_people': [{'ref': 'N1', 'name': '林黛玉', 'intro': '初到荣府'}]},
            {'refmap': {'N1': 'P2'}},
        )
        self.assertEqual(describe('P1'), '贾宝玉（初次登场）')
        self.assertEqual(describe('P2'), '林黛玉（初到荣府）')
        self.assertEqual(describe('P9'), '（本段新出场）')

    def test_read_families_records_nonempty_tuple_key(self):
        answers = {'f1': {'probabilities': {'friend': 0.4, 'kin': 0.75, 'none': 0.1, 'other': 0.34}}}
        self.assertEqual(read_families(answers, [('P1', 'P2')]), {
            ('P1', 'P2'): [('kin', 0.75), ('friend', 0.4)],
        })


if __name__ == '__main__':
    unittest.main()
