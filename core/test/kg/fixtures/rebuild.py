"""Rebuild offline KG differential expectations from the unchanged Python port source.

Run from the repository root. Uses only existing oracle inputs and synthetic
extractions; no requests, model calls, corpus writes or credentials are needed.
"""
import copy
import json
from pathlib import Path
import sys
import unicodedata

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT))
assert sys.version_info[:2] == (3, 11), 'Use the frozen Python 3.11 oracle interpreter'
from pipeline.kg import KG, Anchor
from pipeline.extract import segments
from tests.test_kg import TEXT, EXTRACTION, make_book


def encode(value):
    if isinstance(value, set):
        return {'$set': sorted(value)}
    if isinstance(value, tuple):
        return {'$tuple': [encode(v) for v in value]}
    if isinstance(value, list):
        return [encode(v) for v in value]
    if isinstance(value, dict):
        return {k: encode(v) for k, v in value.items()}
    return value


def decode(value):
    if isinstance(value, list):
        return [decode(v) for v in value]
    if isinstance(value, dict):
        if set(value) == {'$set'}:
            return set(value['$set'])
        if set(value) == {'$tuple'}:
            return tuple(decode(v) for v in value['$tuple'])
        return {k: decode(v) for k, v in value.items()}
    return value


def state(kg):
    return {k: getattr(kg, k) for k in ('people', 'rels', 'log', 'mentions', 'recent', 'saga', 'n', 'seg', 'warnings')}


def run(book, seg, data, initial=None, guard=None, decisions=None):
    kg = KG(copy.deepcopy(book))
    for k, v in (initial or {}).items():
        setattr(kg, k, copy.deepcopy(v))
    data = copy.deepcopy(data)
    planned = kg.plan(seg, data)
    if decisions is None:
        decisions = {o['key']: o['ids'][0] for o in planned['occs'] if o['ambiguous']}
    log = kg.commit(seg, data, planned, decisions, guard)
    return {'plan': planned, 'committed': log, 'state': state(kg), 'prompt_state': kg.prompt_state(), 'data_after': data}


def case(name, paragraphs, data, lang='zh', initial=None, guard=None):
    book = make_book(paragraphs)
    book['lang'] = book['card_lang'] = lang
    seg = segments(book, [0])[0]
    return {'name': name, 'book': book, 'seg': seg, 'data': data,
            'initial': initial or {}, 'guard': guard,
            'expected': run(book, seg, data, initial, guard)}


def new(ref, name, para, quote, **extra):
    return dict(ref=ref, name=name, para=para, quote=quote, **extra)


cases = [case('original_reveal', TEXT, EXTRACTION)]
cases.append(case('unicode_frontiers', [
    '😀🌙 少女来到了山下。她说：我是丛雨。',
    '丛雨告诉 Ann：Anne 不是 Ann，陈😀明也是朋友。',
    '陈😀明说道："好",大家笑了。',
], {
    'new_people': [new('N1', '丛雨', 1, '少女来到了山下', intro='😀' * 45, importance=3),
                   new('N2', 'Ann', 2, '丛雨告诉 Ann', gender='女'),
                   new('N3', '陈😀明', 2, '陈😀明也是朋友', importance=9)],
    'surfaces': {'N1': ['*少女', '丛雨'], 'N2': ['Ann', 'the girl'], 'N3': ['陈😀明']},
    'aliases': [{'who': 'N2', 'alias': '姐姐'}, {'who': 'N3', 'alias': '明😀', 'primary': True, 'para': 3}],
    'events': [{'who': ['N1', 'N2', 'N1', 'missing'], 'text': '丛雨与 Ann相遇,微笑', 'para': 1, 'quote': '少女来到了山下'},
               {'who': [], 'text': '😀' * 90, 'para': 'bad', 'quote': 'missing quote'}],
    'attrs': [{'who': 'N1', 'key': '😀' * 12, 'value': '😀' * 42, 'para': 1, 'quote': '少女来到'}],
    'rels': [{'a': 'N1', 'b': 'N2', 'a_is': ' a 的 朋友 ', 'b_is': 'B的 同伴', 'desc': '她说"好",Ann笑了',
              'para': 1, 'quote': '少女来到', 'by': 'judge'},
             {'a': 'N1', 'b': 'N1', 'desc': 'skip self'}],
    'profiles': [{'who': 'N1', 'tagline': '新的人物', 'bio': '😀' * 405, 'para': 1},
                 {'who': 'N2', 'tagline': 'Later title', 'para': 1, 'evidence_scope': 'segment'}],
}, guard={'checks': {'N1': {'accepted': True}}}))
cases.append(case('english_limits', [
    '😀 The old gentleman met Ann, not Anne. Charles finally appeared.',
    'Charles called Ann Captain Ann. The old gentleman was Charles.',
], {
    'new_people': [new('N1', 'Charles', 1, 'The old gentleman met Ann', intro='😀' * 130),
                   new('N2', 'Ann', 1, 'met Ann')],
    'surfaces': {'N1': ['*The old gentleman', 'Charles'], 'N2': ['Ann', 'Captain Ann', '*the lady']},
    'aliases': [{'who': 'N2', 'alias': 'Captain Ann', 'primary': True},
                {'who': 'N1', 'alias': 'Charles and Ann'}],
    'rels': [{'a': 'N1', 'b': 'N2', 'a_is': 'x' * 60, 'b_is': 'y' * 60, 'desc': 'z' * 200,
              'quote': 'met Ann', 'para': 1, 'status': 'changed'}],
    'events': [{'who': ['N1'], 'text': '😀' * 250, 'quote': 'met Ann', 'para': 1}],
    'profiles': [{'who': 'N1', 'tagline': '😀' * 95, 'bio': '😀' * 1210, 'para': 2}],
}, lang='en'))
cases.append(case('generic_merge_and_relations', ['少女说她是丛雨。Alice听到了。丛雨点头。'], {
    'new_people': [new('N1', '少女', 1, '少女说'), new('N2', '丛雨', 1, '她是丛雨'), new('N3', 'Alice', 1, 'Alice听到了')],
    'surfaces': {'N1': ['*少女', '*朋友'], 'N2': ['丛雨'], 'N3': ['Alice']},
    'rels': [{'a': 'N1', 'b': 'N2', 'a_is': '同人', 'b_is': '同人', 'para': 1},
             {'a': 'N2', 'b': 'N3', 'a_is': '朋友', 'b_is': '朋友', 'para': 1}],
    'merges': [{'from': 'N2', 'into': 'N1', 'para': 1, 'quote': '她是丛雨', 'reason': '她说"是",点头'}],
}))

plan_path = ROOT / 'oracle/goldens/pipeline/kg/KG/plan.jsonl'
captured = []
for index, line in enumerate(plan_path.read_text().splitlines()):
    row = decode(json.loads(line))
    i = row['input']
    fields = i['self']['fields']
    initial = {k: v for k, v in fields.items() if k != 'book'}
    seg = dict(i['seg'])
    last = fields['book']['blocks'][seg['blocks'][-1]]
    seg.setdefault('o1', last['o'] + len(last['t'].encode('utf-16-le')) // 2)
    captured.append({'source_row': index, 'seg': seg,
                     'expected': run(fields['book'], seg, i['data'], initial)})

# Anchor edge cases are full inputs, unlike traced pos snapshots that omit blocks.
book = make_book(['😀🌙 Ann met Anne.', '甲，乙。丙！丁戊己庚辛壬癸子丑寅卯辰巳。', 'Ann met Bob.'])
seg = segments(book, [0])[0]
anchor = Anchor(book, seg)
anchor_calls = []
for method, args in [
    ('find', ['Ann', 3]), ('find', ['甲乙丙', 2]),
    ('find', ['甲乙丙丁戊己THIS IS PARAPHRASED', 2]),
    ('find', ['😀', 1]), ('find', ['🌙 Ann', 1]), ('find', ['甲乙', 2]),
    ('find', ['missing', None]), ('pos', [500, 'missing']), ('pos', [True, None]),
    ('pos', [2, None]), ('para_end', ['invalid']), ('para_end', ['2']),
    ('block', ['bad']), ('block', [1.8]), ('block', [False]),
    ('block', ['１']), ('block', ['١']), ('block', ['0x1']),
    ('block', ['+１']), ('block', ['1_0']), ('block', ['1__0']),
    ('block', ['\x1c1']), ('block', ['\u00851']),
    ('first', ['Ann', 6]), ('first', ['Ann', 7]), ('first', ['Anne', -1]),
    ('first', ['😀', -1]), ('first', ['Bob', 999]),
]:
    anchor_calls.append({'method': method, 'args': args, 'expected': getattr(anchor, method)(*args)})

out = Path(__file__).parent / 'kg_differential.json'
out.write_text(json.dumps(encode({'synthetic': cases, 'captured': captured,
    'anchor': {'book': book, 'seg': seg, 'calls': anchor_calls},
    'oracle': {'python': sys.version.split()[0], 'unicode': unicodedata.unidata_version}}), ensure_ascii=False, separators=(',', ':')) + '\n')
print(f'Wrote {out.relative_to(ROOT)}: {len(cases)} synthetic commits, {len(captured)} captured commits, {len(anchor_calls)} anchor cases')
