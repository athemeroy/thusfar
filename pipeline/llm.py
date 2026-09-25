"""Minimal stdlib clients for the OpenAI-compatible LLM gateway and the Jev decision model."""
from __future__ import annotations

import hashlib
import json
import math
import os
import random
import re
import threading
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from contextvars import ContextVar
from email.utils import parsedate_to_datetime
from pathlib import Path

from .provenance import digest, reserve_paid

GATEWAY = os.environ.get('LLM_BASE_URL', 'https://api.deepseek.com/v1')
# Jev can be reached directly or through a gateway that carries it (Vercel's AI Gateway lists
# typesafe-ai/jev at the same price). JEV_URL / JEV_MODEL / JEV_KEY_NAME switch routes.
JEV_URL = os.environ.get('JEV_URL', 'https://ai-gateway.vercel.sh/v1/evaluate')
JEV_MODEL = os.environ.get('JEV_MODEL', 'typesafe-ai/jev')

_env_cache: dict[str, str] | None = None
_env_lock = threading.Lock()
# what the judge actually costs: it is priced on input, and every question carries a passage
JEV_STATS = {'calls': 0, 'chars': 0, 'questions': 0, 'paid_chars': 0, 'passage_chars': 0}
_stats_lock = threading.Lock()
_route_context = threading.local()


def _env(name: str) -> str | None:
    if os.environ.get(name):
        return os.environ[name]
    global _env_cache
    with _env_lock:      # threads may ask at the same moment; publish the cache only when complete
        if _env_cache is None:
            cache: dict[str, str] = {}
            for f in (os.environ.get('SECRETS_FILE'), str(Path.home() / '.env')):
                if f and Path(f).exists():
                    for line in Path(f).read_text().splitlines():
                        m = re.match(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$', line)
                        if m and m.group(1) not in cache:
                            v = m.group(2)
                            if v[:1] in '"\'' and v[-1:] == v[:1]:
                                v = v[1:-1]
                            cache[m.group(1)] = v
            _env_cache = cache
    return _env_cache.get(name)


def _opener():
    # system proxy settings are honoured; LLM_BYPASS_PROXY=1 talks to the gateways directly
    if os.environ.get('LLM_BYPASS_PROXY'):
        return urllib.request.build_opener(urllib.request.ProxyHandler({}))
    return urllib.request.build_opener()


class LLMError(RuntimeError):
    pass


_FATAL = {
    401: 'API 密钥无效或已失效（HTTP 401），请到「模型设置」检查密钥',
    402: '模型账户余额不足（HTTP 402），请充值后再继续',
    403: '接口拒绝访问（HTTP 403），请检查密钥权限或接口地址',
    404: '接口地址或模型名不对（HTTP 404），请到「模型设置」检查',
}


def explain(error) -> str | None:
    """A reader-facing reason when retrying cannot help (no key, bad key, no balance, wrong model)."""
    text = str(error)
    if '缺少模型访问密钥' in text:
        return '还没有填写模型 API 密钥，请先到「模型设置」填写'
    m = re.search(r'HTTP (\d{3}): ?(.*)', text, re.S)
    if not m:
        return None
    code, detail = int(m.group(1)), m.group(2).strip()
    try:
        body = json.loads(detail)
        detail = ((body.get('error') or {}).get('message') if isinstance(body.get('error'), dict) else body.get('error')) or detail
    except ValueError:
        pass
    detail = str(detail)[:160]
    if code in _FATAL:
        return f'{_FATAL[code]}。接口返回：{detail}' if detail else _FATAL[code]
    if code in (400, 422):
        return f'接口不接受这个请求（HTTP {code}），多半是模型名不对。接口返回：{detail}'
    return None


class DeadlineExceeded(LLMError, TimeoutError):
    pass


_deadline = ContextVar('book_model_deadline', default=None)


@contextmanager
def request_budget(seconds: float):
    """One absolute budget across all model stages/retries of an HTTP request."""
    if not math.isfinite(seconds) or seconds <= 0:
        raise ValueError('请求预算必须大于零')
    end = time.monotonic() + seconds
    previous = _deadline.get()
    token = _deadline.set(min(end, previous) if previous is not None else end)
    try:
        yield
    finally:
        _deadline.reset(token)


def _remaining():
    end = _deadline.get()
    if end is None:
        return None
    remaining = end - time.monotonic()
    if remaining <= 0:
        raise DeadlineExceeded('请求已到总时限，已停止后续模型调用')
    return remaining


def _timeout(seconds):
    remaining = _remaining()
    return seconds if remaining is None else min(seconds, remaining)


def _sleep(seconds):
    remaining = _remaining()
    if remaining is not None and seconds >= remaining:
        raise DeadlineExceeded('剩余请求时间不足以重试，已停止后续模型调用')
    time.sleep(seconds)


@contextmanager
def _gate(lock):
    remaining = _remaining()
    acquired = lock.acquire() if remaining is None else lock.acquire(timeout=remaining)
    if not acquired:
        raise DeadlineExceeded('等待模型并发槽位超过总时限')
    try:
        _remaining()
        yield
    finally:
        lock.release()


def _chunks(response, limit=16 * 1024 * 1024):
    """One socket read at a time so trickled responses cannot reset the deadline."""
    total = 0
    while True:
        remaining = _remaining()
        sock = getattr(getattr(getattr(response, 'fp', None), 'raw', None), '_sock', None)
        if remaining is not None and sock is not None:
            sock.settimeout(remaining)
        block = getattr(response, 'read1', response.read)(min(65536, limit - total + 1))
        _remaining()
        if not block:
            break
        total += len(block)
        if total > limit:
            raise LLMError('模型响应超过大小上限')
        yield block


def _response_json(response):
    return json.loads(b''.join(_chunks(response)))


def _lines(response):
    pending = b''
    for block in _chunks(response):
        pending += block
        while b'\n' in pending:
            line, pending = pending.split(b'\n', 1)
            yield line
    if pending:
        yield pending


def key_for(model: str) -> str | None:
    """Which secret to send for a model.

    LLM_KEY_MAP="deepseek-=DEEPSEEK_KEY,gemini-=GOOGLE_KEY" routes models by name prefix;
    otherwise LLM_KEY_NAME, then LLM_API_KEY.
    """
    for rule in (_env('LLM_KEY_MAP') or '').split(','):
        prefix, _, name = rule.strip().partition('=')
        if prefix and name and model.startswith(prefix):
            return _env(name)
    return _env(os.environ.get('LLM_KEY_NAME') or '') or _env('LLM_API_KEY')


DEFAULT_BASE = {'openai': GATEWAY, 'anthropic': 'https://api.anthropic.com/v1',
                'gemini': 'https://generativelanguage.googleapis.com/v1beta',
                'ollama': 'http://localhost:11434/v1'}


def protocol_for(model: str) -> str:
    """Which request format to use. LLM_PROTOCOL_MAP="claude-=anthropic,gemini-=gemini" maps by name prefix."""
    for rule in (_env('LLM_PROTOCOL_MAP') or '').split(','):
        prefix, _, proto = rule.strip().partition('=')
        if prefix and proto and model.startswith(prefix):
            return proto
    return _env('LLM_PROTOCOL') or 'openai'


def base_for(protocol: str) -> str:
    return _env(f'LLM_BASE_URL_{protocol.upper()}') or (_env('LLM_BASE_URL') if protocol == 'openai' else None) \
        or DEFAULT_BASE.get(protocol, GATEWAY)


def _request(protocol: str, model: str, messages: list[dict], key: str, max_tokens: int, temperature: float,
             variant: str) -> urllib.request.Request:
    """One streaming request in the chosen protocol (the reply is parsed by _delta)."""
    base = base_for(protocol).rstrip('/')
    system = '\n\n'.join(m['content'] for m in messages if m['role'] == 'system')
    rest = [m for m in messages if m['role'] != 'system']
    headers = {'Content-Type': 'application/json', 'Accept': 'text/event-stream'}
    if protocol == 'anthropic':
        url = base + '/messages'
        body = {'model': model, 'max_tokens': max_tokens, 'temperature': temperature, 'stream': True,
                'messages': rest, **({'system': system} if system else {})}
        headers |= {'x-api-key': key, 'anthropic-version': '2023-06-01',
                    'anthropic-dangerous-direct-browser-access': 'true'}
    elif protocol == 'gemini':
        url = f'{base}/models/{model}:streamGenerateContent?alt=sse'
        body = {'contents': [{'role': 'model' if m['role'] == 'assistant' else 'user',
                              'parts': [{'text': m['content']}]} for m in rest],
                'generationConfig': {'maxOutputTokens': max_tokens, 'temperature': temperature}}
        if system:
            body['systemInstruction'] = {'parts': [{'text': system}]}
        headers['x-goog-api-key'] = key
    else:                      # openai-compatible (gateways, DeepSeek, Ollama, OpenRouter…)
        url = base + '/chat/completions'
        body = {'model': model, 'messages': messages, 'max_tokens': max_tokens, 'temperature': temperature,
                'stream': True, 'stream_options': {'include_usage': True}}
        if variant in ('think', 'nothink'):
            # DeepSeek V4 thinks by default; "deepseek-flash+nothink" turns it off
            body['thinking'] = {'type': 'enabled' if variant == 'think' else 'disabled'}
        headers['Authorization'] = 'Bearer ' + key
    return urllib.request.Request(url, data=json.dumps(body, ensure_ascii=False).encode(), method='POST', headers=headers)


def _delta(protocol: str, ev: dict, usage: dict) -> str:
    """Text of one streamed event; usage is filled in place."""
    if protocol == 'anthropic':
        if ev.get('type') == 'message_start':
            usage['prompt_tokens'] = ((ev.get('message') or {}).get('usage') or {}).get('input_tokens', 0)
        if ev.get('type') == 'message_delta':
            usage['completion_tokens'] = (ev.get('usage') or {}).get('output_tokens', usage.get('completion_tokens', 0))
        return (ev.get('delta') or {}).get('text') or '' if ev.get('type') == 'content_block_delta' else ''
    if protocol == 'gemini':
        um = ev.get('usageMetadata') or {}
        if um:
            usage['prompt_tokens'] = um.get('promptTokenCount', 0)
            usage['completion_tokens'] = um.get('candidatesTokenCount', 0)
        out = []
        for c in ev.get('candidates') or []:
            for part in ((c.get('content') or {}).get('parts') or []):
                if part.get('text'):
                    out.append(part['text'])
        return ''.join(out)
    if ev.get('usage'):
        usage.update({k: ev['usage'].get(k, 0) for k in ('prompt_tokens', 'completion_tokens')})
    return ''.join((ch.get('delta') or {}).get('content') or '' for ch in (ev.get('choices') or []))


def chat(model: str, messages: list[dict], *, max_tokens: int = 8000, temperature: float = 0.2,
         timeout: int | None = None, retries: int | None = None, key_name: str | None = None) -> tuple[str, dict]:
    """Streamed chat completion in any supported protocol. Returns (text, usage).

    LLM_TIMEOUT / LLM_RETRIES set how long to wait and how often to retry — a dead endpoint should
    not hold a run for an hour, and a slow local model may need longer than the default."""
    timeout = timeout if timeout is not None else int(os.environ.get('LLM_TIMEOUT', '600'))
    retries = retries if retries is not None else int(os.environ.get('LLM_RETRIES', '4'))
    model, _, variant = model.partition('+')
    key = _env(key_name) if key_name else key_for(model)
    if not key:
        raise LLMError('缺少模型访问密钥')
    protocol = protocol_for(model)
    last = None
    for attempt in range(retries + 1):
        try:
            req = _request(protocol, model, messages, key, max_tokens, temperature, variant)
            parts, usage = [], {}
            t0, first = time.time(), None
            with _opener().open(req, timeout=_timeout(timeout)) as resp:
                for raw in _lines(resp):
                    line = raw.decode('utf-8', errors='replace').strip()
                    if not line.startswith('data:'):
                        continue
                    data = line[5:].strip()
                    if data == '[DONE]':
                        break
                    try:
                        ev = json.loads(data)
                    except ValueError:
                        continue
                    text = _delta(protocol, ev, usage)
                    if text:
                        if first is None:
                            first = time.time()
                        parts.append(text)
            text = ''.join(parts)
            if not text.strip():
                raise LLMError('模型返回空内容')
            usage = dict(usage, _secs=round(time.time() - t0, 2), _ttft=round((first or time.time()) - t0, 2))
            return text, usage
        except urllib.error.HTTPError as e:
            detail = e.read(400).decode('utf-8', errors='replace')
            last = LLMError(f'HTTP {e.code}: {detail}')
            if e.code in (400, 401, 402, 403, 404, 422):
                raise last
        except DeadlineExceeded:
            raise
        except (urllib.error.URLError, TimeoutError, ConnectionError, LLMError, OSError) as e:
            last = e
        if attempt < retries:
            _sleep(min(60, 3 * 2 ** attempt) + random.random() * 2)
    raise LLMError(f'模型调用失败：{last}')


def repair_json(s: str) -> str:
    """Escape stray double quotes inside strings and drop trailing commas.

    Models sometimes write an ASCII quote inside a Chinese string (e.g. 他说"好"). A quote
    that is not followed by a structural character cannot be the end of the string.
    """
    out, in_str, esc = [], False, False
    n = len(s)
    for i, ch in enumerate(s):
        if in_str:
            if esc:
                esc = False
            elif ch == '\\':
                esc = True
            elif ch == '"':
                j = i + 1
                while j < n and s[j] in ' \t\r\n':
                    j += 1
                closes = j >= n or s[j] in '}]'
                if j < n and s[j] in ',:':
                    # a real closing quote is followed by , or : and then the start of a JSON value
                    k = j + 1
                    while k < n and s[k] in ' \t\r\n':
                        k += 1
                    closes = k >= n or s[k] in '"{[-0123456789tfn]}'
                if not closes:
                    out.append('\\"')
                    continue
                in_str = False
            elif ch == '\n':
                out.append('\\n')
                continue
        elif ch == '"':
            in_str = True
        out.append(ch)
    return re.sub(r',\s*([}\]])', r'\1', ''.join(out))


def parse_json(text: str):
    """Extract the first JSON object from a model reply (tolerates ```json fences)."""
    m = re.search(r'```(?:json)?\s*(.*?)```', text, re.S)
    if m:
        text = m.group(1)
    start = text.find('{')
    end = text.rfind('}')
    if start < 0 or end < 0:
        raise ValueError('回复里没有 JSON')
    body = text[start:end + 1]
    try:
        return json.loads(body)
    except ValueError:
        return json.loads(repair_json(body))


def chat_json(model: str, messages: list[dict], **kw):
    text, usage = chat(model, messages, **kw)
    try:
        return parse_json(text), usage
    except ValueError:
        # one repair attempt: ask the model to fix its own output
        fix, u2 = chat(model, messages + [{'role': 'assistant', 'content': text},
                                          {'role': 'user', 'content': '上面的输出不是合法 JSON。请只输出修正后的完整 JSON，不要任何解释。'}], **kw)
        return parse_json(fix), usage


# ---------------------------------------------------------------- the judge
JUDGE_SYSTEM = """You are a careful judge. You are given a state (the only evidence you may use) and multiple-choice questions. For every question pick exactly one option id and give a probability for each option; the probabilities of one question must sum to 1. Judge only from the state — never from outside knowledge of the work, and never from what you expect to happen later.

Reply with one compact JSON object and nothing else:
{"q1": {"choice": "<option id>", "probabilities": {"<option id>": 0.0, ...}}, ...}"""


def llm_judge(state, questions: dict, *, model: str | None = None) -> dict:
    """Same contract as jev(), answered by an ordinary chat model.

    Open-source installs may have no Jev key (and browsers cannot call the Jev API: it sends no
    CORS headers), so any OpenAI-compatible model can take the judge's seat. Less calibrated —
    see tests/judge_agreement.py for how close it gets.
    """
    model = model or os.environ.get('JUDGE_MODEL') or os.environ.get('RECAP_MODEL') or 'deepseek-flash+nothink'
    qs = {k: {'instructions': q.get('instructions', ''), 'options': q.get('criteria', {})}
          for k, q in questions.items()}
    user = json.dumps({'state': state, 'questions': qs}, ensure_ascii=False)
    msgs = [{'role': 'system', 'content': JUDGE_SYSTEM}, {'role': 'user', 'content': user}]
    text, usage = chat(model, msgs, max_tokens=200 + 120 * len(qs), temperature=0)
    try:
        data = parse_json(text)
    except ValueError:      # some models wrap the JSON in prose or truncate it
        fix, u2 = chat(model, msgs + [{'role': 'assistant', 'content': text},
                                      {'role': 'user', 'content': 'Reply again with only the JSON object.'}],
                       max_tokens=200 + 120 * len(qs), temperature=0)
        data = parse_json(fix)
        usage = {k: (usage.get(k) or 0) + (u2.get(k) or 0) for k in ('prompt_tokens', 'completion_tokens')}
    out = {}
    for k, q in questions.items():
        a = data.get(k) if isinstance(data, dict) else None
        probs = (a or {}).get('probabilities') or {}
        probs = {o: float(probs.get(o, 0) or 0) for o in q.get('criteria', {})}
        total = sum(probs.values()) or 1.0
        probs = {o: round(v / total, 3) for o, v in probs.items()}
        choice = (a or {}).get('choice')
        if choice not in probs:
            choice = max(probs, key=probs.get) if probs else None
        out[k] = {'type': 'choice', 'choice': choice, 'probabilities': probs, 'by': model}
    out['_usage'] = usage
    return out


CLASSIFIER_URL = os.environ.get('CLASSIFIER_URL', 'https://classifier.dev/v1/classify')
CLASSIFIER_DIMS = 20               # the free service takes 20 dimensions per request
CLASSIFIER_DIM_CHARS = 16_000      # observed HTTP 400 limit for serialized dimension definitions
CLASSIFIER_INSTRUCTION_CHARS = 4_000  # observed HTTP 400 limit for each instructions string


def _state_text(state) -> str:
    """The judge's state as one block of text (classifier.dev takes text, not a state object)."""
    if isinstance(state, str):
        return state
    parts = []
    for k, v in (state or {}).items():
        body = v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)
        parts.append(f'[{k}]\n{body}')
    return '\n\n'.join(parts)


def _retry_hint(headers) -> float | None:
    """Retry-After is either seconds or an HTTP date; malformed advice is not a delay."""
    value = (headers or {}).get('Retry-After')
    if value is None:
        return None
    try:
        seconds = float(value)
    except (TypeError, ValueError):
        try:
            seconds = parsedate_to_datetime(value).timestamp() - time.time()
        except (TypeError, ValueError, OverflowError):
            return None
    return max(0.0, seconds) if math.isfinite(seconds) else None


def _retry_after(headers, attempt: int, cap: float | None = None) -> float | None:
    """How long to wait after a 429, or None when waiting is not worth it.

    A server may answer "come back in 13 hours" (classifier.dev says exactly that once the day's
    free quota is gone). Sleeping that long silently parks every worker thread, so a hint longer
    than we are willing to wait means "this route is closed", not "wait" — the caller should take
    another route instead.
    """
    cap = cap if cap is not None else float(os.environ.get('JEV_MAX_WAIT', '60'))
    hinted = _retry_hint(headers)
    if hinted is not None and hinted > cap:
        return None
    if hinted is not None:
        return hinted + random.random()
    # No hint: we are guessing, and guessing big is expensive. The judge answers in about a
    # second, so backing off to a minute costs far more than retrying does — measured on 术师手册,
    # these self-imposed waits were 69% of the whole run's wall clock while the median call took
    # 1.1s. Server-sent advice may be long; our own guess should not be.
    blind = float(os.environ.get('JEV_BLIND_WAIT', '8'))
    return min(blind, 0.5 * 2 ** attempt) + random.random()


def _judge_retry(route: str, status: str, attempt: int, retries: int, wait: float,
                 started: float) -> None:
    """Log only operational metadata, never request bodies, headers or credentials."""
    with _stats_lock:
        JEV_STATS['retries'] = JEV_STATS.get('retries', 0) + 1
        JEV_STATS['retry_wait_seconds'] = JEV_STATS.get('retry_wait_seconds', 0) + wait
    print(f'[judge] 路由={route} 状态={status} 尝试={attempt + 1}/{retries + 1} '
          f'等待={wait:.1f}s 已用={time.monotonic() - started:.1f}s', flush=True)
    _sleep(wait)


def _judge_attempt() -> None:
    with _stats_lock:
        JEV_STATS['attempts'] = JEV_STATS.get('attempts', 0) + 1


def _validate_answers(answers, questions: dict, route: str) -> dict:
    """Missing answers must cause a retry, not become confident negative training examples.

    The local classifier uses independent scores, so requiring a sum of one would reject its
    valid wire format. Each returned score must still be finite, bounded, and an offered label.
    """
    if not isinstance(answers, dict):
        raise ValueError(f'{route}: answers must be an object')
    for key, question in questions.items():
        answer = answers.get(key)
        criteria = question.get('criteria') or {}
        if not isinstance(answer, dict) or not isinstance(answer.get('choice'), str) \
                or answer['choice'] not in criteria:
            raise ValueError(f'{route}: missing or invalid answer for {key}')
        scores = answer.get('probabilities')
        if not isinstance(scores, dict) or answer['choice'] not in scores:
            raise ValueError(f'{route}: missing probabilities for {key}')
        for label, value in scores.items():
            if label not in criteria or isinstance(value, bool) or not isinstance(value, (int, float)) \
                    or not math.isfinite(value) or not 0 <= value <= 1:
                raise ValueError(f'{route}: invalid probability for {key}')
        if not any(scores.values()):
            raise ValueError(f'{route}: empty probability distribution for {key}')
    return answers


class _Breaker:
    """Keeps a free best-effort route from holding up a book.

    A route that is merely cheaper is never worth waiting for: after `fails` failures in a row it is
    considered open and skipped outright for `cool` seconds, so callers go straight to the paid route
    instead of paying the timeout again on every call. One success closes it.
    """

    def __init__(self, name: str, fails: int = 3, cool: float = 600.0):
        self.name, self.fails, self.cool = name, fails, cool
        self.bad = 0
        self.until = 0.0
        self.probing = False
        self.lock = threading.Lock()

    def open(self) -> bool:
        with self.lock:
            return time.time() < self.until

    def allow(self) -> bool:
        """After cooldown, let one caller test recovery while the others use overflow."""
        with self.lock:
            if time.time() < self.until or self.probing:
                return False
            if self.until:
                self.probing = True
            return True

    def ok(self) -> None:
        with self.lock:
            if self.until:
                print(f'[judge] {self.name} is answering again', flush=True)
            self.bad, self.until, self.probing = 0, 0.0, False

    def failed(self, why: str = '', cool: float | None = None) -> None:
        """`cool` lets a route that knows when it reopens say so — a daily quota that resets at
        midnight is worth skipping until then, not for a blind ten minutes."""
        with self.lock:
            self.probing = False
            self.bad += 1
            wait = min(cool or self.cool, float(os.environ.get('JEV_MAX_COOLDOWN', '21600')))
            if self.bad >= self.fails and time.time() >= self.until:
                self.until = time.time() + wait
                print(f'[judge] {self.name} failed {self.bad}x, skipping it for '
                      f'{int(wait)}s: {why[:120]}', flush=True)


# classifier.dev normally answers in about a second, so a slow call is a broken one: give up on it
# quickly, and once it is clearly down stay away long enough that probing it costs nothing
_free_breaker = _Breaker('classifier.dev', fails=int(os.environ.get('JEV_FREE_FAILS', '2')),
                         cool=float(os.environ.get('JEV_FREE_COOLDOWN', '1800')))


def _classifier_batches(questions: dict) -> list[tuple[list, dict]]:
    """Honor both free-route limits before sending any request.

    Count the serialized object, including escaped quotes and label duplication, not merely
    descriptions. UTF-16 units conservatively cover JavaScript's string length for astral text;
    whitespace uses the same JSON serialization as the actual request body.
    """
    batches, keys, dims = [], [], {}
    for key, question in questions.items():
        criteria = question.get('criteria') or {}
        lines = '\n'.join(f'- {label}: {desc}' for label, desc in criteria.items())
        dimension = {'labels': list(criteria),
                     'instructions': f"{question.get('instructions', '')}\nChoose one label:\n{lines}"}
        if len(dimension['instructions'].encode('utf-16-le')) // 2 > CLASSIFIER_INSTRUCTION_CHARS:
            raise LLMError('classifier.dev：单个问题的说明超过 4000 字符，未调用免费接口')

        def candidate_size(candidate):
            serialized = json.dumps(candidate, ensure_ascii=False)
            return len(serialized.encode('utf-16-le')) // 2

        candidate = {**dims, f'd{len(keys)}': dimension}
        if dims and (len(candidate) > CLASSIFIER_DIMS or candidate_size(candidate) > CLASSIFIER_DIM_CHARS):
            batches.append((keys, dims))
            keys, dims = [], {}
            candidate = {'d0': dimension}
        if candidate_size(candidate) > CLASSIFIER_DIM_CHARS:
                raise LLMError('classifier.dev：单个问题的维度定义超过字符上限，需要显式选择支持该长度的路由')
        keys.append(key)
        dims = candidate
    if dims:
        batches.append((keys, dims))
    return batches


def jev_free(state, questions: dict, *, timeout: int = 90, retries: int = 6) -> dict:
    """The same Jev model through classifier.dev: no key, free, 3k classifications a minute.

    Our questions carry a description per option; classifier.dev takes labels plus one
    instructions string, so the descriptions are folded into the instructions.
    """
    if not questions:
        return {}
    if _free_breaker.open():
        raise LLMError('classifier.dev 暂时跳过（连续失败，冷却中）')
    timeout = min(timeout, int(os.environ.get('JEV_FREE_TIMEOUT', '20')))
    retries = min(retries, int(os.environ.get('JEV_FREE_RETRIES', '1')))
    started = time.monotonic()
    out: dict = {}
    text = _state_text(state)
    if len(text) > 31000:
        raise LLMError('上下文超过免费接口上限；未裁剪原文，需要显式选择支持该长度的路由')
    for chunk, dims in _classifier_batches(questions):
        body = json.dumps({'items': [text], 'dimensions': dims}, ensure_ascii=False).encode()
        # free or not, count it: the throughput ceiling (calls a minute) is what limits a big book,
        # and the split between passage and criteria is what a local judge would save
        with _stats_lock:
            JEV_STATS['calls'] += 1
            JEV_STATS['chars'] += len(body.decode('utf-8', 'replace'))
            JEV_STATS['questions'] += len(chunk)
            JEV_STATS['passage_chars'] = JEV_STATS.get('passage_chars', 0) + len(text)
        last = None
        for attempt in range(retries + 1):
            try:
                req = urllib.request.Request(CLASSIFIER_URL, data=body, method='POST',
                                             headers={'Content-Type': 'application/json'})
                key = _env('CLASSIFIER_KEY')
                if key:
                    req.add_header('Authorization', 'Bearer ' + key)
                _judge_attempt()
                with _opener().open(req, timeout=_timeout(timeout)) as resp:
                    data = _response_json(resp)
                results = data.get('results') if isinstance(data, dict) else None
                if not isinstance(results, list) or not results or not isinstance(results[0], dict):
                    raise ValueError('classifier.dev: missing results')
                got = results[0].get('dimensions')
                if not isinstance(got, dict):
                    raise ValueError('classifier.dev: missing dimensions')
                chunk_out = {}
                for i, k in enumerate(chunk):
                    a = got.get(f'd{i}') or {}
                    if not isinstance(a, dict):
                        raise ValueError('classifier.dev: invalid dimension')
                    scores = a.get('scores')
                    if scores is None:
                        scores = {a['label']: a.get('confidence', 1.0)} if a.get('label') else {}
                    chunk_out[k] = {'type': 'choice', 'choice': a.get('label'),
                                    'probabilities': scores, 'confidence': a.get('confidence')}
                _validate_answers(chunk_out, {k: questions[k] for k in chunk}, 'classifier.dev')
                for answer in chunk_out.values():
                    answer['probabilities'] = {lab: round(v, 3) for lab, v in answer['probabilities'].items()}
                out.update(chunk_out)
                break
            except urllib.error.HTTPError as e:
                detail = e.read(200).decode('utf-8', errors='replace')
                last = LLMError(f'classifier.dev HTTP {e.code}: {detail}')
                if e.code == 429:
                    wait = _retry_after(e.headers, attempt,
                                        cap=float(os.environ.get('JEV_FREE_MAX_WAIT', '2')))
                    if wait is None:        # the free quota is gone for today: hand over at once
                        last.reopens_in = _retry_hint(e.headers) or 0
                        raise last
                    if attempt >= retries:
                        raise LLMError(f'classifier.dev 调用失败：{last}')
                    _judge_retry('免费', f'HTTP {e.code}', attempt, retries, wait, started)
                    continue
                if e.code in (400, 401, 403):
                    raise last
                status = f'HTTP {e.code}'
            except DeadlineExceeded:
                raise
            except (urllib.error.URLError, TimeoutError, ConnectionError, OSError, ValueError) as e:
                last = e
                status = type(e).__name__
            if attempt < retries:
                _judge_retry('免费', status, attempt, retries,
                             min(20, 2 * 2 ** attempt) + random.random(), started)
        else:
            raise LLMError(f'classifier.dev 调用失败：{last}')
    return out


_jev_down = threading.Event()      # set once Jev refuses on credentials or credit
# the judge is called from every phase-1 worker at once; upstream rate limits are per organisation
_jev_gate = threading.Semaphore(int(os.environ.get('JEV_CONCURRENCY', '6')))
_teacher_log_lock = threading.Lock()


def _teacher_log(state, questions: dict, answers: dict) -> None:
    """Every judged question, exactly as asked and answered, for training a model of our own later.

    One line per question: the passage is written once per call and referred to by its hash, so a
    book's log stays small. JUDGE_LOG=0 turns it off; JUDGE_LOG_DIR says where it goes.
    """
    d = os.environ.get('JUDGE_LOG_DIR')
    if not d or os.environ.get('JUDGE_LOG', '1') != '1':
        return
    try:
        path = Path(d)
        path.mkdir(parents=True, exist_ok=True)
        text = state if isinstance(state, str) else json.dumps(state, ensure_ascii=False)
        h = hashlib.sha1(text.encode()).hexdigest()[:16]
        with _teacher_log_lock:
            states = path / 'states.jsonl'
            seen = _teacher_log.seen
            identity = (str(path.resolve()), h)
            if identity not in seen:
                with open(states, 'a', encoding='utf-8') as f:
                    f.write(json.dumps({'h': h, 'state': state}, ensure_ascii=False) + '\n')
                seen.add(identity)       # a failed write must remain retryable
            with open(path / 'questions.jsonl', 'a', encoding='utf-8') as f:
                for k, q in questions.items():
                    a = answers.get(k) or {}
                    f.write(json.dumps({'state': h, 'key': k, 'instructions': q.get('instructions', ''),
                                        'criteria': q.get('criteria', {}), 'choice': a.get('choice'),
                                        'probabilities': a.get('probabilities'), 'model': JEV_MODEL,
                                        'route': getattr(_route_context, 'route', 'unknown'),
                                        'capture_schema': 2},
                                       ensure_ascii=False) + '\n')
    except Exception as e:
        print(f'[judge] 训练日志写入失败：{type(e).__name__}，目录={d}', flush=True)


_teacher_log.seen = set()


_local_judge_gate = threading.Lock()


def jev_local(state, questions: dict) -> dict:
    """The explicit local-only route never incurs an upstream request or creates teacher labels."""
    url = os.environ.get('CLASSIFIER_URL', '')
    if not url or not url.rstrip('/').endswith('/v1/evaluate'):
        raise LLMError('本地裁判需要显式设置 CLASSIFIER_URL=http://主机:8008/v1/evaluate')
    body = json.dumps({'state': state, 'questions': questions}, ensure_ascii=False).encode('utf-8')
    req = urllib.request.Request(url, data=body, method='POST', headers={'Content-Type': 'application/json'})
    try:
        # Wait before opening the socket: workers share one GPU without racing its HTTP timeout.
        with _gate(_local_judge_gate):
            with _stats_lock:
                JEV_STATS['calls'] += 1
                JEV_STATS['chars'] += len(body.decode('utf-8'))
                JEV_STATS['questions'] += len(questions)
                JEV_STATS['local_calls'] = JEV_STATS.get('local_calls', 0) + 1
            _judge_attempt()
            with _opener().open(req, timeout=_timeout(float(os.environ.get('JEV_LOCAL_TIMEOUT', '120')))) as resp:
                data = _response_json(resp)
        answers = data.get('answers') if isinstance(data, dict) else None
        _validate_answers(answers, questions, 'Kev local')
        for qid, question in questions.items():
            scores = answers[qid]['probabilities']
            if set(scores) != set(question['criteria']) or abs(sum(scores.values()) - 1) > 0.01:
                raise ValueError('local judge must return a complete normalized distribution')
        return answers
    except DeadlineExceeded:
        raise
    except (urllib.error.URLError, TimeoutError, ConnectionError, OSError, ValueError) as e:
        raise LLMError(f'本地裁判失败，未调用付费接口：{type(e).__name__}: {e}') from e


def _jev_uncached(state, questions: dict, *, timeout: int = 90, retries: int | None = None) -> dict:
    """Call the selected judge route, with explicit bounded paid overflow only.

    Historical JUDGE_FALLBACK chat substitution is intentionally disabled: it
    bypassed the paid-request ledger and could be cached under the teacher name.
    """
    if not questions:
        return {}
    _remaining()
    started = time.monotonic()
    route = os.environ.get('JEV_ROUTE', 'free-only')
    route = 'free-only' if route == 'free' else route
    if route not in ('local', 'free-only', 'free-then-paid', 'paid'):
        raise LLMError('未知裁判路由；使用 local、free-only、free-then-paid 或 paid')
    if route == 'local':
        return jev_local(state, questions)
    if route in ('free-only', 'free-then-paid') and _free_breaker.allow():
        try:
            out = jev_free(state, questions, timeout=timeout)
            _free_breaker.ok()
            _route_context.route = 'free'
            _teacher_log(state, questions, out)
            return out
        except DeadlineExceeded:
            raise
        except Exception as e:
            _free_breaker.failed(str(e), cool=getattr(e, 'reopens_in', 0) or None)
            if route == 'free-only':
                raise LLMError(f'免费裁判暂不可用，未调用付费接口：{type(e).__name__}: {e}') from e
            print(f'[judge] classifier.dev unavailable, falling back to the paid route: {str(e)[:120]}', flush=True)
    elif route == 'free-only':
        raise LLMError('免费裁判处于冷却期，未调用付费接口；稍后可从缓存继续')
    key = (_env(os.environ.get('JEV_KEY_NAME') or '')
           or (_env('VERCEL_AI_GATEWAY_KEY') if 'vercel' in JEV_URL else None)
           or _env('JEV_API_KEY'))
    if not key:
        raise LLMError('缺少 Jev 密钥')
    body = json.dumps({'model': JEV_MODEL, 'state': state, 'questions': questions}, ensure_ascii=False).encode()
    with _stats_lock:
        JEV_STATS['calls'] += 1
        JEV_STATS['chars'] += len(body.decode('utf-8', 'replace'))
        JEV_STATS['paid_chars'] += len(body.decode('utf-8', 'replace'))
        JEV_STATS['questions'] += len(questions)
    last = None
    retries = retries if retries is not None else int(os.environ.get('JEV_RETRIES', '6'))
    if retries < 0:
        raise ValueError('JEV_RETRIES must be nonnegative')
    for attempt in range(retries + 1):
        _remaining()
        try:
            reserve_paid(len(body.decode('utf-8')), len(questions))
        except (RuntimeError, ValueError) as e:
            raise LLMError(str(e)) from e
        try:
            req = urllib.request.Request(JEV_URL, data=body, method='POST',
                                         headers={'Authorization': 'Bearer ' + key,
                                                  'Content-Type': 'application/json'})
            with _gate(_jev_gate):
                _judge_attempt()
                with _opener().open(req, timeout=_timeout(timeout)) as resp:
                    data = _response_json(resp)
            # typesafe.ai returns {"answers": …}; a gateway may wrap it differently
            if not isinstance(data, dict) or 'error' in data:
                raise ValueError('Jev: invalid response')
            out = data.get('answers') or data.get('results') or data
            _validate_answers(out, questions, 'Jev')
            if attempt:
                print(f'[judge] 路由=付费 已恢复 尝试={attempt + 1}/{retries + 1} '
                      f'已用={time.monotonic() - started:.1f}s', flush=True)
            _route_context.route = 'paid'
            _teacher_log(state, questions, out)
            return out
        except urllib.error.HTTPError as e:
            detail = e.read(300).decode('utf-8', errors='replace')
            last = LLMError(f'Jev HTTP {e.code}: {detail}')
            if e.code == 429:       # rate limited: wait as told, unless "as told" is hours away
                wait = _retry_after(e.headers, attempt)
                if wait is None:
                    raise last
                if attempt >= retries:
                    break
                _judge_retry('付费', f'HTTP {e.code}', attempt, retries, wait, started)
                continue
            if e.code in (400, 401, 402, 403, 404, 422):
                raise last
            status = f'HTTP {e.code}'
        except DeadlineExceeded:
            raise
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError, ValueError) as e:
            last = e
            status = type(e).__name__
        if attempt < retries:
            _judge_retry('付费', status, attempt, retries,
                         min(30, 2 * 2 ** attempt) + random.random(), started)
    raise LLMError(f'Jev 调用失败：{last}')


_cache_locks_guard = threading.Lock()
_cache_locks: dict[str, threading.Lock] = {}


def jev(state, questions: dict, *, timeout: int = 90, retries: int | None = None) -> dict:
    """Cache complete teacher requests, retaining successful batches on retry.

    Local model results never become teacher labels or cross-checkpoint caches.
    Caller-specific confidence policies remain outside this exact-input cache.
    """
    directory = os.environ.get('JUDGE_LOG_DIR')
    route = os.environ.get('JEV_ROUTE', 'free-only')
    if not directory or route == 'local' or os.environ.get('JUDGE_CACHE', '1') != '1' or not questions:
        return _jev_uncached(state, questions, timeout=timeout, retries=retries)
    fingerprint = digest({'state': state, 'questions': questions, 'model': JEV_MODEL,
                          'route': route, 'url': JEV_URL, 'version': 1})
    path = Path(directory) / 'cache' / f'{fingerprint}.json'
    with _cache_locks_guard:
        lock = _cache_locks.setdefault(str(path.resolve()), threading.Lock())
    with _gate(lock):
        if path.exists():
            saved = json.loads(path.read_text())
            if saved.get('request_sha256') != fingerprint:
                raise LLMError('裁判缓存校验失败')
            _validate_answers(saved.get('answers'), questions, 'judge cache')
            return saved['answers']
        answers = _jev_uncached(state, questions, timeout=timeout, retries=retries)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(f'.{os.getpid()}.{threading.get_ident()}.tmp')
        tmp.write_text(json.dumps({'request_sha256': fingerprint, 'answers': answers,
                                   'route': getattr(_route_context, 'route', route),
                                   'model': JEV_MODEL}, ensure_ascii=False))
        tmp.replace(path)
        return answers
