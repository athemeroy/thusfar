"""Add JEV attribute checks to already-processed segments (writes guard.attrs into work/segs/*.json).

usage: python -m scripts.backfill_attr_checks data/books/<id> [--force]
Idempotent: segments that already have guard.attrs are skipped. Applied on the next replay.
"""
import json
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from pipeline.extract import segments, seg_text
from pipeline.run import check_attrs, wjson

root = Path(sys.argv[1])
book = json.loads((root / 'book.json').read_text())
segs = segments(book, [i for i, c in enumerate(book['chapters']) if c['kind'] == 'body'])
kg = json.loads((root / 'kg.json').read_text())
names = {r['id']: (r['name'], r.get('intro') or '') for r in kg['log'] if r['t'] == 'person'}
FORCE = '--force' in sys.argv


def one(path: Path):
    rec = json.loads(path.read_text())
    g = rec.setdefault('guard', {})
    if 'attrs' in g and not FORCE:
        return 0, 0
    refnames = {np.get('ref'): np.get('name') for np in rec['data'].get('new_people', [])}
    intros = {np.get('ref'): np.get('intro') for np in rec['data'].get('new_people', [])}
    who_of = lambda w: (refnames[w], intros.get(w) or '') if w in refnames else names.get(w) or (str(w), '')  # noqa: E731
    g['attrs'] = check_attrs(seg_text(book, segs[rec['seg']]), rec['data'], who_of)
    wjson(path, rec)
    return len(g['attrs']), sum(1 for v in g['attrs'].values() if (v.get('p') or 0) < 0.2)


files = sorted((root / 'work' / 'segs').glob('*.json'))
with ThreadPoolExecutor(6) as ex:
    res = list(ex.map(one, files))
print(f'{len(files)} segments, {sum(r[0] for r in res)} attributes checked, {sum(r[1] for r in res)} strongly rejected')
