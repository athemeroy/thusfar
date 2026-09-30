"""Phase 1 of the two-phase pipeline: local extraction, one segment at a time, in parallel.

The model sees ONLY this segment (plus the last lines of the previous one for continuity).
It names people the way this segment names them; phase 2 (link.py) decides who is who
across the book. Because no segment depends on another, hundreds can run concurrently,
and because nothing after the segment is ever shown, the output is causally safe.
"""
from __future__ import annotations

import os

from .extract import seg_text
from .lang import card_lang, local_note
from .llm import LLMError, chat, parse_json

LOCAL_MODEL = os.environ.get('LOCAL_MODEL', 'deepseek-flash+nothink')

SYSTEM = """你是细致的文学编辑，只根据给你的这一段小说原文，整理其中的人物信息。你看不到这段之前和之后的内容。

铁律：
1. 只写【本段原文】里写明或能直接推出的内容。即使你认出了这部作品、知道后来的情节，也绝不能写入任何本段没有交代的信息。
2. 人物就用本段里对他的称呼来命名；本段没说出名字的人，用本段里能区分他的称呼（如“新生”“黑衣人”“老太太”）。
3. 所有 quote 必须是【本段原文】中逐字出现的连续片段（中文 6～30 字；其他语言见下方语言说明），para 是所在段落编号（[P3] 填 3）。
4. 【上文】只帮助你理解开头的代词和场景，不要从中抽取任何内容。
5. 【已知人物】是前面章节已经出场的人物。本段的人如果就是其中某位（哪怕本段用的是别的称呼，如“公公”“老包法利”“那位太太”），在 known 里填他的编号；拿不准就留空，不要猜。

收录人物：有名字或反复出现、对情节有作用的角色（包括只用称谓出现的，如“校长”“老板娘”）。不收历史名人、神话人物、群体。

只输出一个紧凑的单行 JSON：
{"people":[{"id":"a","known":"P4 或空","name":"本段最能识别此人的称呼","names":["本段里称呼此人时实际用过的每一种写法"],"gender":"男|女|未知","role":"本段中他是谁（≤24字）","para":1,"quote":"首次出现处原文"}],
"same":[{"a":"a","b":"b","para":1,"quote":"...","why":"原文揭示 a 就是 b"}],
"events":[{"who":["a","b"],"text":"一句话事件（≤36字）","para":1,"quote":"...","imp":1}],
"facts":[{"who":"a","key":"身份|职业|住处|年龄|外貌|性格|处境|生死","value":"≤24字","para":1,"quote":"..."}],
"rels":[{"a":"a","b":"b","b_is":"b对a而言是什么","a_is":"a对b而言是什么","desc":"≤30字","para":1,"quote":"..."}]}

要求：
- names 列出本段每一种写法（全名、名、姓、字号、绰号、头衔），必须逐字出现在原文；不要代词和一次性描述。普通称谓（夫人、太太、先生、老爷、姑娘、二爷、老太太、医生、母亲等）前加 *。
- 同一个人在本段只建一个条目；若原文揭示两个称呼是同一人（如“新生”原来叫查理），分别建条目并写入 same。
- events：本段对情节或人物有意义的事，按顺序，每 1000 字至少 3 条；每个出场的重要人物至少一条。imp：3 重大，2 重要，1 一般。
- rels：本段写明或可直接推出的关系（亲属、婚恋、主仆、师生、朋友、敌对、雇佣、债务……），同时出场且有互动的人物之间都要考虑。
- facts：本段写明的身份、处境等；人物死亡写 key=生死。"""


CONCEPT_SYSTEM = """你是细致的编辑，只根据给你的这一段书稿，整理其中的**概念与术语**。你看不到这段之前和之后的内容。

铁律：
1. 只写【本段原文】里写明或能直接推出的内容。即使你读过这本书、知道后面的章节，也绝不能写入本段没有交代的信息。
2. 术语就用本段里的说法来命名（如“负反馈”“沉没成本”“阿赖耶识”）；本段没给出正式名称的概念，用本段里能指认它的说法。
3. 所有 quote 必须是【本段原文】中逐字出现的连续片段（中文 6～30 字；其他语言见下方语言说明），para 是所在段落编号（[P3] 填 3）。
4. 【上文】只帮助理解开头的指代，不要从中抽取内容。
5. 【已知概念】是前面章节已经讲过的概念。本段的概念如果就是其中某个（哪怕本段换了说法），在 known 里填它的编号；拿不准就留空。

收录（宁缺勿滥）：作者**明确定义、命名，或在本段反复使用**的概念、术语、方法、模型、定律；也收**书中出现的真实人物**（提出者、被引用的作者、案例中的人）。
不收：一次性提到的普通名词；书里的小标题、口号、问句（如“它讲的是什么？”“让观众喜欢上主角”这种整句）；代词和泛指（“他”“这个东西”）。
name 必须是**名词性的术语**（≤12 字），不能是整句话或问句；如果作者用一句话表达一个概念，请提炼成术语再写（如“救猫咪场景”而不是“让观众喜欢上主角”）。

只输出一个紧凑的单行 JSON（字段与小说模式相同，语义换成概念）：
{"people":[{"id":"a","known":"P4 或空","name":"术语或人名","names":["本段用到的每一种写法"],"gender":"未知","role":"截至本段，它是什么（≤24字）","para":1,"quote":"首次出现处原文"}],
"same":[{"a":"a","b":"b","para":1,"quote":"...","why":"原文说明两种说法指同一个概念"}],
"events":[{"who":["a"],"text":"本段对它做了什么：提出/定义/论证/举例/限定/反驳（≤36字）","para":1,"quote":"...","imp":1}],
"facts":[{"who":"a","key":"定义|别称|提出者|出处|适用范围|前提|局限|例子|公式","value":"≤24字","para":1,"quote":"..."}],
"rels":[{"a":"a","b":"b","b_is":"b 相对 a 是什么（上位/下位/组成部分/前提/结果/对立/同义/应用/提出者）","a_is":"a 相对 b 是什么","desc":"≤30字","para":1,"quote":"..."}]}

要求：
- names 写本段实际用过的写法（全称、简称、外文原词、缩写），必须逐字出现在原文。
- facts 的 **定义** 最重要：写本段给出的定义原意，不要用你自己知道的标准定义替换。
- events：本段围绕这些概念做的事，按顺序；每个重点概念至少一条。imp：3 核心概念，2 重要，1 一般。
- 条目数量有上限（见用户消息里的【本段长度】），只留最重要的；写不满没关系。
- rels：本段写明或可直接推出的概念之间的关系。"""


LANG_NAME = {'zh': '中文', 'ja': '日文', 'en': '英文', 'fr': '法文', 'de': '德文',
             'es': '西班牙文', 'it': '意大利文', 'pt': '葡萄牙文', 'nl': '荷兰文', 'ru': '俄文'}


def build(book: dict, seg: dict, prev: dict | None, cast_hint: str = '') -> list[dict]:
    lang = book.get('lang') or 'zh'
    cjk = lang in ('zh', 'ja')
    # A page of Latin or Cyrillic prose says about as much as a third of a page of Chinese, and a
    # quotable fragment is correspondingly longer: six to thirty characters is a phrase in Chinese
    # and one or two words in French. Both numbers used to be written for Chinese and applied to
    # every book, which meant a Russian novel was asked for three times too many events and for
    # quotes too short to locate.
    dense = 1 if cjk else 3
    # small models ignore "3 per 1000 characters" but obey a number: measured on gemini-flash-lite,
    # events per segment went from 3 to 10 (Terra writes 11) with this one line
    need = max(6, round(seg.get('chars', 0) / (300 * dense)))
    # a book of ideas has a handful of real terms per page; without a ceiling the model lists every noun
    cap = max(4, round(seg.get('chars', 0) / (800 * dense)))
    quote_lo, quote_hi = (6, 30) if cjk else (20, 100)
    concept = book.get('genre') in ('nonfiction', 'reference')
    ch = book['chapters'][seg['chapter']]
    chap = (ch.get('parent') + ' · ' if ch.get('parent') else '') + ch['title']
    before = ''
    if prev:
        tail = [book['blocks'][i]['t'] for i in prev['blocks'][-2:]]
        before = '\n'.join(t[-200:] for t in tail)
    user = f"""【作品】《{book['title']}》
【章节】{chap}

【{'已知概念' if concept else '已知人物'}】（前面章节已经出现过的，编号｜名字｜别称｜说明）
{cast_hint or '（暂无）'}

【上文】（仅供理解，不要抽取）
{before or '（无）'}

【本段原文】
{seg_text(book, seg)}

【本段长度】约 {seg.get('chars', 0)} 个字符，至少写满 {need} 条 events（按顺序，宁多勿少）；{'条目最多 ' + str(cap) + ' 个，宁缺勿滥' if concept else '人物、关系、facts 同样要抽全'}。

请输出 JSON。"""
    system = CONCEPT_SYSTEM if concept else SYSTEM
    return [{'role': 'system', 'content': system + lang_note(lang, quote_lo, quote_hi, card_lang(book)) + local_note(book)},
            {'role': 'user', 'content': user}]


def lang_note(lang: str, quote_lo: int, quote_hi: int, output_lang: str = 'zh') -> str:
    """What changes when the book is not Chinese.

    The rules above are written with Chinese examples, and a model reading a French novel has to be
    told two things explicitly: quotes and names are copied from the original and stay in it, while
    everything the reader will see on a card is written in Chinese. Left unsaid, a model will
    sometimes translate a name — and a translated name cannot be found in the passage, so every
    check that verifies a record against its text then fails.
    """
    if lang in ('zh', None):
        return ''
    name = LANG_NAME.get(lang, lang)
    output = '英文' if output_lang == 'en' else '中文'
    return f"""

【这本书是{name}的】
- quote 必须是原文（{name}）里逐字出现的连续片段，长度 {quote_lo}～{quote_hi} 个字符；不要翻译、不要改写、不要省略中间的词。
- name 和 names 也必须是原文里逐字出现的写法（{name}），不要译成中文，不要音译。
- role、text、value、desc、why 请用{output}写。
- 泛称加 * 的规则照旧，按{name}的习惯判断（如 Madame / Monsieur / Herr / Frau / Госпожа / 先生 / 奥さん 这类不是名字的称呼）。"""


KEYS = ('people', 'same', 'events', 'facts', 'rels')


def extract_local(book: dict, seg: dict, prev: dict | None, model: str = LOCAL_MODEL, cast_hint: str = '') -> tuple[dict, dict]:
    msgs = build(book, seg, prev, cast_hint)
    text, usage = chat(model, msgs, max_tokens=9000, temperature=0.2)
    try:
        data = parse_json(text)
    except ValueError:
        if '{' not in text and len(text.strip()) < 300:
            # "抱歉，我无法回答这个问题": a content filter, not malformed JSON; asking it to fix
            # the JSON only spends a second call on the same refusal
            raise LLMError('REFUSED: ' + text.strip()[:120])
        fix, u2 = chat(model, msgs + [{'role': 'assistant', 'content': text},
                                      {'role': 'user', 'content': '上面的输出不是合法 JSON。请只输出修正后的完整 JSON。'}],
                       max_tokens=9000, temperature=0)
        data = parse_json(fix)
        text = fix
        usage = {k: (usage.get(k) or 0) + (u2.get(k) or 0) for k in ('prompt_tokens', 'completion_tokens')}
    if not isinstance(data, dict):
        raise ValueError('模型没有返回 JSON 对象')
    for k in KEYS:
        if not isinstance(data.get(k), list):
            data[k] = []
    data = sanitize(data)
    if not data['people'] and seg.get('chars', 0) > 800 and not data['events']:
        raise ValueError('局部抽取为空：' + text[:160])
    usage = dict(usage or {})
    usage['_raw'] = text
    return data, usage


def _s(x) -> str:
    if isinstance(x, list):
        x = next((y for y in x if isinstance(y, str) and y), '')
    return x if isinstance(x, str) else ('' if x is None else str(x))


def sanitize(data: dict) -> dict:
    """Coerce every field to the expected type; drop entries that cannot be used."""
    people = []
    for p in data.get('people', []):
        if not isinstance(p, dict):
            continue
        names = p.get('names') if isinstance(p.get('names'), list) else [p.get('names')]
        p = dict(p, id=_s(p.get('id')) or f'x{len(people)}', name=_s(p.get('name')), known=_s(p.get('known')).strip(),
                 names=[_s(n) for n in names if _s(n)], role=_s(p.get('role')), quote=_s(p.get('quote')),
                 gender=_s(p.get('gender')))
        if p['name'] or p['names']:
            people.append(p)
    data['people'] = people
    for k in ('same', 'events', 'facts', 'rels'):
        data[k] = [x for x in data.get(k, []) if isinstance(x, dict)]
    for e in data['events']:
        e['who'] = [_s(w) for w in (e.get('who') if isinstance(e.get('who'), list) else [e.get('who')]) if _s(w)]
        e['text'] = _s(e.get('text'))
        e['quote'] = _s(e.get('quote'))
    for x in data['facts'] + data['rels'] + data['same']:
        for f in ('who', 'a', 'b', 'key', 'value', 'quote', 'b_is', 'a_is', 'desc', 'why'):
            if f in x:
                x[f] = _s(x[f])
    return data
