"""Private model configuration for the embedded Android server."""
from __future__ import annotations

import os
import re
import sys
import tempfile
import time
import urllib.parse
from pathlib import Path

DEFAULT_URL = 'https://api.deepseek.com/v1'
DEFAULT_MODEL = 'deepseek-flash+nothink'
ROUTES = ('free-only',)


def _file() -> Path:
    return Path(os.environ['SECRETS_FILE'])


def read() -> dict:
    path = _file()
    values = {}
    if path.exists():
        for line in path.read_text().splitlines():
            name, sep, value = line.partition('=')
            if sep and name in ('LLM_BASE_URL', 'LLM_API_KEY', 'EXTRACT_MODEL', 'JEV_ROUTE'):
                values[name] = value
    # settings saved by 1.7.x before normalize() existed are corrected on read
    url, model = normalize(values.get('LLM_BASE_URL') or DEFAULT_URL, values.get('EXTRACT_MODEL') or DEFAULT_MODEL)
    return {'base_url': url,
            'model': model,
            'jev_route': values.get('JEV_ROUTE') or 'free-only',
            'api_key': values.get('LLM_API_KEY') or ''}


def public() -> dict:
    settings = read()
    key = settings.pop('api_key')
    settings['api_key_set'] = bool(key)
    settings['api_key_last4'] = key[-4:] if key else ''
    return settings


def apply_environment():
    settings = read()
    model = settings['model']
    for name in ('EXTRACT_MODEL', 'LOCAL_MODEL', 'RECAP_MODEL', 'JUDGE_MODEL',
                 'CLASSIFY_MODEL', 'QA_MODEL', 'MARGINALIA_MODEL', 'MARGINALIA_AUTO_MODEL'):
        os.environ[name] = model
    os.environ['JEV_ROUTE'] = settings['jev_route']
    # the pipeline reads the address itself; hand it the corrected one (environment wins over the file)
    os.environ['LLM_BASE_URL'] = settings['base_url']
    # These modules bind their default model at import time. A saved change must
    # also affect questions and reader comments in this already-running process.
    for module, names in (('server.ask', ('QA_MODEL',)),
                          ('server.marginalia', ('MODEL', 'AUTO_MODEL'))):
        loaded = sys.modules.get(module)
        if loaded is not None:
            for name in names:
                setattr(loaded, name, model)
    from pipeline import llm
    with llm._env_lock:
        llm._env_cache = None


def normalize(url: str, model: str) -> tuple[str, str]:
    """An OpenAI-compatible address with no path is almost always missing /v1 (the bare host
    serves the provider's web page), and DeepSeek V4 thinks by default, spending the reply on
    reasoning; the pipeline needs its answer, so plain deepseek-* names get +nothink."""
    url = url.strip().rstrip('/')
    if urllib.parse.urlsplit(url).path in ('', '/'):
        url += '/v1'
    model = model.strip()
    if model.lower().startswith('deepseek-') and '+' not in model:
        model += '+nothink'
    return url, model


def test() -> dict:
    """One tiny request with the saved settings, so a wrong key or model shows up before a book."""
    from pipeline import llm
    settings = read()
    if not settings['api_key']:
        return {'ok': False, 'message': llm.explain(llm.LLMError('缺少模型访问密钥'))}
    started = time.time()
    try:
        text, _ = llm.chat(settings['model'], [{'role': 'user', 'content': '只回答两个字：可以'}],
                           max_tokens=16, temperature=0, timeout=30, retries=0)
    except Exception as exc:        # noqa: BLE001 - every failure is reported to the reader
        return {'ok': False, 'message': llm.explain(exc) or f'连接失败：{str(exc)[:200]}'}
    seconds = time.time() - started
    message = f'连接成功：{settings["model"]} 用 {seconds:.1f} 秒回复了「{text.strip()[:20]}」'
    if seconds > 8:
        # a two-word reply this slow means minutes per passage when processing a book
        message += '。这个模型回复很慢，整理一本书会花很长时间（每段可能要几分钟）；想快一些可以换 deepseek-flash+nothink'
    return {'ok': True, 'message': message}


def save(payload: dict) -> dict:
    current = read()
    url = payload.get('base_url', current['base_url'])
    model = payload.get('model', current['model'])
    route = payload.get('jev_route', current['jev_route'])
    key = payload.get('api_key', '')
    if not isinstance(url, str) or len(url) > 500 or any(ord(c) <= 32 or ord(c) == 127 for c in url):
        raise ValueError('模型接口地址无效')
    parsed = urllib.parse.urlsplit(url.strip())
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError('模型接口请填写 HTTPS 地址，不要包含账号、参数或片段')
    if not isinstance(model, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._/+:-]{0,99}', model):
        raise ValueError('模型名称无效')
    if route not in ROUTES:
        raise ValueError('JEV 路线无效')
    if not isinstance(key, str) or len(key) > 1024 or any(ord(c) < 33 or ord(c) > 126 for c in key):
        raise ValueError('API 密钥格式无效')
    if payload.get('clear_key') not in (None, False, True):
        raise ValueError('清除密钥选项无效')
    if key and payload.get('clear_key'):
        raise ValueError('不能同时填写和清除密钥')
    effective_key = '' if payload.get('clear_key') else key or current['api_key']
    url, model = normalize(url, model)
    values = {'LLM_BASE_URL': url.strip().rstrip('/'), 'LLM_API_KEY': effective_key,
              'EXTRACT_MODEL': model, 'JEV_ROUTE': route}
    path = _file()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.model-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as handle:
            os.fchmod(handle.fileno(), 0o600)
            handle.write(''.join(f'{name}={value}\n' for name, value in values.items()))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        os.chmod(path, 0o600)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    apply_environment()
    return public()
