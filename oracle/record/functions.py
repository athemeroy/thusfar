"""Capture actual pure-function calls while running the Python tests and corpus.

Example:
  python3 -m oracle.record.functions --include oracle/record/pure-functions.txt --unittest \
      --corpus oracle/corpus --out oracle/goldens

An include file has one Python qualified function id per line. Without one, the recorder reads
all rows marked 纯函数 from docs/port/INVENTORY.md. Only JSON-safe calls are committed; the
report lists skipped values and functions that received no calls.
"""
from __future__ import annotations

import argparse
import dis
import importlib
import ipaddress
import json
import os
import runpy
import socket
import sys
import tempfile
import threading
import unittest
from collections import Counter
from pathlib import Path

from .common import (ObjectView, UnsafeValue, digest, encode, known_secrets,
                     require_reference_runtime, write_json, write_jsonl)

ROOT = Path(__file__).resolve().parents[2]
_VOLATILE_TEST_FUNCTIONS = {
    'server.manual_entities._base', 'server.manual_entities.mentions',
    'server.manual_entities.restore', 'server.manual_entities.rows',
    'server.marginalia._key', 'server.notebook.validate',
}


def _contains_test_revision(value: object) -> bool:
    if isinstance(value, dict):
        if any(key in value for key in ('created', 'updated', 'graph_revision')):
            return True
        return any(_contains_test_revision(item) for item in value.values())
    if isinstance(value, (list, tuple)):
        return any(_contains_test_revision(item) for item in value)
    return False


def included_functions(path: Path | None, inventory: Path) -> tuple[set[str], dict[tuple[str, int], str]]:
    if not inventory.is_file():
        raise ValueError(f'no machine-readable inventory at {inventory}')
    records = json.loads(inventory.read_text(encoding='utf-8'))['functions']
    locations = {(row['source'], row['line']): row['id'] for row in records}
    if len(locations) != len(records):
        raise ValueError('inventory has duplicate source/line identities')
    if path is not None:
        result = {line.strip() for line in path.read_text(encoding='utf-8').splitlines()
                  if line.strip() and not line.lstrip().startswith('#')}
        missing = result - {row['id'] for row in records}
        if missing:
            raise ValueError(f'include list has ids absent from inventory: {sorted(missing)}')
    else:
        result = {row['id'] for row in records if row['category'] == '纯函数'}
    if not result:
        raise ValueError('no pure functions selected')
    return result, locations


class Collector:
    def __init__(self, include: set[str], locations: dict[tuple[str, int], str],
                 secrets: tuple[str, ...], maximum: int):
        self.include = include
        self.locations = locations
        self.secrets = secrets
        self.maximum = maximum
        self.samples: dict[str, dict[str, dict]] = {}
        self.outputs: dict[str, dict[str, str]] = {}
        self.calls = Counter()
        self.skipped = Counter()
        self.rejected_corpus = []
        self.conflicts: dict[str, set[str]] = {}
        self.lock = threading.Lock()
        self.phase = 'none'

    def trace(self, frame, event, arg):
        if event != 'call':
            return None
        path = Path(frame.f_code.co_filename)
        try:
            rel = path.resolve().relative_to(ROOT)
        except ValueError:
            return None
        if rel.parts[0] not in ('pipeline', 'server') or rel.suffix != '.py':
            return None
        actual = '.'.join(rel.with_suffix('').parts) + '.' + frame.f_code.co_qualname.replace('.<locals>.', '.')
        function = self.locations.get((str(rel), frame.f_code.co_firstlineno))
        if function is not None and function.partition('@L')[0] != actual:
            raise RuntimeError(f'inventory function identity is stale at {rel}:{frame.f_code.co_firstlineno}')
        if function is None:
            function = actual
        if function not in self.include:
            return None
        names = frame.f_code.co_varnames[:frame.f_code.co_argcount + frame.f_code.co_kwonlyargcount]
        var_count = frame.f_code.co_argcount + frame.f_code.co_kwonlyargcount
        if frame.f_code.co_flags & 0x04:  # *args
            names += frame.f_code.co_varnames[var_count:var_count + 1]
            var_count += 1
        if frame.f_code.co_flags & 0x08:  # **kwargs
            names += frame.f_code.co_varnames[var_count:var_count + 1]
        inputs = {name: frame.f_locals[name] for name in names if name in frame.f_locals}
        if self.phase == 'unittest' and function in _VOLATILE_TEST_FUNCTIONS and \
                _contains_test_revision(inputs):
            with self.lock:
                self.skipped[(function, 'test-generated clock/inode input; fixed special oracle exists')] += 1
            return None
        if 'self' in inputs:
            inputs['self'] = ObjectView(inputs['self'], frozenset(frame.f_code.co_names))
        try:
            encoded = encode(inputs, self.secrets)
        except UnsafeValue as exc:
            with self.lock:
                self.skipped[(function, str(exc))] += 1
            return None
        had_exception = False
        last_exception = None

        def local(_frame, kind, result):
            nonlocal had_exception, last_exception
            if kind == 'exception':
                had_exception = True
                last_exception = result[1]
            elif kind == 'return':
                # CPython emits a return(None) trace event while an exception propagates.
                # A caught exception can also end in a legitimate return(None). The current
                # bytecode distinguishes them: explicit returns end at RETURN_VALUE, while
                # propagation ends at the raising/unwinding instruction.
                opcode = _frame.f_code.co_code[_frame.f_lasti] if _frame.f_lasti >= 0 else None
                explicit_return = opcode == dis.opmap['RETURN_VALUE']
                if had_exception and result is None and not explicit_return:
                    try:
                        if last_exception is None:
                            raise UnsafeValue('propagated exception was not available')
                        self.add(function, encoded, encode(last_exception, self.secrets))
                    except UnsafeValue as exc:
                        with self.lock:
                            self.skipped[(function, str(exc))] += 1
                else:
                    try:
                        output = encode(result, self.secrets)
                        self.add(function, encoded, output)
                    except UnsafeValue as exc:
                        with self.lock:
                            self.skipped[(function, str(exc))] += 1
            return local

        return local

    def add(self, function: str, inputs: object, output: object) -> None:
        key = digest(inputs)
        out_hash = digest(output)
        with self.lock:
            self.calls[function] += 1
            prior = self.outputs.setdefault(function, {}).setdefault(key, out_hash)
            if prior != out_hash:
                self.conflicts.setdefault(function, set()).add(key)
                return
            items = self.samples.setdefault(function, {})
            if key not in items:
                items[key] = {'input': inputs, 'output': output}
                if len(items) > self.maximum:
                    items.pop(max(items))

    def save(self, out: Path) -> dict:
        for function, items in sorted(self.samples.items()):
            if function in self.conflicts:
                continue
            pieces = function.split('.')
            target = out.joinpath(*pieces[:-1], pieces[-1] + '.jsonl')
            write_jsonl(target, [items[key] for key in sorted(items)])
        report = {
            'selected': sorted(self.include),
            'unobserved': sorted(self.include - self.calls.keys()),
            'calls': {key: self.calls[key] for key in sorted(self.calls)},
            'sample_counts': {key: len(value) for key, value in sorted(self.samples.items())
                              if key not in self.conflicts},
            'skipped': [{'function': function, 'reason': reason, 'count': count}
                        for (function, reason), count in sorted(self.skipped.items())],
            'non_deterministic': [{'function': function, 'input_sha256': key}
                                  for function, keys in sorted(self.conflicts.items()) for key in sorted(keys)],
            'rejected_corpus': self.rejected_corpus,
        }
        write_json(out / 'record-report.json', report)
        return report


class LoopbackOnly:
    _PROXY_NAMES = ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy',
                    'all_proxy', 'FTP_PROXY', 'ftp_proxy')

    def __enter__(self):
        self.original = (socket.socket.connect, socket.socket.connect_ex, socket.socket.sendto)
        self.proxies = {name: os.environ.pop(name, None) for name in self._PROXY_NAMES}

        def check(address):
            if isinstance(address, tuple):
                host = address[0]
                try:
                    local = ipaddress.ip_address(host).is_loopback
                except ValueError:
                    local = host == 'localhost'
                if not local:
                    raise RuntimeError('function recorder blocks non-loopback network')

        def connect(sock, address):
            check(address)
            return self.original[0](sock, address)

        def connect_ex(sock, address):
            check(address)
            return self.original[1](sock, address)

        def sendto(sock, data, *args):
            check(args[-1])
            return self.original[2](sock, data, *args)

        socket.socket.connect = connect
        socket.socket.connect_ex = connect_ex
        socket.socket.sendto = sendto
        return self

    def __exit__(self, *_):
        socket.socket.connect, socket.socket.connect_ex, socket.socket.sendto = self.original
        for name, value in self.proxies.items():
            if value is not None:
                os.environ[name] = value


def run_python_tests() -> bool:
    tests = unittest.TestLoader().discover(str(ROOT / 'tests'), pattern='test*.py')
    return unittest.TextTestRunner(verbosity=1).run(tests).wasSuccessful()


def run_corpus(path: Path, collector: Collector) -> None:
    from pipeline.parse import parse_file
    manifest = json.loads((path / 'manifest.json').read_text(encoding='utf-8'))
    entries = manifest['files']
    expected_rejections = json.loads((ROOT / 'oracle/record/expected_rejections.json').read_text(encoding='utf-8'))
    with tempfile.TemporaryDirectory(prefix='thusfar-oracle-corpus-') as tmp:
        for source in sorted(path.rglob('*')):
            if source.is_file() and source.suffix.lower() in ('.txt', '.epub'):
                rel = str(source.relative_to(path))
                if rel not in entries:
                    raise ValueError(f'corpus file absent from manifest: {rel}')
                expected = expected_rejections.get(rel)
                try:
                    parse_file(source, Path(tmp) / digest(rel)[:12])
                except Exception as exc:
                    if not expected:
                        raise RuntimeError(f'unexpected parser rejection for {rel}') from exc
                    if isinstance(expected, str):
                        matches = expected in (type(exc).__name__, str(exc)) or expected in str(exc)
                    else:
                        matches = (expected.get('type') in (None, type(exc).__name__) and
                                   expected.get('message', '') in str(exc))
                    if not matches:
                        raise RuntimeError(f'parser rejection for {rel} did not match manifest') from exc
                    collector.rejected_corpus.append({'path': rel, 'exception': type(exc).__name__,
                                                      'message': str(exc)})
                else:
                    if expected:
                        raise RuntimeError(f'corpus file {rel} was expected to be rejected')


def run_manual(path: Path) -> None:
    for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        if not line.strip():
            continue
        case = json.loads(line)
        name = case['function']
        parts = name.split('.')
        module = importlib.import_module('.'.join(parts[:2]))
        target = module
        for part in parts[2:]:
            target = getattr(target, part)
        try:
            target(*case.get('args', []), **case.get('kwargs', {}))
        except Exception as exc:
            raise RuntimeError(f'manual case {number} ({name}) failed') from exc


def run_book_replay(source: Path, cassettes: Path, start: str, concurrency: int) -> None:
    from .artifacts import stage_book
    from .cassettes import install
    model = 'deepseek-flash+nothink'
    names = ('LLM_BASE_URL', 'LLM_BASE_URL_OPENAI', 'LLM_PROTOCOL', 'LLM_PROTOCOL_MAP',
             'LLM_KEY_NAME', 'LLM_KEY_MAP', 'ORACLE_REPLAY_KEY',
             'JEV_ROUTE', 'CLASSIFIER_URL', 'JUDGE_LOG_DIR', 'JUDGE_LOG',
             'EXTRACT_MODEL', 'LOCAL_MODEL', 'RECAP_MODEL', 'JUDGE_MODEL', 'CLASSIFY_MODEL')
    previous = {name: os.environ.get(name) for name in names}
    with tempfile.TemporaryDirectory(prefix='thusfar-oracle-function-book-') as tmp:
        root = Path(tmp) / source.name
        os.environ.update(LLM_BASE_URL='https://open.xiaojingai.com/v1',
                          LLM_BASE_URL_OPENAI='https://open.xiaojingai.com/v1',
                          LLM_PROTOCOL='openai', LLM_PROTOCOL_MAP='deepseek-flash=openai',
                          LLM_KEY_NAME='ORACLE_REPLAY_KEY',
                          LLM_KEY_MAP='deepseek-flash=ORACLE_REPLAY_KEY',
                          ORACLE_REPLAY_KEY='oracle-placeholder', JEV_ROUTE='free-only',
                          CLASSIFIER_URL='https://classifier.dev/v1/classify',
                          JUDGE_LOG_DIR=str(Path(tmp) / 'judge'), JUDGE_LOG='0',
                          EXTRACT_MODEL=model, LOCAL_MODEL=model, RECAP_MODEL=model,
                          JUDGE_MODEL=model, CLASSIFY_MODEL=model)
        try:
            stage_book(source, root, start)
            from pipeline import llm
            from pipeline.run import run_book
            from pipeline import run
            old_classifier, old_recap = llm.CLASSIFIER_URL, run.RECAP_MODEL
            llm.CLASSIFIER_URL, run.RECAP_MODEL = 'https://classifier.dev/v1/classify', model
            try:
                with install(cassettes, 'replay'):
                    run_book(root, model=model, local_model=model, concurrency=concurrency)
            finally:
                llm.CLASSIFIER_URL, run.RECAP_MODEL = old_classifier, old_recap
        finally:
            for name, value in previous.items():
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value


def main() -> int:
    require_reference_runtime()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--include', type=Path)
    parser.add_argument('--inventory', type=Path, default=ROOT / 'docs/port/inventory.json')
    parser.add_argument('--unittest', action='store_true')
    parser.add_argument('--corpus', type=Path)
    parser.add_argument('--manual', type=Path)
    parser.add_argument('--script', type=Path, help='additional Python workload to execute')
    parser.add_argument('--replay-book', type=Path, action='append', default=[])
    parser.add_argument('--cassettes', type=Path, default=ROOT / 'oracle/cassettes')
    parser.add_argument('--book-start', choices=('fresh', 'resume'), default='fresh')
    parser.add_argument('--concurrency', type=int, default=12)
    parser.add_argument('--out', type=Path, default=ROOT / 'oracle/goldens')
    parser.add_argument('--maximum', type=int, default=200)
    args = parser.parse_args()
    if args.maximum < 1 or args.maximum > 200:
        parser.error('--maximum must be between 1 and 200')
    if not any((args.unittest, args.corpus, args.manual, args.script, args.replay_book)):
        parser.error('choose at least one workload')
    if args.out.exists() and any(args.out.iterdir()):
        parser.error('--out must be empty to prevent stale goldens from a previous run')
    include, locations = included_functions(args.include, args.inventory)
    collector = Collector(include, locations, known_secrets(), args.maximum)
    old_trace, old_thread_trace = sys.gettrace(), threading.gettrace()
    ok = True
    try:
        with LoopbackOnly():
            sys.settrace(collector.trace)
            threading.settrace(collector.trace)
            if args.manual:
                collector.phase = 'manual'
                run_manual(args.manual)
            if args.unittest:
                collector.phase = 'unittest'
                ok = run_python_tests() and ok
            if args.corpus:
                collector.phase = 'corpus'
                run_corpus(args.corpus, collector)
            if args.script:
                collector.phase = 'script'
                runpy.run_path(str(args.script), run_name='__main__')
            for source in args.replay_book:
                collector.phase = 'book-replay'
                run_book_replay(source, args.cassettes, args.book_start, args.concurrency)
    finally:
        sys.settrace(old_trace)
        threading.settrace(old_thread_trace)
    report = collector.save(args.out)
    print(f"recorded {sum(report['sample_counts'].values())} samples across "
          f"{len(report['sample_counts'])} functions; unobserved={len(report['unobserved'])}; "
          f"skipped={sum(row['count'] for row in report['skipped'])}; "
          f"non-deterministic={len(report['non_deterministic'])}")
    return 0 if ok and not report['non_deterministic'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
