"""Clone a processed book so phase 2 (linking, checks, biographies) can be re-run with new code
while reusing the paid-for phase-1 outputs.

usage: python3 scripts/replay_phase2.py SRC_DIR DST_DIR [--keep-recaps]

Copies book.json and work/local/*. Old hints named people by id only; the id→name map of the
old run is added as `known_name`, so a different numbering in the replay cannot mislead linking.
--keep-recaps also copies chapter recaps and the story-so-far (they depend on events, not on
who-is-who, and are the bulk of the model calls); biographies are always regenerated.
"""
import json
import shutil
import sys
import time
from pathlib import Path


def main():
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    if dst.exists():
        sys.exit(f'{dst} exists')
    (dst / 'work' / 'local').mkdir(parents=True)
    shutil.copy(src / 'book.json', dst / 'book.json')
    meta = json.loads((src / 'meta.json').read_text()) if (src / 'meta.json').exists() else {}
    meta.update(added=time.time(), auto=False, replay_of=src.name)
    (dst / 'meta.json').write_text(json.dumps(meta, ensure_ascii=False))
    names = {}
    kg = json.loads((src / 'kg.json').read_text())
    for r in kg['log']:
        if r['t'] == 'person':
            names.setdefault(r['id'], r['name'])
        elif r['t'] == 'name':
            names[r['id']] = r['name']
    n = 0
    for f in sorted((src / 'work' / 'local').glob('*.json')):
        rec = json.loads(f.read_text())
        for lp in rec.get('data', {}).get('people', []):
            if lp.get('known') in names and not lp.get('known_name'):
                lp['known_name'] = names[lp['known']]
                n += 1
        (dst / 'work' / 'local' / f.name).write_text(json.dumps(rec, ensure_ascii=False))
    if '--keep-recaps' in sys.argv:
        for sub in ('recaps', 'sagas'):
            if (src / 'work' / sub).exists():
                shutil.copytree(src / 'work' / sub, dst / 'work' / sub)
    print(f'cloned {src.name} → {dst.name}: {len(list((dst / "work" / "local").glob("*.json")))} local files, {n} hints named')


if __name__ == '__main__':
    main()
