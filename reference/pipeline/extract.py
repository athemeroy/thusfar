"""Sequential, prefix-only knowledge-graph extraction.

Segment k is processed with (a) the cast registry built from segments < k and (b) the
text of segment k only. Nothing downstream of k is ever visible to the model, so every
record it writes is causally safe at the position where it is anchored.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

from .llm import chat, parse_json
from .parse import u16

SEG_CHARS = 3200

SYSTEM = """你是一位细致的文学编辑，正在为一款“防剧透阅读器”逐段整理小说的人物知识图谱。读者只读到【本段原文】的末尾，你的输出会在读者读到对应位置时展示给他。

铁律（最重要）：
1. 只能使用【前情提要】【已知人物档案】【本段原文】里的信息。即使你认出了这部作品、知道后来的情节，也绝不能写入任何在本段之后才会揭示的内容（后来的身份、结局、死亡、未来的婚恋和关系变化等）。哪怕是暗示也不行。
2. 始终站在“读到这里为止”的读者视角。人物还没被说出名字时，就用读者此刻能用的称呼（如“新生”“黑衣人”）建档；原文后来揭示他就是某人时，才用 merges 合并。
3. 所有 quote 必须是【本段原文】中逐字出现的连续片段（6～30个字），用来定位原文。para 是该信息出现的段落编号（[P3] 就填 3）。
4. 只写原文能支持的事实，不做推测性评价；语气客观、简洁、中文。

人物的范围：有名字或反复出现、对情节有作用的角色（包括只用称谓出现的，如“校长”“老板娘”）。不要收录只被顺带提到的历史名人、作家、神话人物，也不要收录群体（如“学生们”）。

输出一个 JSON 对象（不要任何解释），字段如下，没有内容的字段给空数组：
{
  "new_people": [{"ref": "N1", "name": "最能识别此人的名字（本段内已揭示的全名或常用名）", "gender": "男|女|未知", "importance": 1-3, "para": 1, "quote": "首次出场的原文", "intro": "出场时读者对他的第一印象（≤24字）"}],
  "surfaces": {"P3": ["查理", "包法利", "*新生"], "N1": ["..."]},
  "aliases": [{"who": "P3", "alias": "新揭示的名字/绰号/称谓", "primary": false, "para": 1, "quote": "..."}],
  "merges": [{"from": "P5", "into": "P2", "para": 1, "quote": "...", "reason": "原文揭示二者是同一人"}],
  "events": [{"who": ["P2", "N1"], "text": "一句话事件（≤40字）", "para": 1, "quote": "...", "importance": 1-3}],
  "attrs": [{"who": "P2", "key": "身份|职业|住处|年龄|外貌|性格|处境|生死", "value": "≤25字", "para": 1, "quote": "..."}],
  "rels": [{"a": "P2", "b": "P7", "b_is": "b 对 a 而言是什么（如 母亲）", "a_is": "a 对 b 而言是什么（如 儿子）", "desc": "一句话说明（≤40字）", "status": "new|changed|ended", "para": 1, "quote": "..."}],
  "profiles": [{"who": "P2", "tagline": "一句话身份（≤18字）", "bio": "截至本段该人物的完整简介（60～160字）", "para": 1}]
}

要求：
- surfaces：对象，键是人物 id，值是本段里称呼此人时实际用过的名字或称谓写法（全名、名、姓、绰号、头衔，如“查理”“包法利先生”“新生”）。每个写法必须在原文中逐字出现。不要代词（他、她），不要一次性的描述性说法（“可怜的孩子”“那个人”“年轻人”）。如果写法是普通称谓、在别处可能指别人（如“夫人”“医生”“校长”“先生”“老太太”），在前面加 * 号。同一写法在本段指向不同的人时，在各人名下都列出。
- aliases：已知人物新获得的名字、绰号、头衔。primary=true 表示从此应把它当作此人的主称呼（例如真名揭晓、身份改变后大家都这样称呼）。
- importance：3=主要人物，2=重要配角，1=次要人物。
- events：只记对情节或人物有意义的事件，按发生顺序，本段通常 3～10 条。
- rels：只记原文明确交代的关系或关系变化（亲属、婚恋、雇佣、师生、朋友、敌对、债务等）。已知关系没有变化就不要重复。
- profiles：本段新出现的人物必须写；已有人物只有在认识明显加深或处境改变时才更新。bio 是人物小传而不是场景描写：身份与背景、性格、主要关系、至今的关键经历、目前处境，要融合旧简介与新信息，不要只写本段的一个场景；不许出现任何后文信息。para 填写这份简介所依据的最后一个段落编号。
- 引用已知人物时一律用档案里的 id（如 P3），本段新人物用 N1、N2…
- 输出紧凑的单行 JSON，不要缩进和换行。"""


def segments(book: dict, body: list[int], max_chars: int | None = None) -> list[dict]:
    """Split body chapters into paragraph-aligned segments of ~max_chars."""
    from .lang import seg_chars
    max_chars = max_chars or seg_chars(book)
    segs: list[dict] = []
    blocks = book['blocks']
    for ci in body:
        ch = book['chapters'][ci]
        cur: list[int] = []
        size = 0
        for bi in range(ch['b0'], ch['b1']):
            b = blocks[bi]
            if b['k'] == 'img' or not b['t']:
                continue
            n = u16(b['t'])
            if cur and size + n > max_chars:
                segs.append({'chapter': ci, 'blocks': cur})
                cur, size = [], 0
            cur.append(bi)
            size += n
        if cur:
            segs.append({'chapter': ci, 'blocks': cur})
    # fold tiny segments (e.g. a lone part title) into the following one
    merged: list[dict] = []
    carry: list[int] = []
    for s in segs:
        text_len = sum(u16(blocks[i]['t']) for i in s['blocks'])
        if text_len < 120 and s is not segs[-1]:
            carry += s['blocks']
            continue
        s['blocks'] = carry + s['blocks']
        carry = []
        merged.append(s)
    # a trailing short piece joins the previous segment of the same chapter
    for i, s in enumerate(merged):
        s['i'] = i
        s['o0'] = blocks[s['blocks'][0]]['o']
        last = blocks[s['blocks'][-1]]
        s['o1'] = last['o'] + u16(last['t'])
        s['chars'] = sum(u16(blocks[j]['t']) for j in s['blocks'])
    return merged


def seg_text(book: dict, seg: dict) -> str:
    lines = []
    for n, bi in enumerate(seg['blocks'], 1):
        b = book['blocks'][bi]
        prefix = '【标题】' if b['k'] == 'h' else ''
        lines.append(f'[P{n}] {prefix}{b["t"]}')
    return '\n'.join(lines)


def registry_prompt(state: dict, text: str) -> str:
    people = [p for p in state['people'].values() if not p.get('merged_into')]
    if not people:
        return '（暂无，本段是第一段或此前没有出现人物）'
    seg_no = state['seg']
    rows_full, rows_short = [], []
    for p in sorted(people, key=lambda p: (-p.get('importance', 1), -p.get('mentions', 0))):
        names = [p['name']] + p.get('aliases', [])
        present = any(n and n in text for n in names)
        recent = seg_no - p.get('last_seg', -99) <= 4
        if present or recent or p.get('importance', 1) >= 3:
            rows_full.append(
                f"{p['id']}｜{p['name']}｜别称：{'、'.join(p.get('aliases', [])) or '无'}｜{p.get('tagline', '')}\n    简介：{p.get('bio', '')}")
        else:
            rows_short.append(f"{p['id']}｜{p['name']}｜{'、'.join(p.get('aliases', [])[:4])}｜{p.get('tagline', '')}")
    out = '\n'.join(rows_full)
    if rows_short:
        out += '\n\n（以下人物本段可能未出场，仅列出以便沿用 id）\n' + '\n'.join(rows_short[:400])
    return out


def relations_prompt(state: dict, text: str) -> str:
    rows = []
    people = state['people']
    for r in state['rels'].values():
        if r.get('status') == 'ended':
            continue
        a, b = people.get(r['a']), people.get(r['b'])
        if not a or not b:
            continue
        if any(n in text for n in [a['name'], b['name']] + a.get('aliases', []) + b.get('aliases', [])):
            rows.append(f"{r['a']}（{a['name']}）的{r['b_is']}是 {r['b']}（{b['name']}）：{r.get('desc', '')}")
    return '\n'.join(rows[:120]) or '（无）'


def build_messages(book: dict, state: dict, seg: dict) -> list[dict]:
    text = seg_text(book, seg)
    ch = book['chapters'][seg['chapter']]
    chap = (ch.get('parent') + ' · ' if ch.get('parent') else '') + ch['title']
    recent = '\n'.join(f"- {e}" for e in state.get('recent_events', [])[-10:]) or '（无）'
    user = f"""【作品】《{book['title']}》{book.get('author') or ''}
【当前章节】{chap}

【前情提要】
{state.get('saga') or '（故事刚开始）'}

【最近发生的事】
{recent}

【已知人物档案】（截至本段之前）
{registry_prompt(state, text)}

【已知关系】
{relations_prompt(state, text)}

【本段原文】
{text}

请输出 JSON。"""
    return [{'role': 'system', 'content': SYSTEM}, {'role': 'user', 'content': user}]


KEYS = ('new_people', 'aliases', 'merges', 'events', 'attrs', 'rels', 'profiles')


def extract_segment(book: dict, state: dict, seg: dict, model: str) -> tuple[dict, dict]:
    """One model call for one segment. Raises if the reply is unusable so the caller retries."""
    msgs = build_messages(book, state, seg)
    text, usage = chat(model, msgs, max_tokens=12000, temperature=0.2)
    try:
        data = parse_json(text)
    except ValueError:
        fix, _ = chat(model, msgs + [{'role': 'assistant', 'content': text},
                                     {'role': 'user', 'content': '上面的输出不是合法 JSON（可能有未转义的英文引号或被截断）。请只输出修正后的完整 JSON。'}],
                      max_tokens=12000, temperature=0)
        data = parse_json(fix)
        text = fix
    if not isinstance(data, dict) or not any(isinstance(data.get(k), list) and data.get(k) for k in KEYS + ('new_people',)):
        if not data.get('surfaces'):
            raise ValueError('模型返回了空结果：' + text[:200])
    for k in KEYS:
        if not isinstance(data.get(k), list):
            data[k] = []
    if not isinstance(data.get('surfaces'), dict):
        data['surfaces'] = {}
    usage = dict(usage or {})
    usage['_raw'] = text
    return data, usage


if __name__ == '__main__':
    import sys
    import time
    book = json.loads(Path(sys.argv[1]).read_text())
    body = [i for i, c in enumerate(book['chapters']) if c['kind'] == 'body']
    segs = segments(book, body)
    print(len(segs), 'segments')
    state = {'people': {}, 'rels': {}, 'seg': 0}
    t = time.time()
    data, usage = extract_segment(book, state, segs[int(sys.argv[2])], sys.argv[3])
    print(round(time.time() - t, 1), 's', usage.get('prompt_tokens'), usage.get('completion_tokens'))
    print(json.dumps(data, ensure_ascii=False, indent=1))
