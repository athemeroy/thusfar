"""Print deterministic link, dedupe, and spoiler-scrub outputs for one hash seed."""

import json
from types import SimpleNamespace
from unittest.mock import patch

from pipeline.extract import segments
from pipeline.kg import KG
from pipeline.link import link_segment, proper_name, to_classic, verify_names
from pipeline.parse import finish
from server import ask
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
    cast['P1']['aliases'].update({'Aaron', 'Alder', 'Alice', 'Alpha'})
    kg = SimpleNamespace(people=cast, canon=lambda pid: pid, k=1)
    captured = []
    name_index = []

    def fake_judge(questions, *_args):
        captured.append(questions[0][2])
        return {'1': {'choice': 'new', 'p': 1.0}}

    def capture_name_index(_kg, _person, by_name):
        name_index.extend(by_name)
        return None

    with patch('pipeline.link._ask_jev', side_effect=fake_judge), \
         patch('pipeline.link._resolve_hint', side_effect=capture_name_index), \
         patch('pipeline.link.verify_names', return_value=({}, {})):
        link_segment(kg, {}, {'people': [{'id': '1', 'name': 'Alex', 'names': []}]}, 'Alex')

    runner = bare_runner()
    for index in range(1, 6):
        runner.kg.people[f'P{index}'] = person(f'P{index}', 'Alex', 1)
    pairs, dossiers = runner._dedupe_candidates(20, 0)

    verify_related_calls = []
    target = person('P1', '吴甲', 1)
    target['aliases'].add('钱乙')
    local_person = {'id': '1', 'name': '周丙', 'names': ['郑丁']}

    def verify_related(a, b):
        verify_related_calls.append((a, b))
        return False

    with patch('pipeline.link.related', side_effect=verify_related), \
         patch('pipeline.link.jev', return_value={}):
        verify_names({'P1': target}, [local_person],
                     {'1': {'to': 'P1', 'how': 'fallback-name'}}, '测试段落')

    dedupe_related_calls = []
    dedupe_runner = bare_runner()
    dedupe_runner.kg.people['P1'] = target
    other = person('P2', '周丙', 2)
    other['aliases'].add('郑丁')
    dedupe_runner.kg.people['P2'] = other

    def dedupe_related(a, b):
        dedupe_related_calls.append((a, b))
        return False

    with patch('pipeline.run.related', side_effect=dedupe_related):
        dedupe_runner._dedupe_candidates(20, 0)

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
    question = 'alpha beta gamma delta epsilon zeta'
    passages = [(i * 4000, question.ljust(30)) for i in range(13)]
    passages.extend([
        (52000, 'alpha beta gamma'.ljust(30)),
        (56000, 'delta epsilon zeta'.ljust(30)),
        (60000, 'beta epsilon gamma zeta'.ljust(3000)),
        (64000, 'gamma zeta'.ljust(3000)),
        (68000, 'extra'.ljust(3000)),
        (72000, 'filler'.ljust(3000)),
    ])
    with patch.object(ask, '_book_index', return_value=passages):
        retrieved = ask.retrieve(None, {}, question, [], 80000)
    return {
        'proper': proper, 'classic': classic,
        'candidates': captured[0], 'name_index': name_index, 'pairs': pairs,
        'verify_related_calls': verify_related_calls,
        'dedupe_related_calls': dedupe_related_calls,
        'dossier_keys': list(dossiers),
        'scrubbed': event['text'],
        'retrieved_offsets': [row['o'] for row in retrieved],
    }


if __name__ == '__main__':
    print(json.dumps(probe(), ensure_ascii=False, separators=(',', ':')))
