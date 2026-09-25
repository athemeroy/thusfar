"""Run a copied Python book through the model/JEV cassette transport.

Record mode performs real calls only after explicit invocation with attempt caps. Replay mode
uses placeholder credentials and cannot open remote sockets.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path

from .artifacts import stage_book
from .cassettes import install
from .common import digest, require_reference_runtime, write_json
from .functions import LoopbackOnly
from .scan import scan

ROOT = Path(__file__).resolve().parents[2]
_SETTINGS = ('LLM_BASE_URL', 'LLM_BASE_URL_OPENAI', 'LLM_PROTOCOL', 'LLM_PROTOCOL_MAP',
             'LLM_KEY_NAME', 'LLM_KEY_MAP', 'ORACLE_REPLAY_KEY',
             'EXTRACT_MODEL', 'LOCAL_MODEL', 'RECAP_MODEL', 'JUDGE_MODEL', 'CLASSIFY_MODEL',
             'JEV_ROUTE', 'CLASSIFIER_URL', 'JUDGE_LOG_DIR', 'JUDGE_LOG')
_RECEIPT = '.oracle-record.json'


def source_identity(source_book: Path) -> str:
    rows = {}
    for path in sorted(source_book.rglob('*')):
        if path.is_symlink():
            raise ValueError('source book contains a symlink')
        if path.is_file():
            rows[str(path.relative_to(source_book))] = hashlib.sha256(path.read_bytes()).hexdigest()
    if 'book.json' not in rows:
        raise ValueError('source book has no book.json')
    return digest(rows)


def prepare_working_book(source_book: Path, working_book: Path, cassettes: Path,
                         start: str, resume_existing: bool) -> None:
    identity = source_identity(source_book)
    receipt_path = working_book / _RECEIPT
    expected = {'schema': 1, 'model': 'deepseek-flash+nothink',
                'source_path': str(source_book.resolve()), 'source_sha256': identity,
                'cassettes_path': str(cassettes.resolve()), 'start': start}
    if resume_existing:
        if not working_book.is_dir() or not receipt_path.is_file():
            raise ValueError('original working book has no oracle recording receipt')
        saved = json.loads(receipt_path.read_text(encoding='utf-8'))
        if saved != expected:
            raise ValueError('resume source, cassette ledger, model or start mode differs from original run')
        # A pending slot may represent a paid request whose result was lost. Reconcile that
        # original attempt before asking again; never retry it under a new work directory.
        scan(cassettes)
        return
    if working_book.exists():
        raise FileExistsError('working book already exists; use --resume-existing for the original run')
    stage_book(source_book, working_book, start)
    write_json(receipt_path, expected)


def main() -> None:
    require_reference_runtime()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source_book', type=Path)
    parser.add_argument('--working-book', type=Path, required=True)
    parser.add_argument('--resume-existing', action='store_true',
                        help='resume the exact prior working book and cassette ledger')
    parser.add_argument('--mode', choices=('record', 'replay'), required=True)
    parser.add_argument('--start', choices=('fresh', 'resume'), default='fresh')
    parser.add_argument('--cassettes', type=Path, default=ROOT / 'oracle/cassettes')
    parser.add_argument('--concurrency', type=int, default=12)
    parser.add_argument('--max-model-attempts', type=int, default=16)
    parser.add_argument('--max-jev-attempts', type=int, default=200)
    parser.add_argument('--max-cny', type=float, default=1.0,
                        help='cumulative model recording budget across this cassette directory, at most ¥1')
    args = parser.parse_args()
    if args.resume_existing and args.mode != 'record':
        parser.error('--resume-existing is only for the original live recording')
    if args.working_book.exists() and not args.resume_existing:
        parser.error('--working-book must not exist; use --resume-existing to reconcile prior paid work')
    if args.max_model_attempts < 1 or args.max_jev_attempts < 1:
        parser.error('attempt caps must be positive')
    if not 0 < args.max_cny <= 1.0:
        parser.error('--max-cny must be greater than zero and at most ¥1')
    if not (args.source_book / 'book.json').is_file():
        parser.error('source book has no book.json')
    previous = {key: os.environ.get(key) for key in _SETTINGS}
    model = 'deepseek-flash+nothink'
    os.environ.update(LLM_BASE_URL='https://open.xiaojingai.com/v1',
                      LLM_BASE_URL_OPENAI='https://open.xiaojingai.com/v1',
                      LLM_PROTOCOL='openai', LLM_PROTOCOL_MAP='deepseek-flash=openai',
                      LLM_KEY_NAME='NAS_DEFAULT_KEY' if args.mode == 'record' else 'ORACLE_REPLAY_KEY',
                      LLM_KEY_MAP=('deepseek-flash=NAS_DEFAULT_KEY' if args.mode == 'record'
                                   else 'deepseek-flash=ORACLE_REPLAY_KEY'),
                      EXTRACT_MODEL=model, LOCAL_MODEL=model, RECAP_MODEL=model,
                      JUDGE_MODEL=model, CLASSIFY_MODEL=model, JEV_ROUTE='free-only',
                      CLASSIFIER_URL='https://classifier.dev/v1/classify', JUDGE_LOG='0',
                      JUDGE_LOG_DIR=str(args.working_book / 'work' / 'judge'))
    if args.mode == 'replay':
        os.environ['ORACLE_REPLAY_KEY'] = 'oracle-placeholder'
    try:
        from pipeline import llm
        if args.mode == 'record' and not llm._env('NAS_DEFAULT_KEY'):
            parser.error('NAS_DEFAULT_KEY is unavailable; no live requests were made')
        prepare_working_book(args.source_book.resolve(), args.working_book.resolve(),
                             args.cassettes, args.start, args.resume_existing)
        from pipeline.run import run_book
        with install(args.cassettes, args.mode,
                     max_model_attempts=args.max_model_attempts,
                     max_jev_attempts=args.max_jev_attempts,
                     max_cny=args.max_cny) as tape:
            try:
                if args.mode == 'replay':
                    with LoopbackOnly():
                        run_book(args.working_book, model=model, local_model=model,
                                 concurrency=args.concurrency)
                else:
                    run_book(args.working_book, model=model, local_model=model,
                             concurrency=args.concurrency)
            finally:
                budget = tape.budget_summary()
                print(f'cassette {args.mode}: {tape.count} responses; '
                      f'model attempts={tape.attempts["model"]}; JEV attempts={tape.attempts["jev"]}; '
                      f'configured-rate token estimate=¥{budget["configured_rate_estimate_cny"]:.6f}; '
                      f'cumulative guarded charge=¥{budget["charged_cny"]:.6f}; '
                      f'usage unavailable={budget["usage_unavailable"]}; '
                      'actual gateway bill requires a provider receipt')
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


if __name__ == '__main__':
    main()
