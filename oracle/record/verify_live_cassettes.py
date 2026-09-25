"""Read-only audit of an opt-in DeepSeek/free-JEV live cassette directory.

Only counts, costs, and SHA-256 fingerprints are printed. Request/response bodies and
credentials are never printed or copied. This verifies the local tape and configured-rate
budget ledger; a provider billing receipt is still needed for the actual account charge.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import re
from collections import Counter
from decimal import Decimal
from pathlib import Path

from .cassettes import CassetteStore, _CONFIGURED_PRICE, _GUARD_PRICE
from .common import assert_public, canonical, digest, known_secrets
from .scan import inspect_value

SHA256 = re.compile(r'[0-9a-f]{64}\Z')
HEX_ID = re.compile(r'[0-9a-f]{32}\Z')
MODEL_URL = 'https://open.xiaojingai.com/v1/chat/completions'
JEV_URL = 'https://classifier.dev/v1/classify'
_LOCK_FILES = {'.budget.lock', '.tape.lock'}
_REPLY_HEADERS = {'content-type', 'content-encoding', 'retry-after'}


def _fail(reason: str) -> None:
    raise ValueError('live cassette verification failed: ' + reason)


def _unique_pairs(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            _fail('JSON has a duplicate key')
        out[key] = value
    return out


def _no_constant(_value):
    _fail('JSON contains a non-finite number')


def _read_json(path: Path):
    if path.is_symlink() or not path.is_file():
        _fail('a required tape or ledger is not a regular file')
    try:
        before = path.stat()
        if before.st_size > 64 * 1024 * 1024:
            _fail('a tape or ledger exceeds the audit size limit')
        raw = path.read_bytes()
        after = path.stat()
        if _signature(before) != _signature(after) or len(raw) != after.st_size:
            _fail('a tape or ledger changed during the read-only audit')
        value = json.loads(raw.decode('utf-8'), object_pairs_hook=_unique_pairs,
                           parse_constant=_no_constant)
        return value, hashlib.sha256(raw).hexdigest(), _signature(after)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        _fail(f'malformed JSON in {path.name}: {type(exc).__name__}')


def _signature(stat) -> tuple[int, int, int, int]:
    return (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns)


def _money(value, name: str) -> Decimal:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) \
            or value < 0:
        _fail(f'invalid {name}')
    return Decimal(str(value))


def _request_kind(envelope: dict, secrets: tuple[str, ...]) -> str:
    if not isinstance(envelope, dict) or set(envelope) != {'method', 'url', 'headers', 'body_utf8'} \
            or envelope['method'] != 'POST' or not isinstance(envelope['body_utf8'], str):
        _fail('request envelope shape or method changed')
    url = envelope['url']
    if url == MODEL_URL:
        kind = 'model'
        expected_headers = {'accept': 'text/event-stream', 'content-type': 'application/json'}
    elif url == JEV_URL:
        kind = 'jev'
        expected_headers = {'content-type': 'application/json'}
    else:
        _fail('request URL is outside the exact approved live endpoints')
    if envelope['headers'] != expected_headers:
        _fail('request headers differ from the key-free cassette envelope')
    assert_public(url + envelope['body_utf8'], secrets)
    try:
        body = json.loads(envelope['body_utf8'], object_pairs_hook=_unique_pairs,
                          parse_constant=_no_constant)
    except json.JSONDecodeError:
        _fail('request body is not JSON')
    if not isinstance(body, dict):
        _fail('request body is not an object')
    if kind == 'model':
        if set(body) != {'model', 'messages', 'max_tokens', 'temperature', 'stream',
                         'stream_options', 'thinking'} \
                or body['model'] != 'deepseek-flash' \
                or body['thinking'] != {'type': 'disabled'} \
                or body['stream'] is not True \
                or body['stream_options'] != {'include_usage': True}:
            _fail('model request differs from deepseek-flash+nothink streaming envelope')
        messages = body['messages']
        if not isinstance(messages, list) or not messages or any(
                not isinstance(message, dict) or set(message) != {'role', 'content'}
                or message['role'] not in ('system', 'user', 'assistant')
                or not isinstance(message['content'], str) for message in messages):
            _fail('model messages have an unreviewed shape')
        cap = body['max_tokens']
        temperature = body['temperature']
        if isinstance(cap, bool) or not isinstance(cap, int) or cap < 1 \
                or isinstance(temperature, bool) or not isinstance(temperature, (int, float)) \
                or not math.isfinite(temperature) or not 0 <= temperature <= 2:
            _fail('model token cap or temperature is invalid')
    else:
        if set(body) != {'items', 'dimensions'} or not isinstance(body['items'], list) \
                or len(body['items']) != 1 or not isinstance(body['items'][0], str) \
                or not isinstance(body['dimensions'], dict) or not body['dimensions'] \
                or len(body['dimensions']) > 20:
            _fail('free JEV request differs from classifier.dev envelope')
        for index, (key, dimension) in enumerate(body['dimensions'].items()):
            if key != f'd{index}' or not isinstance(dimension, dict) \
                    or set(dimension) != {'labels', 'instructions'} \
                    or not isinstance(dimension['instructions'], str) \
                    or not isinstance(dimension['labels'], list) or not dimension['labels'] \
                    or any(not isinstance(label, str) or not label
                           for label in dimension['labels']) \
                    or len(set(dimension['labels'])) != len(dimension['labels']):
                _fail('free JEV dimension has an unreviewed shape')
    return kind


def _attempt(attempt: dict, secrets: tuple[str, ...]) -> None:
    if not isinstance(attempt, dict):
        _fail('cassette attempt is not an object')
    kind = attempt.get('kind')
    if kind == 'pending':
        _fail('a live attempt is still pending')
    if kind == 'response':
        allowed = {'kind', 'status', 'headers', 'chunks_base64'}
        if 'read_error' in attempt:
            allowed.add('read_error')
        if set(attempt) != allowed or isinstance(attempt['status'], bool) \
                or not isinstance(attempt['status'], int) or not 200 <= attempt['status'] < 300 \
                or not isinstance(attempt['chunks_base64'], list):
            _fail('response attempt shape or status is invalid')
        chunks = attempt['chunks_base64']
        if any(not isinstance(chunk, str) for chunk in chunks):
            _fail('response chunks are not base64 strings')
        try:
            raw = b''.join(base64.b64decode(chunk, validate=True) for chunk in chunks)
        except (ValueError, base64.binascii.Error):
            _fail('response chunk has invalid base64')
        if len(raw) > 16 * 1024 * 1024:
            _fail('response exceeds the Python client size limit')
        if 'read_error' in attempt:
            _error(attempt['read_error'])
    elif kind == 'http_error':
        if set(attempt) != {'kind', 'status', 'reason', 'headers', 'body_base64'} \
                or isinstance(attempt['status'], bool) or not isinstance(attempt['status'], int) \
                or not 300 <= attempt['status'] < 600 or not isinstance(attempt['reason'], str) \
                or not isinstance(attempt['body_base64'], str):
            _fail('HTTP error attempt shape or status is invalid')
        try:
            base64.b64decode(attempt['body_base64'], validate=True)
        except (ValueError, base64.binascii.Error):
            _fail('HTTP error body has invalid base64')
    elif kind == 'error':
        if set(attempt) != {'kind', 'error'}:
            _fail('transport error attempt shape is invalid')
        _error(attempt['error'])
    else:
        _fail('cassette attempt kind is not replayable')
    headers = attempt.get('headers', {})
    if not isinstance(headers, dict) or any(
            not isinstance(key, str) or key.lower() not in _REPLY_HEADERS
            or not isinstance(value, str) for key, value in headers.items()):
        _fail('response headers contain unreviewed or credential fields')
    inspect_value(attempt, secrets, Path('<cassette>'))


def _error(value) -> None:
    if not isinstance(value, dict) or set(value) != {'type', 'message'} \
            or value['type'] not in ('TimeoutError', 'socket.timeout', 'URLError',
                                    'ConnectionError', 'ConnectionResetError',
                                    'BrokenPipeError', 'OSError') \
            or not isinstance(value['message'], str):
        _fail('transport error has an unreviewed type or shape')


def _overlap_groups(tape: dict) -> None:
    groups = tape['overlap_groups']
    attempts = tape['attempts']
    if not isinstance(groups, list):
        _fail('overlap groups are invalid')
    seen = set()
    for group in groups:
        if not isinstance(group, list) or len(group) < 2 \
                or any(isinstance(index, bool) or not isinstance(index, int)
                       or index < 0 or index >= len(attempts) for index in group) \
                or sorted(set(group)) != group or seen.intersection(group):
            _fail('overlap group indexes are invalid or repeated')
        seen.update(group)
        if any(attempts[index] != attempts[group[0]] for index in group[1:]):
            _fail('concurrent identical requests have ambiguous replies')


def _client_visible_usage(attempt: dict) -> tuple[int, int] | None:
    """Parse streamed usage through [DONE], as chat() would consume it."""
    if attempt['kind'] != 'response':
        return None
    raw = b''.join(base64.b64decode(chunk, validate=True)
                   for chunk in attempt['chunks_base64'])
    usage = None
    for line in raw.decode('utf-8', 'replace').splitlines():
        if not line.startswith('data:'):
            continue
        content = line[5:].strip()
        if content == '[DONE]':
            break
        try:
            event = json.loads(content)
        except json.JSONDecodeError:
            continue
        candidate = event.get('usage') if isinstance(event, dict) else None
        if not isinstance(candidate, dict):
            continue
        prompt, completion = candidate.get('prompt_tokens'), candidate.get('completion_tokens')
        if all(isinstance(value, int) and not isinstance(value, bool) and value >= 0
               for value in (prompt, completion)):
            usage = (prompt, completion)
    return usage


def _tape(path: Path, secrets: tuple[str, ...]) -> tuple[str, dict, str, tuple[int, int, int, int]]:
    tape, file_sha, signature = _read_json(path)
    if not isinstance(tape, dict) or set(tape) != {
            'schema', 'request_sha256', 'request', 'attempts', 'overlap_groups'} \
            or tape['schema'] != 1 or tape['request_sha256'] != path.stem \
            or not isinstance(tape['attempts'], list) or not tape['attempts']:
        _fail('cassette tape schema, digest, or attempts are invalid')
    envelope = tape['request']
    if digest(envelope) != path.stem:
        _fail('cassette request digest differs from filename')
    kind = _request_kind(envelope, secrets)
    for attempt in tape['attempts']:
        _attempt(attempt, secrets)
        if kind == 'model' and _client_visible_usage(attempt) != CassetteStore._stream_usage(attempt):
            _fail('model token usage occurs after the client-visible stream end')
    _overlap_groups(tape)
    inspect_value(tape, secrets, path)
    return kind, tape, file_sha, signature


def _ledger(path: Path, model_attempts: Counter, model_envelopes: dict) -> \
        tuple[dict, str, tuple[int, int, int, int]]:
    ledger, file_sha, signature = _read_json(path)
    if not isinstance(ledger, dict) or set(ledger) != {'schema', 'max_cny', 'entries'} \
            or ledger['schema'] != 1 or not isinstance(ledger['entries'], list):
        _fail('budget ledger schema is invalid')
    max_cny = _money(ledger['max_cny'], 'max_cny')
    if not Decimal('0') < max_cny <= Decimal('1'):
        _fail('budget ledger maximum exceeds ¥1')
    actual = Counter()
    ids = set()
    configured_total = Decimal('0')
    charged_total = Decimal('0')
    unavailable = 0
    for entry in ledger['entries']:
        if not isinstance(entry, dict) or not {'id', 'request_sha256', 'reserved_cny',
                                               'charged_cny', 'state'} <= set(entry):
            _fail('budget ledger entry is malformed')
        row_id, sha = entry['id'], entry['request_sha256']
        if not isinstance(row_id, str) or not HEX_ID.fullmatch(row_id) or row_id in ids \
                or not isinstance(sha, str) or not SHA256.fullmatch(sha) \
                or sha not in model_envelopes:
            _fail('budget ledger ID or model request digest is invalid')
        ids.add(row_id)
        reserved = _money(entry['reserved_cny'], 'reserved_cny')
        charged = _money(entry['charged_cny'], 'charged_cny')
        expected_reservation = Decimal(str(CassetteStore._upper_bound(model_envelopes[sha])))
        if reserved != expected_reservation or charged > reserved:
            _fail('budget reservation or charge differs from preflight bound')
        state = entry['state']
        if state == 'completed':
            if set(entry) != {'id', 'request_sha256', 'reserved_cny', 'charged_cny',
                              'state', 'prompt_tokens', 'completion_tokens',
                              'configured_rate_estimate_cny', 'guarded_usage_cny'}:
                _fail('completed ledger entry has unexpected fields')
            prompt, completion = entry['prompt_tokens'], entry['completion_tokens']
            if any(isinstance(value, bool) or not isinstance(value, int) or value < 0
                   for value in (prompt, completion)):
                _fail('ledger token usage is invalid')
            configured = Decimal(str(round((prompt * _CONFIGURED_PRICE[0] +
                                            completion * _CONFIGURED_PRICE[1]) / 1_000_000, 9)))
            guarded = Decimal(str(round((prompt * _GUARD_PRICE[0] +
                                         completion * _GUARD_PRICE[1]) / 1_000_000, 9)))
            if _money(entry['configured_rate_estimate_cny'], 'configured estimate') != configured \
                    or _money(entry['guarded_usage_cny'], 'guarded usage') != guarded \
                    or charged != guarded:
                _fail('ledger charge does not match recorded streamed token usage')
            actual[(sha, (prompt, completion))] += 1
            configured_total += configured
        elif state == 'usage_unavailable':
            if set(entry) != {'id', 'request_sha256', 'reserved_cny', 'charged_cny', 'state'} \
                    or charged != reserved:
                _fail('missing-usage entry did not retain its full reservation')
            actual[(sha, None)] += 1
            unavailable += 1
        else:
            _fail('budget ledger contains an unsettled or over-bound reservation')
        charged_total += charged
    if actual != model_attempts:
        _fail('budget ledger entries do not match model tape attempts and usage')
    if charged_total > max_cny:
        _fail('cumulative guarded model charge exceeds the ¥1 ceiling')
    return ({'max_cny': float(max_cny), 'configured_rate_estimate_cny': float(configured_total),
             'guarded_charged_cny': float(charged_total), 'model_attempts': len(ledger['entries']),
             'usage_unavailable': unavailable}, file_sha, signature)


def verify(directory: Path) -> dict:
    if directory.is_symlink() or not directory.is_dir():
        _fail('cassette directory is not a regular directory')
    secrets = known_secrets()
    tape_paths = []
    hashes = {}
    ledger_path = directory / 'budget-ledger.json'
    for path in sorted(directory.iterdir()):
        if path.is_symlink() or not path.is_file():
            _fail('cassette directory contains a symlink or non-regular entry')
        if path.name in _LOCK_FILES:
            continue
        if path.name == ledger_path.name:
            continue
        if not SHA256.fullmatch(path.stem) or path.suffix != '.json':
            _fail('cassette directory contains an unreviewed file')
        tape_paths.append(path)
    if not tape_paths:
        _fail('cassette directory has no live request tapes')
    if ledger_path.is_symlink() or not ledger_path.is_file():
        _fail('cassette directory has no regular budget ledger')
    signatures = {}
    counts = Counter()
    model_attempts = Counter()
    model_envelopes = {}
    for path in tape_paths:
        kind, tape, file_sha, signature = _tape(path, secrets)
        hashes[path.name] = file_sha
        signatures[path.name] = signature
        counts[kind + '_tapes'] += 1
        if kind == 'model':
            model_envelopes[path.stem] = tape['request']
        for attempt in tape['attempts']:
            counts[kind + '_attempts'] += 1
            counts[attempt['kind']] += 1
            if kind == 'model':
                model_attempts[(path.stem, CassetteStore._stream_usage(attempt))] += 1
    budget, ledger_sha, ledger_signature = _ledger(ledger_path, model_attempts, model_envelopes)
    hashes[ledger_path.name] = ledger_sha
    signatures[ledger_path.name] = ledger_signature
    if {path.name for path in directory.iterdir()} != \
            set(hashes) | ({name for name in _LOCK_FILES if (directory / name).exists()}):
        _fail('cassette directory file set changed during the read-only audit')
    for name, signature in signatures.items():
        path = directory / name
        if path.is_symlink() or _signature(path.stat()) != signature:
            _fail('a tape or ledger changed during the read-only audit')
    if counts['model_attempts'] != budget['model_attempts']:
        _fail('model tape count differs from budget ledger entry count')
    result = {
        'schema': 1, 'source': 'read-only local live cassette audit',
        'tape_tree_sha256': digest(dict(sorted(hashes.items()))), 'json_files': len(tape_paths) + 1,
        'tape_files': len(tape_paths), 'attempts': counts['model_attempts'] + counts['jev_attempts'],
        'model_tapes': counts['model_tapes'], 'model_attempts': counts['model_attempts'],
        'free_jev_tapes': counts['jev_tapes'], 'free_jev_attempts': counts['jev_attempts'],
        'responses': counts['response'], 'http_errors': counts['http_error'],
        'transport_errors': counts['error'], 'budget': budget,
        'actual_provider_bill': 'unknown without gateway receipt',
    }
    if result['responses'] + result['http_errors'] + result['transport_errors'] != result['attempts']:
        _fail('attempt kind counts do not add up')
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path, help='existing live cassette directory; never modified')
    parser.add_argument('--expect-report', type=Path,
                        help='previously saved verifier JSON, outside the cassette directory')
    args = parser.parse_args()
    result = verify(args.directory)
    if args.expect_report is not None and _read_json(args.expect_report)[0] != result:
        _fail('current tape counts, costs, or tree hash differ from expected report')
    print(canonical(result))


if __name__ == '__main__':
    main()
