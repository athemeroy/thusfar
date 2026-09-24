"""Run offline release checks and bind their receipt to the exact runtime source."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.build_release import fingerprint, inventory, stamp_shell

NETWORK_GUARD = '''import socket
_connect = socket.socket.connect
_connect_ex = socket.socket.connect_ex
_getaddrinfo = socket.getaddrinfo
def local(host):
    return host in ('localhost', '127.0.0.1', '::1', None, '')
def connect(self, address):
    if self.family in (socket.AF_INET, socket.AF_INET6) and not local(address[0]):
        raise RuntimeError('External network is forbidden during release checks')
    return _connect(self, address)
def connect_ex(self, address):
    if self.family in (socket.AF_INET, socket.AF_INET6) and not local(address[0]):
        raise RuntimeError('External network is forbidden during release checks')
    return _connect_ex(self, address)
def getaddrinfo(host, *args, **kwargs):
    if not local(host):
        raise RuntimeError('External DNS is forbidden during release checks')
    return _getaddrinfo(host, *args, **kwargs)
socket.socket.connect = connect
socket.socket.connect_ex = connect_ex
socket.getaddrinfo = getaddrinfo
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    shell = stamp_shell(root)
    before = fingerprint(inventory(root))
    rows = []
    with tempfile.TemporaryDirectory(prefix='yedu-release-check-') as temporary:
        guard = Path(temporary)
        (guard / 'sitecustomize.py').write_text(NETWORK_GUARD)
        env = dict(os.environ)
        for name in ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy'):
            env.pop(name, None)
        env.update(PYTHONPATH=str(guard) + os.pathsep + str(root), PYTHONDONTWRITEBYTECODE='1',
                   DATA_DIR=str(guard / 'data'), AUTO_PROCESS='0', DETECT_KIND='0', COOKIE_SECURE='0',
                   JEV_ROUTE='free-only', JEV_PAID_MAX_CALLS='0', JEV_PAID_MAX_CHARS='0')

        def check(name, argv, stdin=None, timeout=300):
            start = time.monotonic()
            log = out / (name + '.log')
            try:
                with log.open('wb') as stream:
                    result = subprocess.run(argv, cwd=root, env=env, input=stdin,
                                            stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
                code, error = result.returncode, None
            except (OSError, subprocess.TimeoutExpired) as exc:
                code, error = -1, str(exc)
            row = {'check': name, 'exit_code': code, 'seconds': round(time.monotonic() - start, 3), 'log': log.name}
            if error:
                row['error'] = error
            rows.append(row)
            print(json.dumps(row), flush=True)

        check('python', [sys.executable, '-m', 'unittest', 'discover', '-s', 'tests', '-p', 'test*.py', '-v'])
        check('i18n-catalogs', [sys.executable, str(root / 'scripts/check_i18n.py')], timeout=30)
        for path in sorted((root / 'web/js').rglob('*.js')):
            check('syntax-' + '-'.join(path.relative_to(root / 'web/js').with_suffix('').parts),
                  ['node', '--input-type=module', '--check'], path.read_bytes(), timeout=20)
        check('syntax-worker', ['node', '--check', str(root / 'web/sw.js')], timeout=20)
        for path in sorted((root / 'tests').glob('*.test.mjs')):
            check(path.stem, ['node', str(path)], timeout=90)
        browser = root / 'tests/frontend_browser.py'
        if browser.is_file():
            check('browser', [sys.executable, str(browser), '--out-dir', str(out / 'browser')], timeout=180)
        else:
            rows.append({'check': 'browser', 'exit_code': -1, 'error': 'Browser release check is missing'})
        for name in ('library', 'source_preview', 'workspace', 'notebook_hub', 'offline_library', 'library_workspace', 'marginalia', 'i18n'):
            browser = root / 'tests' / (name + '_browser.py')
            if not browser.is_file():
                rows.append({'check': name + '-browser', 'exit_code': -1, 'error': 'Required UX browser check is missing'})
                continue
            check(name + '-browser', [sys.executable, str(browser), '--out-dir', str(out / (name + '-browser'))], timeout=240)
    after = fingerprint(inventory(root))
    proof = {'format': 'yedu-validation/1', 'source_sha256': before, 'shell': shell,
             'source_unchanged': before == after, 'checks': rows,
             'ok': before == after and all(row['exit_code'] == 0 for row in rows)}
    (out / 'validation.json').write_text(json.dumps(proof, indent=2) + '\n')
    print(json.dumps({'ok': proof['ok'], 'receipt': str(out / 'validation.json')}))
    return 0 if proof['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
