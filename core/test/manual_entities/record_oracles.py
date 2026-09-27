"""Record Python 3.11 manual-entity contracts without network calls."""
from pathlib import Path
import copy
import json
import sys
from unittest.mock import patch

assert sys.version_info[:2] == (3, 11), 'Use the frozen Python 3.11 oracle'
ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from server import manual_entities as m

TEXT = '😀阿明 阿明 李四 Alpha Straße fox foxtrot fox'
BOOK = {'title': 'Manual fixture', 'len': len(TEXT.encode('utf-16-le')) // 2,
        'blocks': [{'k': 'p', 't': TEXT, 'o': 0}],
        'chapters': [{'title': 'One', 'b0': 0, 'b1': 1, 'o0': 0,
                      'o1': len(TEXT.encode('utf-16-le')) // 2}], 'notes': {}}
cases = []

def call(fn, *args, label=None):
    args = copy.deepcopy(args)
    row = {'function': fn, 'args': args, 'label': label or fn}
    try:
        with patch.object(m.time, 'time', return_value=1234.5):
            value = getattr(m, fn)(*copy.deepcopy(args))
        row['value'] = value
    except Exception as e:
        row['error'] = {'type': type(e).__name__, 'message': str(e)}
        value = None
    cases.append(row)
    return value

def payload(**kw):
    return {'id': 'manual01', 'kind': 'person', 'name': '阿明',
            'knowledge_cutoff': BOOK['len'], 'note': '  first note  ',
            'operation': 'operation01', 'expected_revision': 0, **kw}

for name in ['阿明', '😀', 'fox', 'foxtrot', 'missing', 'Alpha', 'Straße']:
    for cutoff in [0, 1, 2, 3, 4, 5, 8, 15, BOOK['len']]:
        call('anchor', BOOK, name, cutoff, label=f'anchor {name} @{cutoff}')

created = call('apply', [], payload(knowledge_cutoff=4), BOOK, {'log': []})[1]
edited = call('apply', [created], payload(expected_revision=1, operation='operation02', note='later note'), BOOK, {'log': []})[1]
deleted = call('apply', [edited], payload(expected_revision=2, operation='operation03', deleted=True, note=''), BOOK, {'log': []})[1]
for old in [created, edited, deleted]:
    call('rows', [old])
    call('restore', [old], BOOK)
    call('mentions', BOOK['blocks'], [old], [])
call('apply', [created], payload(knowledge_cutoff=4), BOOK, {'log': []}, label='operation replay')
call('apply', [created], payload(knowledge_cutoff=4, note='changed'), BOOK, {'log': []}, label='operation replay changed')
call('apply', [created], payload(operation='operation03'), BOOK, {'log': []}, label='revision conflict')
call('apply', [], payload(expected_revision=1), BOOK, {'log': []}, label='unknown id conflict')
for kw in [dict(id='bad'), dict(kind='bad'), dict(name=''), dict(name='A\nB'),
           dict(name='😀'*81), dict(knowledge_cutoff=True), dict(note='x'*3001),
           dict(operation='bad'), dict(expected_revision=-1), dict(deleted=True)]:
    call('apply', [], payload(**kw), BOOK, {'log': []})
for kw in [dict(name='李四'), dict(kind='concept'), dict(knowledge_cutoff=3)]:
    call('apply', [created], payload(expected_revision=1, operation='operation04', **kw), BOOK, {'log': []})
for name, other in [('阿明', '阿明'), ('Straße', 'STRASSE')]:
    call('apply', [], payload(name=name), BOOK, {'log': [{'t':'person', 'id':'p1', 'name':other, 'p':0}]})
    call('apply', [], payload(name=name), BOOK, {'log': [{'t':'person', 'id':'p1', 'name':other, 'p':BOOK['len']+1}]}, label='future duplicate stays private')
call('apply', [created], payload(id='manual02', operation='operation09'), BOOK, {'log': []}, label='manual duplicate')
concept = call('apply', [], payload(id='manual03', name='fox', kind='concept', operation='operation03'), BOOK, {'log': []})[1]
longer = call('apply', [], payload(id='manual04', name='foxtrot', kind='concept', operation='operation04'), BOOK, {'log': []})[1]
call('mentions', BOOK['blocks'], [concept, longer, created], [[2,4,'p1',0], [26,29,'p2',1]])
call('mentions', BOOK['blocks'], [created, concept], [[3,5,'p1']])
call('rows', [concept, edited, deleted, longer])
for raw in [None, {}, [created, created], [dict(created, versions=[])],
            [dict(created, knowledge_cutoff=3)], [dict(created, source_start=0)],
            [dict(created, revision=0)], [dict(created, operation='bad')],
            [dict(created, operation_hash='X'*64)],
            [dict(edited, versions=list(reversed(edited['versions'])))],
            [dict(created, versions=[{'p':4,'note':None}])]]:
    call('restore', raw, BOOK)
call('apply', [], payload(expected_revision=None), BOOK, {'log': []})
call('apply', [dict(created, created=None)], payload(expected_revision=1, operation='operation08'), BOOK, {'log': []})
call('restore', [dict(created, created=None, updated=None)], BOOK)
call('apply', [created] * 1000, payload(id='manual09', name='Alpha'), BOOK, {'log': []}, label='item capacity')
out = Path(__file__).with_name('fixtures') / 'python.json'
out.write_text(json.dumps({'book':BOOK, 'cases':cases}, ensure_ascii=False, indent=2) + '\n')
print(f'Recorded {len(cases)} manual-entity oracle cases')
