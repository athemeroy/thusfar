"""One place for what a model costs and how fast it is, for every part of the product.

Prices are CNY per million tokens. `mult` is the channel multiplier a gateway may apply to the
list price (some resellers bill a fraction of it). `rate` is measured from real books:
tokens per 10k characters of text and minutes per 10k characters at the default concurrency.
Add a model here and the estimate in the shelf, the cost report and the benchmark all follow.
"""
from __future__ import annotations

import json
import os

# price: (input, output) CNY per million tokens; mult: (low, high) channel multiplier
PRICES = {
    'gpt-5.6-terra': {'price': (2.0, 12.0), 'mult': (0.25, 0.4)},
    'deepseek-flash': {'price': (1.056, 4.224), 'mult': (1.0, 1.0), 'official': (1.0, 4.0)},
    'deepseek-v3.2': {'price': (0.96, 1.44), 'mult': (1.0, 1.0)},
    'deepseek-v4-pro': {'price': (4.752, 14.256), 'mult': (1.0, 1.0)},
    'claude-opus-5': {'price': (35.0, 175.0), 'mult': (1.0, 1.0)},
    # reseller list prices; `official` is what the model's own provider charges,
    # which is the number the docs quote.
    'gemini-2.5-flash-lite': {'price': (0.08, 0.32), 'mult': (0.5, 0.5), 'official': (0.72, 2.88)},
    'gemini-3.1-flash-lite-preview': {'price': (0.20, 0.60), 'mult': (0.5, 0.5), 'official': (0.72, 2.88)},
    'gpt-4.1-nano': {'price': (0.08, 0.32), 'mult': (1.0, 1.0)},
    'gpt-4o-mini': {'price': (0.12, 0.48), 'mult': (1.0, 1.0)},
    'qwen3-4b': {'price': (0.08, 0.48), 'mult': (1.0, 1.0)},
    'gpt-oss-20b': {'price': (0.10, 0.38), 'mult': (1.0, 1.0)},
}
JEV_PRICE = 0.042 * 7.2            # $0.042 per million input tokens, in CNY


def _overrides() -> dict:
    """What the person running this actually pays, from the environment.

    The table above is what our gateway charges, which is nobody else's price: channels differ,
    providers change their rates, and a self-hoster on a prepaid plan may pay nothing per call.
    Rather than have everyone patch this file, MODEL_PRICES states it:

        MODEL_PRICES='{"deepseek-flash": [1.0, 4.0], "my-local-model": [0, 0]}'

    Two numbers per model: input and output, in your own currency per million tokens — the shelf
    shows whatever unit you used. JEV_PRICE_OVERRIDE does the same for the judge (0 when you run
    your own, which is the point of running your own).
    """
    try:
        raw = json.loads(os.environ.get('MODEL_PRICES') or '{}')
    except Exception:
        return {}
    out = {}
    for name, v in raw.items():
        if isinstance(v, (list, tuple)) and len(v) == 2:
            out[name] = {'price': (float(v[0]), float(v[1])), 'mult': (1.0, 1.0)}
    return out


def price_of(model: str, official: bool = False) -> dict:
    """The price to use for a model: the reader's own if they gave one, else our measured table."""
    mine = _overrides().get(model)
    if mine:
        return mine
    p = PRICES.get(model, {'price': (2.0, 12.0), 'mult': (1.0, 1.0)})
    if official and p.get('official'):
        return {'price': p['official'], 'mult': (1.0, 1.0)}
    return p


def judge_price() -> float:
    try:
        return float(os.environ['JEV_PRICE_OVERRIDE'])
    except (KeyError, ValueError):
        return JEV_PRICE
DEFAULT = {'tokens': (38_000, 16_000), 'minutes': 0.46, 'judge_chars': 25_000}
# measured on finished books: per 10k characters of the book
RATES = {
    # 技能无冷却 136万字 / 儒林外史 32.5万字, Terra, concurrency 16
    'gpt-5.6-terra': {'tokens': (38_000, 16_000), 'minutes': 0.46},
    # 包法利 20万字 + 远大前程 99万字符, DeepSeek, concurrency 32
    'deepseek-flash': {'tokens': (17_500, 7_000), 'minutes': 0.17},
    # measured on single segments: same input, ~40% of Terra's output, seconds instead of minutes
    'gemini-2.5-flash-lite': {'tokens': (38_000, 6_500), 'minutes': 0.06},
    'gemini-3.1-flash-lite-preview': {'tokens': (38_000, 6_500), 'minutes': 0.06},
}
# Latin and Cyrillic text is about three characters per Chinese character for the same content
LATIN_FACTOR = 0.35
CJK = ('zh', 'ja', None, '')


def model_now() -> str:
    return (os.environ.get('LOCAL_MODEL') or os.environ.get('EXTRACT_MODEL') or 'deepseek-flash+nothink').split('+')[0]


def estimate(chars: int, model: str | None = None, lang: str = 'zh', judge: bool = True,
             official: bool = False) -> dict:
    """What reading this book with the AI will take: minutes and a CNY range.

    official=True prices it at the provider's own rate (what a reader of the open-source project
    would pay) instead of this gateway's channel price."""
    model = (model or model_now()).split('+')[0]
    rate = RATES.get(model, DEFAULT)
    if model not in PRICES and model not in _overrides():
        return {'model': model, 'minutes': None, 'low': None, 'high': None}
    price = price_of(model, official)
    units = max(0, chars) / 10_000 * (1 if lang in CJK else LATIN_FACTOR)
    tin, tout = (t * units / 1e6 for t in rate['tokens'])
    lo, hi = (tin * price['price'][0] + tout * price['price'][1]) * price['mult'][0], \
             (tin * price['price'][0] + tout * price['price'][1]) * price['mult'][1]
    if judge and os.environ.get('JEV_ROUTE', 'free-only') not in ('free-only', 'free'):
        jev_tokens = units * DEFAULT['judge_chars'] / 1.5 / 1e6
        lo += jev_tokens * judge_price()
        hi += jev_tokens * judge_price()
    return {'model': model, 'minutes': round(units * rate['minutes']), 'low': round(lo, 2), 'high': round(hi, 2)}


def cost_of(usage: dict) -> tuple[float, float]:
    """CNY range actually spent, from a book's recorded usage."""
    lo = hi = 0.0
    for model, u in (usage.get('by_model') or {}).items():
        p = price_of(model.split('+')[0])
        if not p:
            continue
        c = (u.get('prompt', 0) * p['price'][0] + u.get('completion', 0) * p['price'][1]) / 1e6
        lo += c * p['mult'][0]
        hi += c * p['mult'][1]
    jev = usage.get('jev') or {}
    # the free route (classifier.dev) serves the same model at no charge; books run before this
    # field existed only ever used the paid route, so `chars` is the right fallback for them
    billed = jev.get('paid_chars', jev.get('chars')) if 'paid_chars' in jev else jev.get('chars')
    if billed:
        c = billed / 1.5 / 1e6 * judge_price()
        lo += c
        hi += c
    return round(lo, 2), round(hi, 2)
