"""Record the original Python ask behavior without any network or credentials."""
import hashlib
import json
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from server import ask


def book(texts, lang='en'):
    blocks, offset = [], 0
    for text in texts:
        blocks.append({'k': 'p', 't': text, 'o': offset})
        offset += len(text.encode('utf-16-le')) // 2 + 1
    return {'title': 'Fixture', 'lang': lang, 'len': offset,
            'blocks': blocks, 'chapters': [{'title': 'Future identity revealed',
            'b0': 0, 'b1': len(blocks), 'o0': 0, 'o1': offset, 'kind': 'body'}]}

b = book(['Alice came to the village.', 'Bob offered Alice a cup of tea.',
          'They sat in the garden.😀A future revelation follows.', 'UNREAD SECRET identity.'])
pos = b['blocks'][2]['o'] + len('They sat in the garden.') + 1
log = [{'t': 'person', 'p': 0, 'id': 'a', 'name': 'Alice'},
       {'t': 'person', 'p': 1, 'id': 'b', 'name': 'Bob'},
       {'t': 'rel', 'p': 3, 'a': 'a', 'b': 'b', 'a_is': 'wife', 'b_is': 'husband', 'status': 'ended'},
       {'t': 'saga', 'p': 4, 'text': 'Alice arrived.'},
       {'t': 'attr', 'p': 5, 'id': 'a', 'key': 'job', 'value': 'teacher'},
       {'t': 'attr', 'p': 6, 'id': 'a', 'key': 'job', 'value': 'writer'},
       {'t': 'event', 'p': pos + 1, 'who': ['a'], 'text': 'UNREAD GRAPH SECRET'}]
out = {'source_sha256': hashlib.sha256((ROOT/'server/ask.py').read_bytes()).hexdigest(),
       'recent': [], 'retrieve': [], 'answers': [], 'who': []}
with tempfile.TemporaryDirectory() as td:
    d = Path(td)/'books'/'fixture'; d.mkdir(parents=True)
    (d/'book.json').write_text(json.dumps(b))
    for cutoff in [0, 5, pos, b['len']]:
        args = {'book': b, 'pos': cutoff, 'chars': 40}
        out['recent'].append({'input': args, 'output': ask.recent_text(**args)})
        for q in ['Alice', '她为什么来了？', 'garden']:
            args = {'book': b, 'q': q, 'names': [], 'pos': cutoff, 'k': 3}
            out['retrieve'].append({'input': args, 'output': ask.retrieve(d, **args)})
    cases = [
        ('accepted', 'How are Alice and Bob related?', 'relation', {'relation': .9},
         ['"Alice came" [1]. They were married.'], [{'a': {'verdict': 'ok', 'p': .95}}]),
        ('rewritten', 'What happened?', 'recap', {}, ['REJECTED FIRST', 'Alice came. [1]'],
         [{'a': {'verdict': 'flag', 'p': .01}}, {'a': {'verdict': 'ok', 'p': .8}}]),
        ('withheld', '发生了什么？', 'other', {}, ['REJECTED FIRST', 'REJECTED SECOND'],
         [{'a': {'verdict': 'flag', 'p': .01}}, {'a': {'verdict': 'flag', 'p': .01}}]),
        ('guard_outage', 'What happened?', 'other', {}, ['REJECTED PRIVATE'], ['error']),
        ('future', 'What happens next?', 'future', {'future': .9}, [], []),
        ('quotes', 'What did Alice say?', 'who', {}, ['“Not a quote” [1], "Alice came" [1] [source]'],
         [{'a': {'verdict': 'ok', 'p': .95}}]),
    ]
    for digit in ['１', '١']:
        cases.append(('unicode_' + digit, 'Who is Alice?', 'who', {},
            ['「Alice came」[' + digit + ']'], [{'a': {'verdict': 'ok', 'p': .95}}]))
    for label, question, route, probs, replies, verdicts in cases:
        events, calls = [], []
        chats = iter(replies); guards = iter(verdicts)
        def chat(model, messages, **kw):
            calls.append({'model': model, 'messages': messages, **kw})
            return next(chats), {}
        def guard(*args):
            result = next(guards)
            if result == 'error': raise RuntimeError('fixture outage')
            return result
        data = {'book.json': b, 'kg.json': {'log': log}, 'status.json': {'frontier': pos - 1}}
        with patch.object(ask, 'route_question', return_value=(route, probs)), \
             patch.object(ask, 'retrieval_query', side_effect=lambda q, b: q), \
             patch.object(ask, 'rank_by_judge', side_effect=lambda q, p: p[:6]), \
             patch.object(ask, 'chat', side_effect=chat), \
             patch.object(ask, 'guard_texts', side_effect=guard), \
             patch.object(ask, 'QA_MODEL', 'fixture-model'):
            ask.answer(d, question, pos, lambda kind, payload: events.append({'kind': kind, 'value': payload}), lambda p: data[p.name])
        for event in events:
            event['value'].pop('ms', None)
        out['answers'].append({'name': label, 'input': {'book': b, 'kg': data['kg.json'],
            'status': data['status.json'], 'question': question, 'pos': pos}, 'script': {'route': route,
            'probs': probs, 'replies': replies, 'guards': verdicts}, 'events': events, 'chat': calls})
    wb = book(['Person19 arrived. He sat down.'])
    wl = [{'t': 'person', 'p': 0, 'id': f'p{i}', 'name': f'Person{i}'} for i in range(20)]
    wl.append({'t': 'cnt', 'p': 0, 'c': {f'p{i}': 100 if i < 19 else 1 for i in range(20)}})
    calls=[]
    def jev(s,q):
        calls.append({'state': s, 'questions': q}); return {'w': {'choice': 'p19', 'probabilities': {'p19': .9}}}
    with patch.object(ask, 'jev', side_effect=jev):
        result=ask.who_is(wb, wl, 29, 18, 20)
    out['who'].append({'input': {'book': wb, 'log': wl, 'pos':29, 'start':18,'end':20}, 'output':result, 'calls':calls})
Path(__file__).with_name('fixtures').joinpath('python_ask.json').write_text(json.dumps(out, ensure_ascii=False, indent=2)+'\n')
print('Recorded Python ask fixtures: 4 recent, 12 retrieval, 8 full answers, 1 who; network calls: 0')
