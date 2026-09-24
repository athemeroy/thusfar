"""Temporal knowledge graph: apply each segment's extraction to an append-only event log.

Every log record carries `p`, the UTF-16 position from which the reader may see it.
The reader folds all records with p <= cutoff to get "the world as known at this page".

Record types (t):
  person  {id, name, gender, imp, intro, s}      a character enters the story
  name    {id, name}                               display name changes (e.g. real name revealed)
  alias   {id, alias}                              another way the character is called
  merge   {from, into, reason, s}                  two records turn out to be the same person
  event   {who[], text, imp, s}
  attr    {id, key, value, s}
  rel     {a, b, a_is, b_is, desc, status, s}
  profile {id, tagline, bio, chk}
  imp     {id, imp}                                how much this person matters, re-judged as the book goes
  cnt     {c: {id: mentions in this segment}}
  recap   {chapter, text}  /  saga {text}
"""
from __future__ import annotations

import re

from .lang import scale
from .parse import u16

PRONOUNS = {'他', '她', '它', '他们', '她们', '我', '你', '您', '我们', '你们', '咱们', '自己', '人家', '对方', '此人', '那人', '这人',
            # ways of saying "I" that are not names (老衲 was once stored as a monk's alias)
            '老衲', '贫僧', '贫道', '贫尼', '本座', '老夫', '在下', '小的', '奴家', '本王', '朕', '寡人', '哀家', '老子', '小爷',
            '本少', '本少爷', '本姑娘', '老娘', '洒家', '俺', '咱', '晚辈', '小女子', '老身', '妾身', '微臣', '奴婢', '属下',
            '末将', '本官', '本宫', '小生', '鄙人', '区区', '为师', '本尊', '老朽', '小弟', '本帅', '本公子', '哥们', '兄弟',
            'i', 'me', 'my', 'he', 'him', 'his', 'she', 'her', 'it', 'we', 'us', 'you', 'they', 'them', 'myself',
            'himself', 'herself', 'someone', 'somebody', 'nobody', 'everyone', 'stranger', 'the stranger',
            # "someone", "the one who asked": not people the reader can look up
            '有人', '某人', '众人', '来人', '旁人', '别人', '他人', '路人', '大家', '所有人', '问话之人', '说话之人', '说话的人',
            '那个人', '这个人', '其他人', '其余人', '另一人', '一人', '二人', '两人', '三人', '对面的人', '神秘人'}
GENERIC = {'父亲', '母亲', '爸爸', '妈妈', '爹', '娘', '儿子', '女儿', '丈夫', '妻子', '太太', '夫人', '先生', '老爷',
           '小姐', '姑娘', '少女', '女孩', '少年', '男孩', '青年', '少爷', '医生', '大夫', '校长', '老师', '神父', '堂长', '老板', '老板娘', '仆人', '女仆',
           '老头子', '老太太', '老头', '孩子', '哥哥', '姐姐', '弟弟', '妹妹', '叔叔', '伯父', '舅舅', '姑妈', '姨妈',
           '祖父', '祖母', '爷爷', '奶奶', '外公', '外婆', '公公', '婆婆', '岳父', '岳母', '丈人', '主人', '客人',
           '新娘', '新郎', '寡妇', '邻居', '朋友', '同学', '学生', '病人', '国王', '王后', '皇帝', '公爵', '伯爵',
           '侯爵', '男爵', '夫人们', '大人', '老人', '年轻人', '女人', '男人', '先生们', '女婿', '未婚女婿',
           '未婚妻', '未婚夫', '媳妇', '儿媳', '新娘子', '新夫人', '闺女', '商人', '妇人', '男子', '女子', '内人',
           '仆役', '听差', '差役', '守卫', '向导', '乡下人', '乡下佬', '小伙子', '姑娘们', '神甫', '教士', '和尚', '尼姑'}
# English titles and descriptions that can mean anyone (compared lower-case, after dropping the/my/old …)
GENERIC_EN = set('''father mother dad mum mom papa mamma son daughter husband wife sir madam ma'am miss mister mrs mr
lady lord gentleman gentlemen doctor physician surgeon lawyer attorney clerk servant maid housekeeper cook butler
footman coachman landlord landlady master mistress boy girl child baby man woman men women lad lass fellow
brother sister uncle aunt nephew niece cousin grandfather grandmother grandpa grandma king queen prince princess
duke duchess earl count countess baron baroness captain colonel general major sergeant soldier officer constable
inspector judge magistrate prisoner convict parson vicar priest clergyman curate reverend bishop nurse governess
schoolmaster teacher pupil student friend neighbour neighbor visitor guest host hostess stranger bride bridegroom
widow widower orphan beggar driver porter waiter waitress shopkeeper merchant sailor fisherman farmer blacksmith
smith guard keeper doorman secretary partner person people creature figure visitor thing one other others'''.split())
EN_PREFIX = re.compile(r"^(?:the|a|an|this|that|these|those|my|his|her|their|our|your|old|young|little|poor|dear|good|elder|younger)\s+", re.I)


def is_latin(s: str) -> bool:
    return bool(re.search(r'[A-Za-z]', s or '')) and not re.search(r'[\u3400-\u9fff]', s or '')


def generic_word(f: str) -> bool:
    """A kinship word, title or description rather than a name (Chinese or English)."""
    f = (f or '').strip()
    if is_latin(f):
        g = f.lower().rstrip('.')
        while EN_PREFIX.match(g):
            g = EN_PREFIX.sub('', g, count=1)
        return g in GENERIC_EN or g in PRONOUNS or g.rstrip('s') in GENERIC_EN
    return f in GENERIC or f.lstrip('他她的老小') in GENERIC
PUNCT = re.compile(r'[\s，。、；：？！“”‘’「」『』（）()《》〈〉…—\-·・,.;:?!"\'\[\]【】]')


CJK = r'[\u3400-\u9fff\uff00-\uffef\u3000-\u303f“”‘’]'
_PUNCT_MAP = {',': '，', ';': '；', ':': '：', '?': '？', '!': '！', '(': '（', ')': '）'}


def zh(text):
    """Use full-width punctuation next to Chinese characters (models often mix in ASCII)."""
    if not isinstance(text, str) or not text:
        return text
    text = re.sub(r'"([^"\n]{1,60})"', r'“\1”', text)
    return re.sub(r'(?<=' + CJK + r')\s*([,;:?!()])\s*|\s*([,;:?!()])\s*(?=' + CJK + r')',
                  lambda m: _PUNCT_MAP[m.group(1) or m.group(2)], text)


def good_alias(a: str) -> bool:
    """A name or nickname, not a kinship word, a couple, a group or a description."""
    if not a or a in PRONOUNS or a.lower() in PRONOUNS or generic_word(a) or a.lstrip('他她的老小未') in GENERIC:
        return False
    if is_latin(a):
        return not re.search(r"\b(?:and|family|brothers|sisters|folks|people)\b|'s\b", a, re.I)
    return not any(x in a for x in ('夫妇', '夫妻', '们', '一家', '俩', '的'))


def _norm(s: str) -> tuple[str, list[int]]:
    out, idx = [], []
    for i, ch in enumerate(s):
        if not PUNCT.match(ch):
            out.append(ch)
            idx.append(i)
    return ''.join(out), idx


class Anchor:
    """Locate model-provided quotes inside a segment and turn them into global positions."""

    def __init__(self, book: dict, seg: dict):
        self.blocks = [book['blocks'][i] for i in seg['blocks']]
        self.seg = seg

    def _g(self, b: dict, i: int) -> int:
        return b['o'] + u16(b['t'][:i])

    def block(self, para) -> dict | None:
        try:
            n = int(para)
        except (TypeError, ValueError):
            return None
        return self.blocks[n - 1] if 1 <= n <= len(self.blocks) else None

    def find(self, quote: str | None, para=None) -> tuple[int, int] | None:
        if not quote or len(quote) < 2:
            return None
        b0 = self.block(para)
        order = [b0] if b0 else []
        if b0:
            k = self.blocks.index(b0)
            order += [self.blocks[j] for j in (k - 1, k + 1, k - 2, k + 2) if 0 <= j < len(self.blocks)]
        order += [b for b in self.blocks if b not in order]
        for b in order:
            i = b['t'].find(quote)
            if i >= 0:
                return self._g(b, i), self._g(b, i + len(quote))
        nq, _ = _norm(quote)
        if len(nq) < 3:
            return None
        for b in order:
            nt, idx = _norm(b['t'])
            i = nt.find(nq)
            if i >= 0:
                return self._g(b, idx[i]), self._g(b, idx[i + len(nq) - 1] + 1)
        # long quotes: try the first half (models sometimes paraphrase the tail)
        if len(nq) >= 12:
            half = nq[:len(nq) // 2]
            for b in order:
                nt, idx = _norm(b['t'])
                i = nt.find(half)
                if i >= 0:
                    return self._g(b, idx[i]), self._g(b, idx[i + len(half) - 1] + 1)
        return None

    def para_end(self, para) -> int:
        b = self.block(para) or self.blocks[-1]
        return b['o'] + u16(b['t'])

    def pos(self, para, quote) -> tuple[int, int]:
        hit = self.find(quote, para)
        if hit:
            return hit
        b = self.block(para)
        if b:
            return b['o'], b['o'] + u16(b['t'])
        return self.seg['o1'], self.seg['o1']

    def first(self, surface: str, after: int = -1) -> tuple[int, int] | None:
        for b in self.blocks:
            start = 0
            while True:
                i = b['t'].find(surface, start)
                if i < 0:
                    break
                t = b['t']
                if surface[:1].isascii() and surface[:1].isalpha() and (
                        (i and t[i - 1].isascii() and t[i - 1].isalpha()) or t[i + len(surface):i + len(surface) + 1].isascii()
                        and t[i + len(surface):i + len(surface) + 1].isalpha()):
                    start = i + 1       # part of a longer word (Ann in Anne)
                    continue
                g = self._g(b, i)
                if g >= after:
                    return g, self._g(b, i + len(surface))
                start = i + 1
        return None


class KG:
    def __init__(self, book: dict):
        self.book = book
        self.k = scale(book)      # English cards need ~3x the characters
        self.people: dict[str, dict] = {}
        self.rels: dict[str, dict] = {}
        self.log: list[dict] = []
        self.mentions: list[list] = []
        self.recent: list[str] = []
        self.saga = ''
        self.n = 0
        self.seg = 0
        self.warnings: list[str] = []

    # ------------------------------------------------------------ registry helpers
    def canon(self, pid: str | None) -> str | None:
        seen = set()
        while pid and pid in self.people and self.people[pid].get('merged_into') and pid not in seen:
            seen.add(pid)
            pid = self.people[pid]['merged_into']
        return pid

    def lookup(self, x, refmap: dict) -> str | None:
        if not isinstance(x, str):
            return None
        x = x.strip()
        if x in refmap:
            return refmap[x]
        if x in self.people:
            return self.canon(x)
        for p in self.people.values():   # the model sometimes writes a name instead of an id
            if not p.get('merged_into') and (x == p['name'] or x in p['aliases']):
                return p['id']
        return None

    def prompt_state(self) -> dict:
        people = {}
        for pid, p in self.people.items():
            people[pid] = {'id': pid, 'name': p['name'], 'aliases': sorted(p['aliases'] - {p['name']}),
                           'tagline': p.get('tagline', ''), 'bio': p.get('bio', ''), 'importance': p.get('imp', 1),
                           'mentions': p.get('mentions', 0), 'last_seg': p.get('last_seg', -99),
                           'merged_into': p.get('merged_into')}
        return {'people': people, 'rels': self.rels, 'seg': self.seg, 'recent_events': self.recent[-12:],
                'saga': self.saga}

    def describe(self, pid: str) -> str:
        p = self.people[pid]
        return f"{p['name']}（{p.get('tagline') or p.get('intro') or ''}）"

    # ------------------------------------------------------------ planning
    def plan(self, seg: dict, data: dict) -> dict:
        """Assign ids to new people and list the name occurrences that need a decision."""
        refmap: dict[str, str] = {}
        n = self.n
        for np in data.get('new_people', []):
            ref = str(np.get('ref') or '')
            if ref and ref not in refmap:
                n += 1
                refmap[ref] = f'P{n}'
        # surface → candidate ids
        surf: dict[str, dict] = {}
        for who, forms in (data.get('surfaces') or {}).items():
            pid = refmap.get(who) or (self.canon(who) if who in self.people else None)
            if not pid or not isinstance(forms, list):
                continue
            for f in forms:
                if not isinstance(f, str):
                    continue
                generic = f.startswith('*')
                f = f.lstrip('*').strip()
                generic = generic or generic_word(f)
                if len(f) < 2 or f in PRONOUNS or f.lower() in PRONOUNS:
                    continue
                e = surf.setdefault(f, {'ids': [], 'generic': False})
                if pid not in e['ids']:
                    e['ids'].append(pid)
                e['generic'] |= generic
        occs = []
        if surf:
            # Latin names must match whole words (Ann is not in Anne); Chinese has no word breaks
            rx = re.compile('|'.join(r'(?<![A-Za-z])' + re.escape(s) + r'(?![A-Za-z])' if re.match(r'[A-Za-z]', s[-1:] or ' ') else re.escape(s)
                                     for s in sorted(surf, key=len, reverse=True)))
            for bi in seg['blocks']:
                b = self.book['blocks'][bi]
                for m in rx.finditer(b['t']):
                    e = surf[m.group(0)]
                    s = b['o'] + u16(b['t'][:m.start()])
                    occs.append({'key': f'{s}', 'bi': bi, 'i': m.start(), 'j': m.end(), 's': s,
                                 'e': s + u16(m.group(0)), 'surface': m.group(0), 'ids': e['ids'],
                                 'generic': e['generic'],
                                 'ambiguous': len(e['ids']) > 1 or e['generic']})
        return {'refmap': refmap, 'surfaces': surf, 'occs': occs}

    # ------------------------------------------------------------ commit
    def commit(self, seg: dict, data: dict, plan: dict, decisions: dict, guard: dict | None = None):
        A = Anchor(self.book, seg)
        known_names = {n for p in self.people.values() for n in (p['aliases'] | {p['name']})}
        refmap = plan['refmap']
        log = []
        L = lambda rec: log.append(rec)   # noqa: E731
        ref = lambda x: self.lookup(x, refmap)  # noqa: E731

        # new people ---------------------------------------------------
        for np in data.get('new_people', []):
            pid = refmap.get(str(np.get('ref') or ''))
            if not pid or pid in self.people:
                continue
            self.n = max(self.n, int(pid[1:]))
            s, e = A.pos(np.get('para'), np.get('quote'))
            name = (np.get('name') or '').strip() or '无名氏'
            # what can the reader call this person at the moment of entry?
            forms = [f for f, v in plan['surfaces'].items() if pid in v['ids']]
            firsts = sorted((A.first(f)[0], f) for f in forms if A.first(f))
            name_hit = A.first(name)
            shown = name
            if name_hit and name_hit[0] > s and not generic_word(name):
                # Even a reveal on the next line must not be moved back to entry.
                early = [(pos, f) for pos, f in firsts if s - 50 <= pos < name_hit[0]]
                proper = [x for x in early if not plan['surfaces'][x[1]]['generic']]
                if proper or early:
                    shown = (proper or early)[0][1]
            imp = np.get('importance') if np.get('importance') in (1, 2, 3) else 1
            gender = np.get('gender') if np.get('gender') in ('男', '女') else ''
            intro = (np.get('intro') or '').strip()[:40 * self.k]
            entry = s if shown != name or not name_hit else max(s, name_hit[1])
            # Descriptions are supported against the complete segment, so expose
            # them at that frontier independently of the person's entry.
            L({'t': 'person', 'p': entry, 's': s, 'id': pid, 'name': shown, 'gender': gender, 'imp': imp,
               'intro': ''})
            if intro:
                L({'t': 'profile', 'p': seg['o1'], 'id': pid, 'tagline': intro, 'bio': '', 'kind': 'intro'})
            if shown != name and name_hit:
                L({'t': 'name', 'p': name_hit[1], 'id': pid, 'name': name})
            self.people[pid] = {'id': pid, 'name': name, 'aliases': {name, shown}, 'gender': gender, 'imp': imp,
                                'intro': intro, 'tagline': intro, 'bio': '', 'first': entry, 'mentions': 0,
                                'profile_p': seg['o1'] if intro else -1,
                                'last_seg': self.seg}

        # aliases ----------------------------------------------------------
        for a in data.get('aliases', []):
            pid = ref(a.get('who'))
            alias = (a.get('alias') or '').strip()
            if not pid or not alias or not good_alias(alias):
                continue
            s, e = A.pos(a.get('para'), a.get('quote') or alias)
            hit = A.first(alias)
            p = hit[1] if hit else e
            L({'t': 'alias', 'p': p, 'id': pid, 'alias': alias})
            person = self.people[pid]
            person['aliases'].add(alias)
            if a.get('primary') and alias != person['name']:
                L({'t': 'name', 'p': p, 'id': pid, 'name': alias})
                person['name'] = alias
        # generic titles used for someone are remembered for linking (never shown as aliases)
        for f, v in plan['surfaces'].items():
            if v['generic']:
                for pid in v['ids']:
                    if pid in self.people:
                        self.people[pid].setdefault('weak', set()).add(f)
        # surfaces that are proper names become aliases at their first occurrence
        for f, v in plan['surfaces'].items():
            if v['generic'] or len(v['ids']) != 1 or not good_alias(f):
                continue
            pid = v['ids'][0]
            if f in self.people.get(pid, {}).get('aliases', ()):
                continue
            hit = A.first(f)
            if hit:
                L({'t': 'alias', 'p': hit[1], 'id': pid, 'alias': f})
                self.people[pid]['aliases'].add(f)
                if generic_word(self.people[pid]['name']):
                    # known so far only as "the old monk": the first real name becomes the display name
                    L({'t': 'name', 'p': hit[1], 'id': pid, 'name': f})
                    self.people[pid]['name'] = f

        # events / attrs / rels -------------------------------------------
        for ev in data.get('events', []):
            who = [x for x in (ref(w) for w in (ev.get('who') or [])) if x]
            text = (ev.get('text') or '').strip()
            if not text:
                continue
            s, e = A.pos(ev.get('para'), ev.get('quote'))
            imp = ev.get('importance') if ev.get('importance') in (1, 2, 3) else 1
            L({'t': 'event', 'p': e, 's': s, 'who': list(dict.fromkeys(who)), 'text': text[:80 * self.k], 'imp': imp})
            self.recent.append(text)
        for at in data.get('attrs', []):
            pid = ref(at.get('who'))
            if not pid or not at.get('key') or not at.get('value'):
                continue
            s, e = A.pos(at.get('para'), at.get('quote'))
            L({'t': 'attr', 'p': e, 's': s, 'id': pid, 'key': str(at['key'])[:8 * self.k], 'value': str(at['value'])[:40 * self.k]})
        for r in data.get('rels', []):
            a, b = ref(r.get('a')), ref(r.get('b'))
            if not a or not b or a == b:
                continue
            s, e = A.pos(r.get('para'), r.get('quote'))
            if r.get('by') in ('judge', 'judge+llm') or r.get('evidence_scope') == 'segment':
                e = seg['o1']
            status = r.get('status') if r.get('status') in ('new', 'changed', 'ended') else 'new'
            # models sometimes echo the field name ("a的女儿") — that must never reach a card
            for f in ('a_is', 'b_is'):
                if isinstance(r.get(f), str):
                    r[f] = re.sub(r'^[abAB]\s*的\s*', '', r[f].strip())
            lab = 12 if self.k == 1 else 48      # "distant kinsman and walking companion"
            rec = {'t': 'rel', 'p': e, 's': s, 'a': a, 'b': b, 'a_is': (r.get('a_is') or '')[:lab],
                   'b_is': (r.get('b_is') or '')[:lab], 'desc': (r.get('desc') or '')[:60 * self.k], 'status': status}
            L(rec)
            self.rels['|'.join(sorted((a, b)))] = {k: rec[k] for k in ('a', 'b', 'a_is', 'b_is', 'desc', 'status')}

        # profiles ---------------------------------------------------------
        checks = (guard or {}).get('checks', {})
        for pr in data.get('profiles', []):
            pid = ref(pr.get('who'))
            if not pid:
                continue
            tagline = (pr.get('tagline') or '').strip()[:30 * self.k]
            bio = (pr.get('bio') or '').strip()[:400 * self.k]
            if not tagline and not bio:
                continue
            p = seg['o1'] if pr.get('evidence_scope') == 'segment' else A.para_end(pr.get('para'))
            rec = {'t': 'profile', 'p': p, 'id': pid, 'tagline': tagline, 'bio': bio}
            chk = checks.get(str(pr.get('who')))
            if chk:
                rec['chk'] = chk
            L(rec)
            person = self.people[pid]
            if p >= person.get('profile_p', -1):
                person['tagline'] = tagline or person.get('tagline', '')
                person['bio'] = bio or person.get('bio', '')
                person['profile_p'] = p

        # Resolve dated references before mutating the identity registry: a
        # later reveal must not canonicalize earlier events or attributes.
        for m in data.get('merges', []):
            a, b = ref(m.get('from')), ref(m.get('into'))
            if not a or not b or a == b:
                continue
            s, e = A.pos(m.get('para'), m.get('quote'))
            L(self.merge(a, b, e, s, m.get('reason') or ''))

        # mentions ---------------------------------------------------------
        counts: dict[str, int] = {}
        for o in plan['occs']:
            if o['ambiguous']:
                pid = decisions.get(o['key'])
            else:
                pid = o['ids'][0]
            if not pid:
                continue
            if self.people.get(pid, {}).get('first', 0) > o['e']:
                # decided on a record that enters later in this segment: fall back to one already present
                alt = [x for x in o['ids'] if self.people.get(x, {}).get('first', 1 << 60) <= o['e']]
                if not alt:
                    continue
                pid = alt[0]
            self.mentions.append([o['s'], o['e'], pid, 1 if o['generic'] else 0])
            cid = self.canon(pid)
            counts[cid] = counts.get(cid, 0) + 1
            self.people[cid]['mentions'] = self.people[cid].get('mentions', 0) + 1
            self.people[cid]['last_seg'] = self.seg
        for pid in {x for rec in log for x in ([rec.get('id')] + rec.get('who', []) + [rec.get('a'), rec.get('b')]) if x}:
            if pid in self.people:
                self.people[self.canon(pid)]['last_seg'] = self.seg
        if counts:
            L({'t': 'cnt', 'p': seg['o1'], 'c': counts})
        # a record about someone must never become visible before that person enters
        intro = {r['id']: r['p'] for r in log if r['t'] == 'person'}
        # ...and before a reveal ("the new boy is Charles"), facts belong to the identity the
        # reader already knows, not to the one revealed later
        early_id = {m['into']: m['from'] for m in log if m['t'] == 'merge' and m['into'] in intro}

        def before(x, p):
            src = early_id.get(x)
            return src if src and p < intro[x] and intro.get(src, -1) <= p else x
        for r in log:
            if r['t'] == 'event':
                r['who'] = list(dict.fromkeys(before(x, r['p']) for x in r['who']))
            elif r['t'] in ('attr', 'alias', 'profile') and r.get('id') in early_id:
                r['id'] = before(r['id'], r['p'])
            elif r['t'] == 'rel':
                r['a'], r['b'] = before(r['a'], r['p']), before(r['b'], r['p'])
        # generated text written before a name is revealed must not use that name
        reveals = []   # (name, position it becomes known, what the reader calls the person before)
        shown = {r['id']: r['name'] for r in log if r['t'] == 'person'}
        for r in log:
            if r['t'] == 'name' and r['id'] in shown:
                reveals.append((r['name'], r['p'], shown[r['id']]))
        for into, frm in early_id.items():
            old_name = shown.get(frm) or self.people.get(frm, {}).get('name')
            if not old_name:
                continue
            forms = [f for f, v in plan['surfaces'].items() if into in v['ids'] and not v['generic']]
            for f in set(forms + [self.people[into]['name']]):
                hit = A.first(f)
                reveals.append((f, hit[0] if hit else intro[into], old_name))
        reveals.sort(key=lambda x: -len(x[0]))
        if reveals:
            def scrub(text, p):
                for name, q, old_name in reveals:
                    if p < q and name and name in text and name != old_name:
                        text = text.replace(old_name + name, old_name).replace(name, old_name)
                return text
            for r in log:
                for k in ('text', 'value', 'tagline', 'bio', 'intro', 'desc'):
                    if isinstance(r.get(k), str):
                        r[k] = scrub(r[k], r['p'])
        # generated text may not mention a name before that name first appears in the original
        fresh = {n for p in self.people.values() for n in (p['aliases'] | {p['name']})
                 if len(n) >= 2 and n not in known_names and n not in GENERIC}
        first_at = {}
        for n in fresh:
            hit = A.first(n)
            if hit:
                first_at[n] = hit[1]
        if first_at:
            for r in log:
                if r['t'] in ('person', 'cnt'):
                    continue
                text = ' '.join(str(r.get(k) or '') for k in ('text', 'value', 'tagline', 'bio', 'intro', 'desc'))
                for n, q in first_at.items():
                    if q > r['p'] and n in text:
                        r['p'] = q
        for r in log:
            if r['t'] in ('attr', 'alias', 'name', 'profile') and r.get('id') in intro:
                r['p'] = max(r['p'], intro[r['id']])
            elif r['t'] == 'rel':
                r['p'] = max(r['p'], intro.get(r['a'], 0), intro.get(r['b'], 0))
            elif r['t'] == 'event':
                r['p'] = max([r['p']] + [intro.get(w, 0) for w in r['who']])
            elif r['t'] == 'merge':
                r['p'] = max(r['p'], intro.get(r['from'], 0), intro.get(r['into'], 0))
        for r in log:
            for k in ('text', 'value', 'tagline', 'bio', 'intro', 'desc', 'reason'):
                if isinstance(r.get(k), str):
                    r[k] = zh(r[k])
        self.log.extend(log)
        self.seg += 1
        return log

    def merge(self, a: str, b: str, p: int, s: int, reason: str, kind: str = '') -> dict:
        """Record that a is b from position p on (the log record is returned, not appended)."""
        rec = {'t': 'merge', 'p': p, 's': s, 'from': a, 'into': b, 'reason': reason[:80 * self.k]}
        if kind:
            rec['kind'] = kind
        src, dst = self.people[a], self.people[b]
        src['merged_into'] = b
        dst['aliases'] |= src['aliases']
        # A later real name must replace a temporary description even when
        # the model chooses the description's id as the merge destination.
        if generic_word(dst['name']) and not generic_word(src['name']):
            dst['name'] = src['name']
        dst.setdefault('weak', set()).update(src.get('weak', ()))
        dst['mentions'] = dst.get('mentions', 0) + src.get('mentions', 0)
        dst['imp'] = max(dst.get('imp', 1), src.get('imp', 1))
        for k, r in list(self.rels.items()):
            if a in (r['a'], r['b']):
                del self.rels[k]
                r = dict(r, a=b if r['a'] == a else r['a'], b=b if r['b'] == a else r['b'])
                if r['a'] != r['b']:
                    self.rels['|'.join(sorted((r['a'], r['b'])))] = r
        return rec

    def add_recap(self, chapter: int, pos: int, recap: str, saga: str):
        recap, saga = zh(recap), zh(saga)
        if recap:
            self.log.append({'t': 'recap', 'p': pos, 'chapter': chapter, 'text': recap})
        if saga:
            self.log.append({'t': 'saga', 'p': pos, 'text': saga})
            self.saga = saga


def quarantine_identities(records, mentions, seeds):
    """Withhold identity-dependent output without guessing a merged ID's origin.

    Equivalence before a taint starts inherits that taint's date; a later merge
    inherits it only from the later reveal. Person introductions remain usable,
    while affected subsequent facts and mentions require explicit relinking.
    """
    taint = dict(seeds)
    edges = [(r['from'], r['into'], r['p']) for r in records if r.get('t') == 'merge']
    changed = True
    while changed:
        changed = False
        for a, b, pos in edges:
            for source, target in ((a, b), (b, a)):
                if source in taint:
                    start = max(pos, taint[source])
                    if start < taint.get(target, float('inf')):
                        taint[target] = start
                        changed = True
    kept, withheld = [], []
    for row in records:
        if row.get('t') == 'person' and row['p'] >= taint.get(row.get('id'), float('inf')) and row.get('intro'):
            withheld.append(row)
            kept.append(dict(row, intro=''))
            continue
        refs = [row[k] for k in ('id', 'a', 'b', 'from', 'into') if k in row]
        refs += row.get('who', []) + list((row.get('c') or {}).keys())
        unsafe = row.get('t') != 'person' and any(row['p'] >= taint.get(pid, float('inf')) for pid in refs)
        (withheld if unsafe else kept).append(row)
    safe_mentions, withheld_mentions = [], []
    for mention in mentions:
        (withheld_mentions if mention[1] >= taint.get(mention[2], float('inf')) else safe_mentions).append(mention)
    return kept, safe_mentions, withheld, withheld_mentions, taint
