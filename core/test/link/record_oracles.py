"""Record bounded offline pipeline.link scenarios and exact Jev requests.

Run from the repository root: python3 core/test/link/record_oracles.py
The Python implementation computes all expectations; the model is always replaced.
"""
from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import sys
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from pipeline import link
from pipeline.kg import KG


def encoded(value):
    if isinstance(value, set):
        return {'$set': sorted(value)}
    if isinstance(value, tuple):
        return {'$tuple': [encoded(x) for x in value]}
    if isinstance(value, list):
        return [encoded(x) for x in value]
    if isinstance(value, dict):
        return {k: encoded(v) for k, v in value.items()}
    return value


def person(name, **more):
    return {'name': name, 'aliases': {name}, 'first': 0, 'mentions': 1, **more}


def lp(lid, name, **more):
    return {'id': lid, 'name': name, 'names': [], 'role': '', **more}


def answer(choice, p):
    return {'choice': choice, 'probabilities': {choice: p}}


def segment(name, people, local, answers=(), scope_start=0, context_text='段落原文', k=1):
    return {'case': name, 'function': 'link_segment', 'input': {
        'people': people, 'local': local, 'seg': {'i': 0, 'blocks': []},
        'context_text': context_text, 'scope_start': scope_start, 'k': k,
    }, 'answers': list(answers)}


def record(case):
    sample = copy.deepcopy(case)
    inp = sample['input']
    calls = []
    def fake_jev(state, questions):
        n = len(calls)
        calls.append({'state': copy.deepcopy(state), 'questions': copy.deepcopy(questions)})
        if n >= len(sample['answers']):
            raise AssertionError(f"unexpected model call: {sample['case']}: {questions}")
        return copy.deepcopy(sample['answers'][n])
    with patch.object(link, 'jev', fake_jev):
        if sample['function'] == 'link_segment':
            kg = KG({'blocks': [], 'lang': 'zh'})
            kg.people = copy.deepcopy(inp['people'])
            kg.k = inp['k']
            result = link.link_segment(kg, inp['seg'], inp['local'], inp['context_text'], inp['scope_start'])
        elif sample['function'] == 'verify_names':
            decisions = copy.deepcopy(inp['decisions'])
            result = {'return': link.verify_names(inp['cast'], inp['people'], decisions, inp['passage']),
                      'decisions': decisions}
        elif sample['function'] == '_ask_jev':
            result = link._ask_jev(inp['questions'], inp['cast'], inp['context_text'], inp['locals_by_id'])
        elif sample['function'] == 'pipeline':
            kg = KG(inp['book'])
            result = []
            for stage in inp['stages']:
                data, linked = link.link_segment(kg, stage['seg'], stage['local'], stage['context_text'])
                planned = kg.plan(stage['seg'], data)
                decisions = {o['key']: o['ids'][0] for o in planned['occs'] if o['ambiguous']}
                committed = kg.commit(stage['seg'], data, planned, decisions)
                result.append(copy.deepcopy({'data': data, 'linked': linked, 'plan': planned,
                                            'committed': committed, 'people': kg.people,
                                            'mentions': kg.mentions, 'log': kg.log}))
        else:
            raise AssertionError(sample['function'])
    assert len(calls) == len(sample['answers']), sample['case']
    sample['calls'] = calls
    sample['output'] = result
    return encoded(sample)


def cases():
    texts = ['😀Alice 见到了 Bob。太太向 Bob 问好。', '太太再次见到了 Bob。']
    length = lambda text: len(text.encode('utf-16-le')) // 2
    offset = length(texts[0]) + 1
    yield {'case': 'sequential_link_plan_commit_preserves_prior_cast_and_utf16', 'function': 'pipeline',
           'input': {'book': {'lang': 'zh', 'blocks': [
               {'k': 'p', 't': texts[0], 'o': 0}, {'k': 'p', 't': texts[1], 'o': offset}]}, 'stages': [
               {'seg': {'blocks': [0], 'o1': length(texts[0])}, 'context_text': texts[0], 'local': {
                   'people': [lp('title', '太太', gender='女', para=1, quote='太太向 Bob 问好'),
                              lp('a', 'Alice', gender='女', para=1, quote='Alice 见到了 Bob', role='女主人'),
                              lp('b', 'Bob', gender='男', para=1, quote='Alice 见到了 Bob', role='客人')],
                   'events': [{'who': ['title', 'b'], 'para': 1, 'quote': '太太向 Bob 问好', 'text': 'Alice 向 Bob 问好'}],
               }},
               {'seg': {'blocks': [1], 'o1': offset + length(texts[1])}, 'context_text': texts[1], 'local': {
                   'people': [lp('title', '太太', gender='女', para=1, known='P1', known_name='Alice'),
                              lp('b', 'Bob', gender='男', para=1)],
                   'events': [{'who': ['title', 'b'], 'para': 1, 'quote': texts[1], 'text': '二人再次相遇'}],
               }},
           ]}, 'answers': [{'q1': answer('L:a', .9)}, {'q1': answer('P1', .9)}]}
    yield segment('empty', {}, {})
    yield segment('distinct_name_over_conflicting_hint', {
        'P1': person('Alice'), 'P2': person('Bob'),
    }, {'people': [lp('a', 'Alice', known='P2')]})
    yield segment('scope_and_merged_people_excluded', {
        'P1': person('Alice', first=2), 'P2': person('Bob', first=10, merged_into='P3'),
        'P3': person('Carol', first=10),
    }, {'people': [lp('a', 'Alice', known='P1'), lp('b', 'Bob')]}, scope_start=10)
    yield segment('filtered_people_still_preserved_by_classic_schema', {}, {
        'people': [lp('a', '他们'), lp('b', '王氏夫妇'), lp('c', 'Alice')],
        'events': [{'who': ['a', 'b', 'c', 'missing'], 'text': '相遇'}],
    })
    yield segment('generic_local_reference', {}, {
        'people': [lp('title', '太太', gender='女'), lp('a', 'Alice', gender='女'), lp('b', 'Bob', gender='男')],
    }, [{'q1': answer('L:a', 0.9)}])
    yield segment('fuzzy_given_name', {'P1': person('Herbert Pocket')},
                  {'people': [lp('a', 'Herbert')]}, [{'q1': answer('P1', 0.75)}])
    yield segment('same_title_core', {'P1': person('郝麦太太')},
                  {'people': [lp('a', '郝麦夫人')]}, [{'q1': answer('P1', 0.75)}])
    yield segment('exact_gender_clash_still_goes_to_judge', {'P1': person('Alice', gender='男')},
                  {'people': [lp('a', 'Alice', gender='女')]}, [{'q1': answer('new', 0.9)}])
    for label, response in [('below_threshold', answer('P1', 0.599)), ('missing', {}),
                            ('invalid_candidate', answer('P99', 0.99)), ('rounded_to_threshold', answer('P1', 0.5996))]:
        yield segment('shared_exact_' + label, {'P1': person('Alice', mentions=3), 'P2': person('Alice')},
                      {'people': [lp('a', 'Alice')]}, [{'q1': response}])
    yield segment('weak_match_uncertain_is_new', {'P1': person('Alice', weak={'太太'})},
                  {'people': [lp('a', '太太')]}, [{'q1': answer('P1', 0.59)}])
    for p in [0.6994, 0.6996]:
        yield segment(f'unrelated_identity_local_propagation_{p}', {'P1': person('无觉大师')}, {
            'people': [lp('title', '老和尚'), lp('a', '圆觉大师', known='P1')],
        }, [{'q1': answer('L:a', .9), 'q2': answer('P1', .8)},
            {'c1': answer('same', p), 'a2': answer('yes', .9)}])
    yield segment('taken_and_unrelated_forms_dropped', {
        'P1': person('雷泰'), 'P2': person('老余'),
    }, {'people': [lp('a', '雷泰', names=['老余', '王木', '*太太'])]},
        [{'q1': answer('P1', .9)}, {'a1': answer('yes', .4994), 'a2': answer('yes', .4996)}])
    yield segment('candidate_priority_and_limits', {
        f'P{i}': person('Alice', mentions=i) for i in range(1, 9)
    }, {'people': [lp('a', 'Alice', known='P1')]}, [{'q1': answer('new', .9)}])
    yield segment('unicode_profile_slice_and_classic_remapping', {}, {
        'people': [lp(1, '', names=['Alice'], role='😀' * 85), lp(2, 'Bob')],
        'same': [{'a': 1, 'b': 2, 'why': 'same', 'para': 1, 'quote': 'Alice Bob'}],
        'facts': [{'who': 1, 'value': 'x'}, {'who': 8}],
        'rels': [{'a': 1, 'b': 2, 'status': 'invalid'}],
        'events': [{'who': [1, 2, 8], 'imp': 3}],
    }, k=3)
    many = [lp(str(i), f'Agent{i}') for i in range(50)]
    yield {'case': 'verify_batches_and_unicode_context_cutoff', 'function': 'verify_names', 'input': {
        'cast': {'P1': person('Zorro')}, 'people': many,
        'decisions': {str(i): {'to': 'P1', 'how': 'jev'} for i in range(50)},
        'passage': '😀' * 12005,
    }, 'answers': [{}, {}, {}]}
    yield {'case': 'ask_batches_local_descriptions_and_unicode_context_cutoff', 'function': '_ask_jev', 'input': {
        'questions': [(str(i), lp(str(i), '太太'), ['P1', 'L:a']) for i in range(50)],
        'cast': {'P1': person('Alice', aliases={'Alice', 'Alice Z', 'Alice B'}, weak={'太太'}, intro='intro')},
        'context_text': '😀' * 12005, 'locals_by_id': {'a': lp('a', 'Mary', role='主人')},
    }, 'answers': [
        {f'q{i}': answer('P1', .6005) for i in range(1, 49)},
        {'q1': answer('L:a', .8), 'q2': answer('new', .5)},
    ]}


def main():
    result = {'schema': 1, 'source_sha256': hashlib.sha256((ROOT / 'pipeline/link.py').read_bytes()).hexdigest(),
              'cases': [record(case) for case in cases()]}
    path = Path(__file__).parent / 'fixtures/oracles.json'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(f'Recorded {len(result["cases"])} offline link scenarios')


if __name__ == '__main__':
    main()
