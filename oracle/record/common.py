"""Stable, secret-aware data encoding shared by the Python oracle recorders."""
from __future__ import annotations

import base64
import dataclasses
import hashlib
import json
import math
import os
import re
from pathlib import Path


class UnsafeValue(ValueError):
    """A value cannot safely or faithfully be included in a committed oracle."""


_SECRET_NAME = re.compile(r'(?:^|_)(?:api_?key|password|passcode|secret|token|authorization|cookie)(?:$|_)', re.I)
_SECRET_LITERAL = re.compile(r'(?i)\b(?:bearer\s+|sk-)[A-Za-z0-9_\-]{12,}')


def known_secrets() -> tuple[str, ...]:
    """Read candidate keys for rejection only; never write or display their values."""
    values = [v for k, v in os.environ.items()
              if _SECRET_NAME.search(k) and not k.endswith(('_FILE', '_NAME', '_URL')) and len(v) >= 8]
    path = Path.home() / '.env'
    if path.is_file():
        for line in path.read_text(encoding='utf-8').splitlines():
            match = re.match(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$', line)
            if match and _SECRET_NAME.search(match.group(1)) and not match.group(1).endswith(('_FILE', '_NAME', '_URL')):
                value = match.group(2).strip('"\'')
                if len(value) >= 8:
                    values.append(value)
    return tuple(sorted(set(values), key=len, reverse=True))


def assert_public(value: str, secrets: tuple[str, ...]) -> None:
    if _SECRET_LITERAL.search(value) or any(secret in value for secret in secrets):
        raise UnsafeValue('credential-like text was rejected')


def encode(value: object, secrets: tuple[str, ...] = (), seen: set[int] | None = None) -> object:
    """Retain Python type and insertion order where JSON alone would lose them."""
    if value is None or isinstance(value, (bool, int)):
        return value
    if isinstance(value, str):
        assert_public(value, secrets)
        return value
    if isinstance(value, float):
        if math.isnan(value):
            return {'$float': 'nan'}
        if math.isinf(value):
            return {'$float': 'inf' if value > 0 else '-inf'}
        return value
    if isinstance(value, bytes):
        return {'$bytes': base64.b64encode(value).decode('ascii')}
    if isinstance(value, Path):
        return {'$path': encode(str(value), secrets)}
    seen = seen if seen is not None else set()
    ident = id(value)
    if ident in seen:
        raise UnsafeValue('cyclic value was rejected')
    seen.add(ident)
    try:
        if isinstance(value, (list, tuple)):
            items = [encode(x, secrets, seen) for x in value]
            return {'$tuple': items} if isinstance(value, tuple) else items
        if isinstance(value, (set, frozenset)):
            items = [encode(x, secrets, seen) for x in value]
            items.sort(key=canonical)
            return {'$set': items}
        if isinstance(value, dict):
            for key in value:
                if isinstance(key, str) and _SECRET_NAME.search(key):
                    raise UnsafeValue('credential field was rejected')
            if all(isinstance(key, str) for key in value):
                return {key: encode(item, secrets, seen) for key, item in value.items()}
            return {'$map': [[encode(key, secrets, seen), encode(item, secrets, seen)]
                             for key, item in value.items()]}
        if dataclasses.is_dataclass(value) and not isinstance(value, type):
            fields = {field.name: encode(getattr(value, field.name), secrets, seen)
                      for field in dataclasses.fields(value)}
            return {'$object': f'{type(value).__module__}.{type(value).__qualname__}', 'fields': fields}
        raise UnsafeValue(f'unsupported type {type(value).__module__}.{type(value).__qualname__}')
    finally:
        seen.remove(ident)


def canonical(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False)


def digest(value: object) -> str:
    return hashlib.sha256(canonical(value).encode('utf-8')).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.recording')
    tmp.write_text(canonical(value) + '\n', encoding='utf-8')
    tmp.replace(path)


def write_jsonl(path: Path, rows: list[object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.recording')
    tmp.write_text(''.join(canonical(row) + '\n' for row in rows), encoding='utf-8')
    tmp.replace(path)
