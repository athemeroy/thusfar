"""Page-bounded reader reactions and manually anchored AI notes."""
from __future__ import annotations

import hashlib
import json
import logging
import os
import random
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import nullcontext
from difflib import SequenceMatcher
from pathlib import Path

from pipeline.judge import guard_texts
from pipeline.llm import chat, jev
from pipeline.parse import u16
from server import storage
from server.ask import recent_text
from server.notebook import source_quote
from server.temporal import fold

MODEL = os.environ.get('MARGINALIA_MODEL', os.environ.get('QA_MODEL', 'deepseek-flash+nothink'))
AUTO_MODEL = os.environ.get('MARGINALIA_AUTO_MODEL', os.environ.get('MARGINALIA_MODEL', 'gemini-2.5-flash-lite'))
CUE_VERSION = 5
PROMPT_VERSION = 7
MAX_CACHE = 2000
PERSONAS = {
    'empathy': ('共情', '读出人物没有明说的情绪，但不替人物下诊断；温柔、克制。'),
    'detective': ('侦探', '指出已经出现的细节、照应或信息差；只说眼前证据，绝不预测。'),
    'cold': ('冷眼', '看清自欺、权力、体面和人情中的微妙张力；犀利但不刻薄。'),
    'scholar': ('学者', '说清这句话在措辞、视角、节奏或结构上的妙处；避免术语堆砌。'),
    'wit': ('吐槽', '轻巧、机敏地说出这句话的反差；不玩过时网络梗，不嘲弄苦难。'),
}
CATEGORY_PERSONA = {
    'feeling': 'empathy', 'clue': 'detective', 'theme': 'cold',
    'craft': 'scholar', 'wit': 'wit',
}
COMMENT_STYLES = (
    '像读书群里刚看到这一句，先说最直接的一个反应，别复述情节。',
    '从原句里挑一个小动作，接一句自然的疑问或感叹。',
    '留意这句话没说破的地方，但只谈材料支持的那一层。',
    '抓住眼前的轻微反差，语气机灵一点，别为了好笑编故事。',
    '像接朋友上一句话那样短短回一句，不写完整的文学分析。',
    '可以承认自己拿不准，用“是不是”“总觉得”这类真实的迟疑。',
    '说出你对这个细节的偏爱、担心或不满，别替人物断定内心。',
    '让口气更轻、更口语；可以有一句贴切的短梗，但别用老套热词。',
    '如果真的贴切，可以只用一个 emoji 或颜文字收尾；不贴切就完全不用。',
)
_locks_guard = threading.Lock()
_locks: dict[str, threading.Lock] = {}
_key_stripes: dict[str, tuple[threading.Lock, ...]] = {}
# Keep speculative work bounded and reserve one model slot for a visible/manual page.
_model_gate = threading.BoundedSemaphore(3)
_prefetch_gate = threading.BoundedSemaphore(2)
_comment_gate = threading.BoundedSemaphore(4)


def _lock_for(root: Path):
    key = str(root.resolve())
    with _locks_guard:
        return _locks.setdefault(key, threading.Lock())


def _key_lock(root: Path, key: str):
    name = str(root.resolve())
    with _locks_guard:
        stripes = _key_stripes.get(name)
        if stripes is None:
            stripes = tuple(threading.Lock() for _ in range(64))
            _key_stripes[name] = stripes
    return stripes[int(key[:8], 16) % len(stripes)]


def _slice_u16(text: str, start: int, end: int) -> str:
    raw = text.encode('utf-16-le')
    return raw[start * 2:end * 2].decode('utf-16-le', errors='ignore')


def _page_candidates(book: dict, start: int, end: int) -> list[dict]:
    """Sentence-sized candidates wholly reconstructed from visible source text."""
    out = []
    for block in book['blocks']:
        if block.get('k') not in ('p', 'h'):
            continue
        b0, b1 = block['o'], block['o'] + u16(block['t'])
        if b1 <= start or b0 >= end:
            continue
        lo, hi = max(start, b0) - b0, min(end, b1) - b0
        visible = _slice_u16(block['t'], lo, hi)
        visible_o = b0 + lo
        # Chinese and Western prose both occur in the library. Keep terminal
        # punctuation with its sentence so the eventual underline looks natural.
        for match in re.finditer(r'[^。！？!?；;.\n]+(?:[。！？!?；;.]+|$)', visible):
            raw = match.group(0)
            left = len(raw) - len(raw.lstrip())
            right = len(raw.rstrip())
            quote = raw[left:right]
            if not 6 <= len(quote) <= 180 or not re.search(r'[\w\u3400-\u9fff]', quote):
                continue
            prefix = visible[:match.start() + left]
            s = visible_o + u16(prefix)
            e = s + u16(quote)
            if start <= s < e <= end:
                out.append({'start': s, 'end': e, 'quote': quote})
    # JEV sees a compact editorial slate, not every fragment on a dense page.
    if len(out) > 10:
        step = (len(out) - 1) / 9
        out = [out[round(i * step)] for i in range(10)]
    return out


def _source_before(book: dict, pos: int, chars: int = 2400) -> str:
    """A hard-bounded, source-only window ending at the reader's current cutoff."""
    return '\n'.join(row['t'] for row in recent_text(book, pos, chars=chars)).strip()[-chars:]


def _story(world: dict, focus: str = '', limit_people: int = 12) -> str:
    """Prefer entities in the visible reading context, then fill from story prominence."""
    parts = []
    if world.get('saga'):
        parts.append('故事线：' + str(world['saga'])[:700])
    people_by_id = world.get('people', {})
    focused = {
        pid for pid, person in people_by_id.items()
        if any(len(name) >= 2 and name in focus
               for name in [person.get('name', '')] + person.get('aliases', []))
    }
    recent_events = world.get('events', [])[-14:]
    related_events = [row for row in world.get('events', [])[:-14]
                      if focused.intersection(row.get('who', []))][-6:]
    events = [str(x.get('text', ''))[:180] for x in related_events + recent_events if x.get('text')]
    if events:
        parts.append('此前事件：' + '；'.join(events))
    recent_ids = {pid for row in recent_events for pid in row.get('who', [])}
    people = sorted(people_by_id.values(),
                    key=lambda p: (p['id'] in focused, p['id'] in recent_ids,
                                   p.get('n', 0), p.get('imp', 0)), reverse=True)
    cards = []
    for person in people[:limit_people]:
        bits = [str(person.get('name', ''))[:40], str(person.get('tagline', ''))[:100],
                str(person.get('bio', ''))[:180]]
        aliases = [x for x in person.get('aliases', []) if x in focus][:3]
        if aliases:
            bits.append('本页别名：' + '、'.join(aliases))
        attrs = '、'.join(f'{k}：{v}' for k, v in list(person.get('attrs', {}).items())[:8])[:240]
        if attrs:
            bits.append(attrs)
        cards.append('｜'.join(x for x in bits if x))
    if cards:
        parts.append('人物状态：' + '\n'.join(cards))
    rels = []
    names = {k: v.get('name', k) for k, v in people_by_id.items()}
    relations = list(world.get('rels', {}).values())
    chosen = [row for row in relations if row.get('a') in focused or row.get('b') in focused][-12:]
    chosen += [row for row in relations[-16:] if row not in chosen]
    for row in chosen[:18]:
        desc = row.get('desc') or row.get('a_is') or row.get('b_is') or '有关联'
        rels.append(f"{names.get(row.get('a'), row.get('a'))}—{names.get(row.get('b'), row.get('b'))}：{str(desc)[:120]}")
    if rels:
        parts.append('人物关系：' + '；'.join(rels))
    return '\n'.join(parts) or '此前没有可用的故事线摘要。'


def _select(book: dict, log: list, frontier: int, page_start: int, page_end: int) -> list[dict]:
    """Jev chooses source-anchored cues; this never calls the writing model."""
    candidates = _page_candidates(book, page_start, page_end)
    if not candidates:
        return []
    world = fold(log, min(page_start, frontier) if frontier else page_start)
    prior = _source_before(book, page_start)
    visible = {f's{i}': row['quote'] for i, row in enumerate(candidates, 1)}
    state = {
        'story_before_this_page': _story(world, prior + '\n' + '\n'.join(visible.values())),
        'source_before_this_page': prior,
        'visible_page_sentences': visible,
    }
    criteria = {
        'ordinary': 'A routine transition or isolated line that gains little from a reader reaction.',
        'feeling': 'A specific emotional undercurrent made richer by the story so far.',
        'clue': 'A concrete detail, information gap, or callback already supported by the read text.',
        'theme': 'A revealing moment of motive, self-deception, power, or manners.',
        'craft': 'Distinctive wording, viewpoint, rhythm, image, or structural turn.',
        'wit': 'A real irony, reversal, or comic contrast that supports a brief witty reaction.',
    }
    questions = {f's{i}': {
        'type': 'choice',
        'instructions': ('Which kind of short reader reaction, if any, would fit this exact sentence? '
                         'Use only story_before_this_page, source_before_this_page and visible_page_sentences; '
                         'never infer later plot. '
                         'Choose ordinary if there is no concrete reason to comment. Sentence: ' + row['quote']),
        'criteria': criteria,
    } for i, row in enumerate(candidates, 1)}
    answers = jev(state, questions)
    threshold = float(os.environ.get('MARGINALIA_MIN_SCORE', '0.45'))
    eligible = []
    for i, row in enumerate(candidates, 1):
        answer = answers.get(f's{i}') or {}
        probs = answer.get('probabilities') or {}
        choice = answer.get('choice')
        score = 1 - float(probs.get('ordinary', 1))
        confidence = float(probs.get(choice, 0)) if choice else 0
        if choice not in CATEGORY_PERSONA or score < threshold or confidence < .38:
            continue
        eligible.append((score * (.7 + .3 * confidence),
                         {**row, 'persona': CATEGORY_PERSONA[choice], 'kind': choice,
                          'score': round(score, 3)}))
    span = page_end - page_start
    limit = min(4, max(1, (span + 199) // 280))
    gap = max(80, span // (limit + 1))
    selected = []
    for _, row in sorted(eligible, key=lambda item: item[0], reverse=True):
        if all(abs(row['start'] - prior['start']) >= gap for prior in selected):
            selected.append(row)
            if len(selected) == limit:
                break
    return sorted(selected, key=lambda row: row['start'])


def _material(book: dict, log: list, frontier: int, end: int, quote: str) -> str:
    world = fold(log, min(end, frontier) if frontier else end)
    recent = _source_before(book, end, chars=2600)
    parts = ['【截至这句话的故事状态】\n' + _story(world, recent + '\n' + quote)]
    if recent:
        parts.append('【此前原文】\n' + recent)
    parts.append('【被划线的原句】\n' + quote)
    return '\n\n'.join(parts)


def _clean(text: str) -> str:
    text = re.sub(r'^\s*(?:批注|评论|弹幕|短评)\s*[：:]\s*', '', text.strip())
    text = re.sub(r'```.*?```', '', text, flags=re.S).strip()
    text = ' '.join(x.strip() for x in text.splitlines() if x.strip())
    text = text.strip('“”"')[:160]
    # Short/truncated completions and copied prompt fragments are not reader comments.
    if (len(re.findall(r'[\u3400-\u9fff]', text)) < 6 or text.endswith(('，', ',', '：', ':'))
            or re.search(r'Markdown|JSON|系统提示', text, flags=re.I)):
        return ''
    return text


def _write_comment(material: str, persona: str, previous: str | None = None, *,
                   model: str | None = None, style: str | None = None) -> str:
    model = model or MODEL
    label, voice = PERSONAS[persona]
    system = (
        '你是刚读到被划线句的读者，在这句话的评论区顺手留一句。不是旁白、剧情复述或文学赏析。'
        '只根据已给的前情和原句；绝不透露、预测、暗示后文，也不能补出材料没写的地点、物品位置、次数、'
        '人物特征、动机或事件。不要把猜测写成已经确定的事实。'
        '只盯住原句里的一个具体动作、措辞或人物关系，说一句自己真正在意的话。'
        '可以有口语、疑问、偏爱或轻微吐槽，不必每次都解释理由；语气像跟同在读的朋友说话。'
        '不要故作诗意，不要强行写“像……”，不要“这说明”“体现了”“细思极恐”“狠狠共情”等套话。'
        '一句中文，通常 8～45 个汉字。不强求句号；问号、感叹号或不加句末标点都自然。'
        '默认不用表情；确实贴切时可以有一个 emoji 或颜文字，也可以不用。'
        '只输出评论正文，不要标题、引号、Markdown或JSON。'
        f'这条从「{label}」角度写：{voice} '
        '这一次的口吻提示：' + (style or random.choice(COMMENT_STYLES))
    )
    user = material
    if previous:
        user += '\n\n上一版未通过材料核对：' + previous + '\n请删掉材料没有支持的判断，重新写一句。'
    with _comment_gate:
        text, _ = chat(model, [{'role': 'system', 'content': system}, {'role': 'user', 'content': user}],
                       max_tokens=160, temperature=.75 if persona == 'wit' else .65, timeout=45, retries=0)
    result = _clean(text)
    if not result:
        raise ValueError('AI 这次没有写出可用的批注，请稍后再试')
    return result


def _accepted(verdict: dict) -> bool:
    probability = verdict.get('p')
    return verdict.get('verdict') == 'ok' and isinstance(probability, (int, float)) and probability >= .4


def _generate(book: dict, log: list, frontier: int, selected: dict, *, model: str | None = None) -> tuple[str, dict]:
    model = model or MODEL
    material = _material(book, log, frontier, selected['end'], selected['quote'])
    comment = _write_comment(material, selected['persona'], model=model)
    verdict = guard_texts(material, {}, {'comment': comment}).get('comment', {})
    if not _accepted(verdict):
        first = comment
        comment = _write_comment(material, selected['persona'], first, model=model)
        second = guard_texts(material, {}, {'comment': comment}).get('comment', {})
        if not _accepted(second):
            raise ValueError('这条批注没有通过已读内容核对，已替你隐藏')
        verdict = {'verdict': 'rewritten', 'p': second.get('p'), 'first': verdict.get('p')}
    return comment, {'verdict': verdict.get('verdict'), 'p': verdict.get('p')}


def _comment_personas(first: str) -> tuple[str, ...]:
    return tuple(dict.fromkeys((first, 'detective', 'empathy', 'wit')))[:3]


def _generate_many(book: dict, log: list, frontier: int, selected: dict, *, model: str | None = None) -> list[dict]:
    """Generate independent angles concurrently; verify the surviving texts in one Jev call."""
    model = model or AUTO_MODEL
    material = _material(book, log, frontier, selected['end'], selected['quote'])
    personas = _comment_personas(selected['persona'])
    styles = random.sample(COMMENT_STYLES, k=len(personas))
    with ThreadPoolExecutor(max_workers=len(personas)) as pool:
        futures = {persona: pool.submit(_write_comment, material, persona, model=model, style=style)
                   for persona, style in zip(personas, styles)}
        drafts, failures = {}, []
        for persona, future in futures.items():
            try:
                drafts[persona] = future.result()
            except Exception as exc:
                failures.append(exc)
    if failures:
        logging.warning('marginalia: %d of %d comment drafts failed', len(failures), len(personas))
    if not drafts:
        raise failures[0]
    # A different angle is useful only if it contributes a different actual remark.
    unique = {}
    for persona, comment in drafts.items():
        normalized = re.sub(r'[^\w\u3400-\u9fff]', '', comment).lower()
        if any(SequenceMatcher(None, normalized, prior).ratio() >= .82 for prior in unique.values()):
            continue
        unique[persona] = normalized
    verdicts = guard_texts(material, {}, {persona: drafts[persona] for persona in unique})
    items = []
    for persona in unique:
        verdict = verdicts.get(persona, {})
        if _accepted(verdict):
            items.append({**selected, 'persona': persona, 'comment': drafts[persona],
                          'guard': {'verdict': 'ok', 'p': verdict.get('p')}})
    if not items:
        raise ValueError('这次生成的评论没有通过已读内容核对，点虚线可重试')
    return items


def _key(payload: dict) -> str:
    version = CUE_VERSION if payload.get('mode') == 'cues' else PROMPT_VERSION
    raw = json.dumps({'v': version, **payload}, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
    return hashlib.sha256(raw.encode()).hexdigest()[:32]


def respond(root: Path, data: dict, cached_json, write_json) -> dict:
    if not isinstance(data, dict):
        raise ValueError('评论请求格式无效')
    book = cached_json(root / 'book.json')
    graph = cached_json(root / 'kg.json') or {'log': []}
    status = cached_json(root / 'status.json') or {}
    mode = data.get('mode', 'manual')
    if mode not in ('manual', 'auto', 'cues'):
        raise ValueError('评论模式无效')
    purpose = data.get('purpose', 'visible')
    if purpose not in ('visible', 'prefetch') or (mode == 'manual' and purpose != 'visible'):
        raise ValueError('评论请求用途无效')
    pos = storage.integer(data.get('pos'), '已读位置', 0, book['len'])
    persona = data.get('persona', 'auto')
    if persona != 'auto' and persona not in PERSONAS:
        raise ValueError('不认识这种批注口吻')
    frontier = status.get('frontier', 0)
    payload = {'mode': mode, 'pos': pos, 'persona': persona,
               'knowledge_frontier': min(pos, frontier) if isinstance(frontier, int) else 0,
               'graph_revision': storage.signature(root / 'kg.json') if (root / 'kg.json').is_file() else None}
    if mode == 'manual':
        start = storage.integer(data.get('start'), '划线位置', 0, pos)
        end = storage.integer(data.get('end'), '划线终点', start + 1, pos)
        quote = source_quote(book, start, end)
        if not quote.strip() or len(quote) > 600:
            raise ValueError('请选择 1～600 字的原文生成批注')
        payload.update(start=start, end=end, quote=quote)
    else:
        page_start = storage.integer(data.get('page_start'), '本页起点', 0, pos)
        page_end = storage.integer(data.get('page_end', pos), '本页终点', page_start, pos)
        if page_end - page_start > 12000:
            raise ValueError('本页范围过大，请重新翻页后再试')
        payload.update(page_start=page_start, page_end=page_end)
    key = _key(payload)
    cache_path = root / 'marginalia.json'
    with _lock_for(root):
        rows = cached_json(cache_path) or []
        if not isinstance(rows, list):
            rows = []
        old = next((row for row in rows if row.get('key') == key), None)
        if old:
            return {**old, 'cached': True}
    # Duplicate requests for the same page coalesce. Distinct pages can generate
    # concurrently; the short cache lock below still serializes writes.
    with _key_lock(root, key):
        with _lock_for(root):
            rows = cached_json(cache_path) or []
            if not isinstance(rows, list):
                rows = []
            old = next((row for row in rows if row.get('key') == key), None)
            if old:
                return {**old, 'cached': True}
        with (_prefetch_gate if purpose == 'prefetch' else nullcontext()):
            with _model_gate:
                if mode == 'cues':
                    selections = _select(book, graph['log'], frontier, page_start, page_end)
                    record = {'key': key, 'items': selections, 'reason': 'cues', 'created': time.time()}
                elif mode == 'auto':
                    quote = source_quote(book, page_start, page_end)
                    if not quote.strip() or len(quote) > 600:
                        raise ValueError('点选的原文范围无效，请重新点虚线')
                    selected = {'start': page_start, 'end': page_end, 'quote': quote,
                                'persona': 'empathy' if persona == 'auto' else persona,
                                'kind': 'reader', 'score': 1.0}
                    items = [{**item, 'position': pos, 'knowledge_cutoff': page_end}
                             for item in _generate_many(book, graph['log'], frontier, selected, model=AUTO_MODEL)]
                    record = {'key': key, **items[0], 'items': items, 'created': time.time()}
                else:
                    selected = {'start': start, 'end': end, 'quote': quote,
                                'persona': 'empathy' if persona == 'auto' else persona,
                                'kind': 'manual', 'score': 1.0}
                    comment, guard = _generate(book, graph['log'], frontier, selected)
                    record = {'key': key, 'comment': comment, 'start': selected['start'], 'end': selected['end'],
                              'quote': selected['quote'], 'persona': selected['persona'], 'kind': selected.get('kind'),
                              'score': selected.get('score'), 'guard': guard, 'position': pos,
                              'knowledge_cutoff': selected['end'], 'created': time.time()}
        with _lock_for(root):
            rows = cached_json(cache_path) or []
            if not isinstance(rows, list):
                rows = []
            old = next((row for row in rows if row.get('key') == key), None)
            if old:
                return {**old, 'cached': True}
            write_json(cache_path, (rows + [record])[-MAX_CACHE:])
        return {**record, 'cached': False}
