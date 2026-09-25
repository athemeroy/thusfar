"""Print deterministic link, dedupe, and spoiler-scrub outputs for one hash seed."""

import json
from types import SimpleNamespace
from unittest.mock import patch

from pipeline.extract import segments
from pipeline.kg import KG
from pipeline.link import link_segment, proper_name, to_classic
from pipeline.parse import finish
from tests.test_oracle_pure_coverage import bare_runner, person


def probe():
    proper = proper_name({
        'name': '*unknown',
        'aliases': {'Alice', 'Clara', 'Ellen', 'Maria'},
    })
    classic = to_classic({
        'people': [{'id': '1', 'name': '', 'names': ['Alice', 'Maria']}],
        'events': [], 'facts': [], 'rels': [],
    }, {'1': {'to': None}})['new_people'][0]['name']

    cast = {f'P{i}': {
        'name': 'Alex', 'aliases': {'Alex'}, 'weak': set(),
        'first': 0, 'mentions': 1, 'gender': '',
    } for i in range(1, 8)}
    kg = SimpleNamespace(people=cast, canon=lambda pid: pid, k=1)
    captured = []

    def ask(questions, *_args):
        captured.append(questions[0][2])
        return {'1': {'choice': 'new', 'p': 1.0}}

    with patch('pipeline.link._ask_jev', side_effect=ask), \
         patch('pipeline.link.verify_names', return_value=({}, {})):
        link_segment(kg, {}, {'people': [{'id': '1', 'name': 'Alex', 'names': []}]}, 'Alex')

    runner = bare_runner()
    for index in range(1, 6):
        runner.kg.people[f'P{index}'] = person(f'P{index}', 'Alex', 1)
    pairs, dossiers = runner._dedupe_candidates(20, 0)

    book = finish([
        {'k': 'p', 't': '某人靠近。甲乙丙在后面。'},
        {'k': 'p', 't': '某人后来被称为甲乙和乙丙。'},
    ], [(0, '章', 0)], {}, '测试', '')
    book['chapters'][0]['kind'] = 'body'
    seg = segments(book, [0])[0]
    data = {
        'new_people': [
            {'ref': 'N1', 'name': '某人', 'para': 1, 'quote': '某人靠近'},
            {'ref': 'N2', 'name': '甲乙', 'para': 2, 'quote': '甲乙和乙丙'},
        ],
        'surfaces': {'N1': ['*某人'], 'N2': ['甲乙', '乙丙']},
        'merges': [{'from': 'N1', 'into': 'N2', 'para': 2,
                    'quote': '后来被称为甲乙和乙丙'}],
        'events': [{'who': ['N2'], 'text': '甲乙丙开始行动', 'para': 1,
                    'quote': '某人靠近'}],
        'attrs': [], 'rels': [], 'profiles': [], 'aliases': [],
    }
    old_kg = KG(book)
    plan = old_kg.plan(seg, data)
    committed = old_kg.commit(seg, data, plan, {})
    event = next(row for row in committed if row['t'] == 'event')
    return {
        'proper': proper, 'classic': classic,
        'candidates': captured[0], 'pairs': pairs,
        'dossier_keys': list(dossiers),
        'scrubbed': event['text'],
    }


if __name__ == '__main__':
    print(json.dumps(probe(), ensure_ascii=False, separators=(',', ':')))
