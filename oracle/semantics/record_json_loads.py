"""Record Python 3.11 json.loads results and error messages for pyJsonLoads."""
import json
import random
from pathlib import Path

CASES = ['{"a":1,}', '[1,]', '{"a" 1}', '{a:1}', '"abc', '[1 2]', '{"a":1} x', '', ' ', '"\\x"', '"a\nb"',
         '{"k":"v","k":2}', '[1e5, 2.0, -0, 0.5, 12345678901234567890]', '[NaN, Infinity, -Infinity]',
         '{"名":"阿Q","q":"\\u963f\\ud83d\\ude42"}', '𠮷{', '{"x": [1, {"y": null}], "z": true, "w": false}',
         '\n\n  {"a":\n 1\n,\n}', '["\\ud83d"]', '{"a":"b"', '[', '{', '{"a":', '-', '01', '1.', '.5', 'tru', '"\\u12"']
rng = random.Random(7)
alphabet = '{}[],:"\\ ntrue1-.e阿𠮷\n'
for _ in range(400):
    CASES.append(''.join(rng.choice(alphabet) for _ in range(rng.randint(1, 14))))
out = []
for t in CASES:
    try:
        v = json.loads(t)
        out.append({'text': t, 'ok': json.dumps(v, allow_nan=True)})
    except json.JSONDecodeError as e:
        out.append({'text': t, 'error': str(e)})
Path(__file__).with_name('json_loads.jsonl').write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in out), encoding='utf-8')
print(len(out))
