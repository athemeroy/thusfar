"""Jev decision-model jobs.

Jev is a fast probabilistic classifier. It is used where the question is a genuine
multiple-choice decision, never as a pass/fail gate on every extracted item:

  resolve_mentions  which character does this ambiguous name/title refer to?
  guard_texts       does a generated description claim anything the text so far does not
                    establish (hallucination or spoiler from the model's prior knowledge)?
  route_question    what kind of reader question is this (and is it asking about the future)?
"""
from __future__ import annotations

import re
from concurrent.futures import ThreadPoolExecutor

from .llm import jev, LLMError

BATCH = 48      # the judge answers 64 questions as fast as 16, and every call repeats the passage


def bounded_passage(passage: str) -> str:
    if len(passage) > 12000:
        raise LLMError('原文段落超过核对上下文上限，已暂停；请先拆分长段落，不能截断证据后继续判断')
    return passage


def _context(text: str, i: int, j: int, before: int = 200, after: int = 80) -> str:
    """Passage around text[i:j] with the mention wrapped in 【】, cut at sentence edges."""
    a = max(0, i - before)
    b = min(len(text), j + after)
    m = re.search(r'[。！？!?…」”]', text[j:b])
    if m:
        b = j + m.end()
    return text[a:i] + '【' + text[i:j] + '】' + text[j:b]


def resolve_mentions(book: dict, seg: dict, occs: list[dict], describe) -> tuple[dict, list]:
    """Decide ambiguous occurrences. Returns ({key: id|None}, raw answers for the record)."""
    todo = [o for o in occs if o['ambiguous']]
    if not todo:
        return {}, []
    # context comes from the whole segment so the passage can span paragraphs
    seg_text = ''
    offsets = {}
    for bi in seg['blocks']:
        offsets[bi] = len(seg_text)
        seg_text += book['blocks'][bi]['t'] + '\n'
    batches = [todo[k:k + BATCH] for k in range(0, len(todo), BATCH)]

    def run(batch):
        ids = sorted({x for o in batch for x in o['ids']})
        state = {'characters': {pid: describe(pid) for pid in ids}, 'passages': {}}
        questions = {}
        for n, o in enumerate(batch, 1):
            qid = f'q{n}'
            base = offsets[o['bi']]
            state['passages'][qid] = _context(seg_text, base + o['i'], base + o['j'])
            criteria = {pid: describe(pid) for pid in o['ids']}
            criteria['none'] = 'None of the listed characters: another person, a group, or the word is used generically / not as a reference to a specific character.'
            questions[qid] = {
                'type': 'choice',
                'instructions': (f'Passage {qid} is from a Chinese novel. Which character does the marked mention '
                                 f'【{o["surface"]}】 refer to in passage {qid}? Decide from the passage and the '
                                 'character descriptions only.'),
                'criteria': criteria,
            }
        answers = jev(state, questions)
        out = {}
        for n, o in enumerate(batch, 1):
            a = answers.get(f'q{n}') or {}
            probs = a.get('probabilities') or {}
            choice = a.get('choice')
            p = probs.get(choice, 0)
            out[o['key']] = {'choice': choice, 'p': round(p, 3), 'surface': o['surface']}
        return out

    raw = {}
    with ThreadPoolExecutor(4) as ex:
        for part in ex.map(run, batches):
            raw.update(part)
    decisions = {}
    for o in todo:
        r = raw.get(o['key']) or {}
        ok = r.get('choice') in o['ids'] and r.get('p', 0) >= 0.55
        decisions[o['key']] = r['choice'] if ok else None
    return decisions, raw


def guard_texts(passage: str, earlier: dict[str, str], items: dict[str, str]) -> dict[str, dict]:
    """Ask Jev whether each generated text is established by the passage + earlier notes.

    items: {key: text}. Returns {key: {'verdict': 'ok'|'flag', 'p': prob_supported}}.
    """
    if not items:
        return {}
    out = {}
    keys = list(items)
    for k0 in range(0, len(keys), BATCH):
        chunk = keys[k0:k0 + BATCH]
        state = {'passage_read_so_far': passage, 'earlier_notes': earlier}
        questions = {}
        for n, k in enumerate(chunk, 1):
            note_key = f'note_g{n}'
            state[note_key] = items[k]
            questions[f'g{n}'] = {
                'type': 'choice',
                'instructions': (
                    'A spoiler-free reading companion wrote the note below about a novel. The reader has read only '
                    f'passage_read_so_far (plus what earlier_notes summarise). Judge {note_key} as a claim, '
                    'not as evidence. Only passage_read_so_far and earlier_notes can support it.'),
                'criteria': {
                    'supported': 'Every claim in the note is stated in, or directly follows from, the passage or the earlier notes.',
                    'beyond_text': 'The note asserts something (an event, identity, relationship, fate or later development) that the passage and earlier notes do not establish.',
                    'contradicted': 'The note contradicts the passage.',
                },
            }
        answers = jev(state, questions)
        for n, k in enumerate(chunk, 1):
            a = answers.get(f'g{n}') or {}
            probs = a.get('probabilities') or {}
            bad = probs.get('beyond_text', 0) + probs.get('contradicted', 0)
            out[k] = {'verdict': 'flag' if bad >= 0.6 else 'ok', 'p': round(probs.get('supported', 0), 3),
                      'choice': a.get('choice')}
    return out


def check_facts(passage: str, facts: dict[str, tuple[str, str, str, str]]) -> dict[str, dict]:
    """facts: {key: (name, who_they_are, attribute, value)}. Judges only the attribute value.

    The identifying description goes into the state, not into the claim, so JEV does not
    treat "who is meant" as something to verify (and cannot confuse two people sharing a title)."""
    if not facts:
        return {}
    out = {}
    keys = list(facts)
    for k0 in range(0, len(keys), BATCH):
        chunk = keys[k0:k0 + BATCH]
        state = {'passage_read_so_far': passage,
                 'characters': {f'c{n}': f'{facts[k][0]}: {facts[k][1]}' for n, k in enumerate(chunk, 1)}}
        questions = {}
        for n, k in enumerate(chunk, 1):
            name, _, attr, value = facts[k]
            questions[f'f{n}'] = {
                'type': 'choice',
                'instructions': (f'Character c{n} ("{name}", see characters.c{n} only to know WHO is meant; do not judge that '
                                 f'description). Claimed attribute of this character — {attr}: {value}. '
                                 'Judge only this attribute against passage_read_so_far.'),
                'criteria': {
                    'supported': 'The passage states or clearly implies this about this character.',
                    'not_in_passage': 'The passage does not establish this about this character (it may come from outside knowledge or be about someone else).',
                    'contradicted': 'The passage contradicts it.',
                },
            }
        answers = jev(state, questions)
        for n, k in enumerate(chunk, 1):
            a = answers.get(f'f{n}') or {}
            probs = a.get('probabilities') or {}
            out[k] = {'p': round(probs.get('supported', 0), 3), 'choice': a.get('choice'),
                  'probs': {x: round(v, 3) for x, v in probs.items()}}
    return out


# Relations as a small tree: first which kind of tie (8 well-separated families), then the exact
# role inside it, then two independent facets (how they stand, and whether it still holds).
# Two families both above 0.35 means both ties are real — a wife who is also a creditor.
FAMILIES = {
    'kin': ('血亲', 'family', 'They are family by blood, adoption or a sworn bond (parent, child, sibling, cousin, adopted or sworn kin)'),
    'marriage': ('姻亲', 'by marriage', 'A tie by marriage: husband and wife, betrothed, in-laws, step-family, a widow and her late husband'),
    'romance': ('情感', 'romantic', 'A romantic tie: lovers, an affair, a suitor, one-sided love, two people who both want the same person'),
    'power': ('主从', 'authority', 'One stands above the other: master/servant, employer/employee, officer/subordinate, master/disciple, guardian/ward, captor/captive, a successor taking over from someone'),
    'trade': ('钱物', 'money', 'Money or goods pass between them: creditor/debtor, seller/buyer, partners in business, an agent, landlord/tenant'),
    'social': ('交往', 'social', 'They keep company: friends, acquaintances, neighbours, people of the same town, schoolmates, fellow disciples, colleagues, teammates, accomplices, allies'),
    'conflict': ('对立', 'conflict', 'They stand against each other: enemies, rivals, accuser and accused, one harming the other, opposite sides of a fight'),
    'grace': ('恩义', 'a debt of kindness', 'One owes the other for a great kindness: a rescuer, a benefactor who paid or sheltered them, a patron who raised them up'),
    'service': ('专业', 'professional', 'A professional service: doctor/patient, lawyer/client, priest/parishioner, craftsman/customer, teacher hired for a household'),
    'none': ('—', '—', 'This passage does not establish any tie between them (they merely appear in the same scene)'),
}
LEAVES = {
    'kin': {'parent': ('父母', 'parent'), 'child': ('子女', 'child'), 'sibling': ('兄弟姐妹', 'sibling'),
            'grandparent': ('祖辈', 'grandparent'), 'grandchild': ('孙辈', 'grandchild'),
            'uncle_aunt': ('叔伯姑舅姨', 'uncle or aunt'), 'nephew_niece': ('侄甥', 'nephew or niece'),
            'cousin': ('堂表亲', 'cousin'), 'adoptive_parent': ('养父母', 'adoptive parent'),
            'adopted_child': ('养子女', 'adopted child'), 'sworn_sibling': ('结拜兄弟姐妹', 'sworn brother or sister'),
            'godparent': ('教父母或干亲', 'godparent'), 'godchild': ('教子女或干子女', 'godchild'),
            'other_kin': ('其他血亲', 'other relative')},
    'marriage': {'spouse': ('配偶', 'spouse'), 'betrothed': ('未婚夫妻', 'betrothed'),
                 'concubine': ('妾室', 'concubine'), 'parent_in_law': ('岳父母公婆', 'parent-in-law'),
                 'child_in_law': ('女婿儿媳', 'child-in-law'), 'sibling_in_law': ('姑嫂妯娌连襟', 'sibling-in-law'),
                 'step': ('继亲', 'step-relation'), 'widowed': ('亡夫亡妻', 'late husband or wife'),
                 'divorced': ('前夫前妻', 'former husband or wife'), 'other_marriage': ('其他姻亲', 'other in-law')},
    'romance': {'lover': ('恋人', 'lover'), 'affair': ('私情', 'lover in secret'), 'suitor': ('追求者', 'suitor'),
                'courted': ('被追求者', 'the one courted'), 'unrequited': ('单恋', 'loves without return'),
                'past_love': ('旧情', 'former lover'), 'love_rival': ('情敌', 'rival in love')},
    'power': {'master': ('主人', 'master'), 'servant': ('仆人', 'servant'), 'employer': ('雇主', 'employer'),
              'employee': ('雇员', 'employee'), 'superior': ('上司', 'superior'), 'subordinate': ('下属', 'subordinate'),
              'teacher': ('师父', 'master or teacher'), 'pupil': ('徒弟', 'disciple or pupil'),
              'guardian': ('监护人', 'guardian'), 'ward': ('被监护者', 'ward'), 'captor': ('看押者', 'captor'),
              'captive': ('阶下囚', 'captive'), 'successor': ('继承人或接班人', 'successor'),
              'predecessor': ('前任', 'the one succeeded')},
    'trade': {'creditor': ('债主', 'creditor'), 'debtor': ('欠债人', 'debtor'), 'seller': ('卖主', 'seller'),
              'buyer': ('买主', 'buyer'), 'partner': ('合伙人', 'business partner'), 'agent': ('中间人', 'agent'),
              'landlord': ('房东或地主', 'landlord'), 'tenant': ('房客或佃户', 'tenant')},
    'social': {'friend': ('朋友', 'friend'), 'confidant': ('知己', 'confidant'), 'acquaintance': ('熟人', 'acquaintance'),
               'neighbour': ('邻居', 'neighbour'), 'townsman': ('同乡', 'from the same place'),
               'schoolmate': ('同窗', 'schoolmate'), 'fellow_disciple': ('同门师兄弟', 'fellow disciple'),
               'trade_fellow': ('同行', 'in the same trade'), 'colleague': ('同僚', 'colleague'),
               'teammate': ('搭档或队友', 'partner or teammate'), 'ally': ('盟友', 'ally'),
               'accomplice': ('同伙', 'accomplice')},
    'conflict': {'enemy': ('仇敌', 'enemy'), 'rival': ('对手', 'rival'), 'harmer': ('加害者', 'the one who harms'),
                 'harmed': ('受害者', 'the one harmed'), 'accuser': ('告发者', 'accuser'),
                 'accused': ('被告发者', 'accused'), 'opposing_side': ('敌对阵营', 'on the opposing side')},
    'grace': {'benefactor': ('恩人', 'benefactor'), 'beneficiary': ('受恩者', 'the one helped'),
              'saviour': ('救命恩人', 'the one who saved their life'), 'saved': ('被救者', 'the one saved'),
              'patron': ('提携者', 'patron'), 'protege': ('受提携者', 'protégé')},
    'service': {'doctor': ('医生', 'doctor'), 'patient': ('病人', 'patient'), 'lawyer': ('律师', 'lawyer'),
                'client': ('委托人', 'client'), 'priest': ('神职', 'clergyman'), 'parishioner': ('教众', 'parishioner'),
                'craftsman': ('匠人', 'craftsman'), 'customer': ('主顾', 'customer'),
                'tutor': ('西席或家教', 'private tutor'), 'employer_of_tutor': ('聘请者', 'the one who hired them')},
}
# every leaf's opposite, so A's side of the card follows from B's
INVERSE = {
    'accomplice': 'accomplice', 'accused': 'accuser', 'accuser': 'accused', 'acquaintance': 'acquaintance',
    'adopted_child': 'adoptive_parent', 'adoptive_parent': 'adopted_child', 'affair': 'affair', 'agent': 'agent',
    'ally': 'ally', 'benefactor': 'beneficiary', 'beneficiary': 'benefactor', 'betrothed': 'betrothed',
    'buyer': 'seller', 'captive': 'captor', 'captor': 'captive', 'child': 'parent', 'child_in_law': 'parent_in_law',
    'client': 'lawyer', 'colleague': 'colleague', 'concubine': 'spouse', 'confidant': 'confidant',
    'courted': 'suitor', 'cousin': 'cousin', 'craftsman': 'customer', 'creditor': 'debtor', 'customer': 'craftsman',
    'debtor': 'creditor', 'divorced': 'divorced', 'doctor': 'patient', 'employee': 'employer',
    'employer': 'employee', 'employer_of_tutor': 'tutor', 'enemy': 'enemy', 'fellow_disciple': 'fellow_disciple',
    'friend': 'friend', 'godchild': 'godparent', 'godparent': 'godchild', 'grandchild': 'grandparent',
    'grandparent': 'grandchild', 'guardian': 'ward', 'harmed': 'harmer', 'harmer': 'harmed', 'landlord': 'tenant',
    'lawyer': 'client', 'love_rival': 'love_rival', 'lover': 'lover', 'master': 'servant', 'neighbour': 'neighbour',
    'nephew_niece': 'uncle_aunt', 'opposing_side': 'opposing_side', 'other': 'other', 'other_kin': 'other_kin',
    'other_marriage': 'other_marriage', 'parent': 'child', 'parent_in_law': 'child_in_law', 'parishioner': 'priest',
    'partner': 'partner', 'past_love': 'past_love', 'patient': 'doctor', 'patron': 'protege',
    'predecessor': 'successor', 'priest': 'parishioner', 'protege': 'patron', 'pupil': 'teacher', 'rival': 'rival',
    'saved': 'saviour', 'saviour': 'saved', 'schoolmate': 'schoolmate', 'seller': 'buyer', 'servant': 'master',
    'sibling': 'sibling', 'sibling_in_law': 'sibling_in_law', 'spouse': 'spouse', 'step': 'step',
    'subordinate': 'superior', 'successor': 'predecessor', 'suitor': 'courted', 'superior': 'subordinate',
    'sworn_sibling': 'sworn_sibling', 'teacher': 'pupil', 'teammate': 'teammate', 'tenant': 'landlord',
    'townsman': 'townsman', 'trade_fellow': 'trade_fellow', 'tutor': 'employer_of_tutor',
    'uncle_aunt': 'nephew_niece', 'unrequited': 'courted', 'ward': 'guardian', 'widowed': 'widowed'
}
# Ideas relate to each other differently than people do; same two-level shape, same facets skipped.
CONCEPT_FAMILIES = {
    'hierarchy': ('层级', 'hierarchy', 'One is a kind of, or a part of, the other (a broader idea and a narrower one, a whole and a component)'),
    'causal': ('因果', 'cause', 'One brings about, requires, or prevents the other'),
    'contrast': ('对比', 'contrast', 'They are set against each other: opposites, competing accounts, or two things the book warns not to confuse'),
    'same_idea': ('同义', 'the same idea', 'Two names for the same idea: a synonym, an older term, a translation, an abbreviation'),
    'use': ('应用', 'use', 'One is used to do the other, or is an example, method, tool or measure of it'),
    'origin': ('出处', 'origin', 'A person, school or work that put the idea forward, or that the idea comes from'),
    'none': ('—', '—', 'This passage does not establish any link between them'),
}
CONCEPT_LEAVES = {
    'hierarchy': {'broader': ('上位概念', 'broader idea'), 'narrower': ('下位概念', 'narrower idea'),
                  'whole': ('所属整体', 'the whole'), 'part': ('组成部分', 'a part of it')},
    'causal': {'cause': ('起因', 'cause'), 'effect': ('结果', 'effect'), 'precondition': ('前提', 'precondition'),
               'enabled': ('由其成立', 'what it makes possible'), 'obstacle': ('阻碍', 'what stands in its way'),
               'obstructed': ('被其阻碍', 'what it blocks')},
    'contrast': {'opposite': ('对立面', 'opposite'), 'alternative': ('替代方案', 'alternative'),
                 'confused_with': ('易混淆', 'often confused with it'), 'criticises': ('批评者', 'criticises it'),
                 'criticised_by': ('被其批评', 'criticised by it')},
    'same_idea': {'synonym': ('同义说法', 'another name for it'), 'translation': ('原词或译名', 'the same term in another language'),
                  'abbreviation': ('简称', 'short form')},
    'use': {'applies_to': ('应用于', 'is applied to it'), 'applied_by': ('由其应用', 'applies it'),
            'example': ('例子', 'an example of it'), 'exemplified_by': ('举例说明', 'illustrated by it'),
            'method': ('方法或工具', 'a method or tool for it'), 'served_by': ('服务于', 'what the method serves'),
            'measure': ('度量', 'how it is measured'), 'measured_by': ('被其度量', 'what it measures')},
    'origin': {'proposer': ('提出者', 'the one who put it forward'), 'proposed': ('提出的概念', 'what they put forward'),
               'source_work': ('出处', 'the work it comes from'), 'contains_idea': ('书中概念', 'an idea from that work')},
}
CONCEPT_INVERSE = {'broader': 'narrower', 'narrower': 'broader', 'whole': 'part', 'part': 'whole',
                   'cause': 'effect', 'effect': 'cause', 'precondition': 'enabled', 'enabled': 'precondition',
                   'obstacle': 'obstructed', 'obstructed': 'obstacle', 'opposite': 'opposite',
                   'alternative': 'alternative', 'confused_with': 'confused_with', 'criticises': 'criticised_by',
                   'criticised_by': 'criticises', 'synonym': 'synonym', 'translation': 'translation',
                   'abbreviation': 'abbreviation', 'applies_to': 'applied_by', 'applied_by': 'applies_to',
                   'example': 'exemplified_by', 'exemplified_by': 'example', 'method': 'served_by',
                   'served_by': 'method', 'measure': 'measured_by', 'measured_by': 'measure',
                   'proposer': 'proposed', 'proposed': 'proposer', 'source_work': 'contains_idea',
                   'contains_idea': 'source_work', 'other': 'other'}
STATE = {'current': ('现在', 'current', 'It holds right now in this passage'),
         'former': ('已结束', 'no longer', 'It is over: the marriage ended, the service ended, the person left or died'),
         'secret': ('隐秘', 'kept secret', 'It is real but hidden from others in the story'),
         'claimed': ('据称', 'only claimed', 'Only someone in the passage says so — the passage does not confirm it')}
STANCE = {'close': ('亲近', 'close', 'Warm, trusting or affectionate in this passage'),
          'neutral': ('平常', 'neutral', 'Ordinary dealings, nothing marked'),
          'distant': ('疏远', 'distant', 'Cool, avoiding, or drifting apart'),
          'hostile': ('敌意', 'hostile', 'Angry, hostile or hurting each other'),
          'using': ('利用', 'using', 'One is using or exploiting the other'),
          'fearful': ('畏惧', 'in fear', 'One fears or is in awe of the other'),
          'dependent': ('依赖', 'dependent', 'One depends on or clings to the other')}


def label(key: str, lang: str) -> str:
    for table in list(LEAVES.values()) + list(CONCEPT_LEAVES.values()) + [STANCE, STATE]:
        if key in table:
            return table[key][0 if lang != 'en' else 1]
    return ''


def trees(kind: str = 'novel'):
    """Which relation tree to use: people in a story, or ideas in a book of ideas."""
    if kind == 'concept':
        return CONCEPT_FAMILIES, CONCEPT_LEAVES, CONCEPT_INVERSE
    return FAMILIES, LEAVES, INVERSE


def family_questions(pairs: list, names: dict, kind: str = 'novel', has_context: bool = False) -> dict:
    """First level of the relation tree, as questions that can ride along with another call."""
    fams = trees(kind)[0]
    what = 'what kind of link is there between' if kind == 'concept' else 'what kind of tie is there between'
    context_note = (' Use character_context, previous_passage_tail, and story_before_this_passage only to identify the people and understand their '
                    'already-known situation; the tie must still be established or actively continued in this_passage.' if has_context else '')
    return {f'f{n}': {'type': 'choice',
                      'instructions': f'In this_passage, {what} 「{names.get(a, a)}」 (A) and 「{names.get(b, b)}」 (B)?{context_note}',
                      'criteria': {k: v[2] for k, v in fams.items()}}
            for n, (a, b) in enumerate(pairs, 1)}


def read_families(ans: dict, pairs: list) -> dict:
    out = {}
    for n, pr in enumerate(pairs, 1):
        probs = (ans.get(f'f{n}') or {}).get('probabilities') or {}
        out[pr] = [(k, round(v, 3)) for k, v in sorted(probs.items(), key=lambda x: -x[1]) if k != 'none' and v >= 0.35][:2]
    return out


def _relation_state(passage: str, context: dict | None = None) -> dict:
    state = {'this_passage': bounded_passage(passage)}
    if isinstance(context, dict):
        for key in ('story_before_this_passage', 'previous_passage_tail', 'character_context'):
            if context.get(key):
                state[key] = context[key]
    return state


def check_and_families(passage: str, items: dict, pairs: list, names: dict, kind: str = 'novel',
                       context: dict | None = None) -> tuple[dict, dict]:
    """One call for two jobs that need the same passage: does the text support each record, and
    what kind of tie each pair has. The passage is the bulk of what the judge is billed for."""
    qs = record_questions(items)
    qs.update(family_questions(pairs, names, kind, bool(context)))
    ans = {}
    keys = list(qs)
    for k0 in range(0, len(keys), BATCH):
        ans.update(jev(_relation_state(passage, context), {k: qs[k] for k in keys[k0:k0 + BATCH]}))
    return read_records(ans, items), read_families(ans, pairs)


def relations_by_judge(passage: str, pairs: list, names: dict, fam: dict | None = None, kind: str = 'novel',
                       context: dict | None = None) -> dict:
    """Tie family → exact role → how they stand. Returns {(a, b): {'ties': [...], 'stance': (key, p)}}.

    A pair can come back with two ties (both families above 0.35): 主人 + 情人 is a real thing.
    'other' as the role means the tie is real but outside the tree — the caller asks a model to word it.
    """
    fams, leaves, _inv = trees(kind)
    if fam is None:
        fam = {}
        for k0 in range(0, len(pairs), BATCH):
            chunk = pairs[k0:k0 + BATCH]
            fam.update(read_families(jev(_relation_state(passage, context),
                                         family_questions(chunk, names, kind, bool(context))), chunk))
    jobs = [(pr, f, p) for pr, fs in fam.items() for f, p in fs]
    out: dict = {pr: {'ties': [], 'stance': None, 'state': None} for pr in pairs}
    for k0 in range(0, len(jobs), BATCH):
        chunk = jobs[k0:k0 + BATCH]
        qs = {}
        for n, ((a, b), f, _) in enumerate(chunk, 1):
            crit = {k: (f'B is {v[1]}' if kind == 'concept' else f"B is A's {v[1]}") for k, v in leaves[f].items()}
            crit['other'] = f'They have a {fams[f][1]} link, but none of these fits'
            qs[f'l{n}'] = {'type': 'choice',
                           'instructions': f'In this_passage, 「{names.get(b, b)}」 (B) and 「{names.get(a, a)}」 (A) have a '
                                           f'{fams[f][1]} link. What exactly is B to A?',
                           'criteria': crit}
        ans = jev(_relation_state(passage, context), qs)
        for n, (pr, f, fp) in enumerate(chunk, 1):
            x = ans.get(f'l{n}') or {}
            role = x.get('choice')
            p = round((x.get('probabilities') or {}).get(role, 0), 3)
            # both levels must hold up: a weak family with a confident leaf is still a guess
            if role and p >= 0.5 and fp * p >= 0.35:
                out[pr]['ties'].append({'family': f, 'role': role, 'p': p, 'family_p': fp})
    # both facets in one call: they are independent of each other and share the same passage.
    # Ideas have no stance, and a passing acquaintance does not need one either — the facets are
    # asked only where they carry meaning (family, marriage, love, authority, a debt of kindness).
    FACETED = {'kin', 'marriage', 'romance', 'power', 'grace', 'conflict'}
    live = [] if kind == 'concept' else [pr for pr, v in out.items()
                                         if any(t['family'] in FACETED for t in v['ties'])]
    for k0 in range(0, len(live), BATCH // 2):
        chunk = live[k0:k0 + BATCH // 2]
        qs = {}
        for n, (a, b) in enumerate(chunk, 1):
            qs[f's{n}'] = {'type': 'choice',
                           'instructions': f'In this_passage, how do 「{names.get(a, a)}」 and 「{names.get(b, b)}」 stand towards each other?',
                           'criteria': {k: v[2] for k, v in STANCE.items()}}
            qs[f't{n}'] = {'type': 'choice',
                           'instructions': f'In this_passage, does the tie between 「{names.get(a, a)}」 and 「{names.get(b, b)}」 still hold, and is it open?',
                           'criteria': {k: v[2] for k, v in STATE.items()}}
        # Missing state is not evidence of a current relationship. The caller
        # retains extraction and retries this verification stage on failure.
        ans = jev(_relation_state(passage, context), qs)
        for n, pr in enumerate(chunk, 1):
            for tag, table, key in (('s', STANCE, 'stance'), ('t', STATE, 'state')):
                x = ans.get(f'{tag}{n}') or {}
                p = round((x.get('probabilities') or {}).get(x.get('choice'), 0), 3)
                if x.get('choice') in table and p >= 0.5:
                    out[pr][key] = (x['choice'], p)
    return {pr: v for pr, v in out.items() if v['ties']}


def record_questions(items: dict) -> dict:
    qs = {}
    for k, (kind, claim) in items.items():
        what = {'event': 'this event happens in this_passage',
                'attr': 'this_passage says this about the character',
                'rel': 'this_passage establishes this relationship'}[kind]
        qs[f'v_{k}'] = {'type': 'choice',
                        'instructions': f'Judging only this_passage: {what}? CLAIM: {claim}',
                        'criteria': {
                            'supported': 'The passage states it, shows it happening, or clearly implies it.',
                            'not_in_passage': 'The passage does not establish this — it may be outside knowledge, a guess, or about someone else.',
                            'contradicted': 'The passage says otherwise.'}}
    return qs


def read_records(ans: dict, items: dict) -> dict:
    out = {}
    for k in items:
        a = ans.get(f'v_{k}') or {}
        probs = a.get('probabilities') or {}
        out[k] = {'p': round(probs.get('supported', 0), 3), 'choice': a.get('choice'),
                  'probs': {x: round(v, 3) for x, v in probs.items()}}
    return out


def verify_records(passage: str, items: dict[str, tuple[str, str]]) -> dict[str, dict]:
    """Every record a segment produced, checked against that segment's own text.

    items: {key: (kind, claim)} where kind is 'event' | 'attr' | 'rel'. Names in the claim must be
    the ones this passage uses, so the judge never has to work out who is meant.
    """
    qs = record_questions(items)
    keys = list(qs)
    ans = {}
    for k0 in range(0, len(keys), BATCH):
        ans.update(jev({'this_passage': bounded_passage(passage)}, {k: qs[k] for k in keys[k0:k0 + BATCH]}))
    return read_records(ans, items)


IMPORTANCE = {
    'main': (3, 'A main one: the story (or the argument) is largely about them; a reader must keep track of them.'),
    'supporting': (2, 'Worth remembering: they come back, act on the plot, or the argument leans on them.'),
    'walk_on': (1, 'A passer-by: appears once or twice for scenery, a servant who opens a door, a name in an example.'),
}


def importance(dossiers: dict, concept: bool = False) -> dict:
    """How much each person (or idea) matters so far, judged from what is known at this point.

    Counting mentions gets this wrong in both directions: a web novel repeats a guild name hundreds
    of times, a textbook mentions its central idea once per chapter. Returns {id: 1|2|3}.
    """
    out = {}
    keys = list(dossiers)
    what = 'idea or term' if concept else 'character'
    for k0 in range(0, len(keys), BATCH):
        chunk = keys[k0:k0 + BATCH]
        qs = {f'i{n}': {'type': 'choice',
                        'instructions': f'In the book so far, how much does this {what} matter?\n{dossiers[k]}',
                        'criteria': {name: text for name, (_v, text) in IMPORTANCE.items()}}
              for n, k in enumerate(chunk, 1)}
        try:
            ans = jev({'note': f'Judge only from what is given about each {what}.'}, qs)
        except Exception:
            break
        for n, k in enumerate(chunk, 1):
            a = ans.get(f'i{n}') or {}
            if a.get('choice') in IMPORTANCE:
                out[k] = IMPORTANCE[a['choice']][0]
    return out


def current_value(items: dict) -> dict:
    """Which of several recorded values for one attribute still holds.

    items: {key: (who, attribute, [values oldest→newest])}. Returns {key: chosen value}.
    A later record is usually the current one, but not always: books restate old facts, and a
    stronger statement can come before a passing mention.
    """
    out = {}
    keys = list(items)
    for k0 in range(0, len(keys), BATCH):
        chunk = keys[k0:k0 + BATCH]
        qs = {}
        for n, k in enumerate(chunk, 1):
            who, attr, values = items[k]
            crit = {f'v{i}': v for i, v in enumerate(values)}
            crit['both'] = 'Both still hold — they are not in conflict.'
            qs[f'c{n}'] = {'type': 'choice',
                           'instructions': (f'The book has said these things about 「{who}」 — {attr} — in this order '
                                            f'(earliest first). Which one describes the situation as it stands now?'),
                           'criteria': crit}
        try:
            ans = jev({'note': 'Judge only from the statements given.'}, qs)
        except Exception:
            break
        for n, k in enumerate(chunk, 1):
            a = ans.get(f'c{n}') or {}
            choice = a.get('choice')
            p = (a.get('probabilities') or {}).get(choice, 0)
            if choice and choice.startswith('v') and p >= 0.6:
                out[k] = items[k][2][int(choice[1:])]
    return out


def title_spoilers(titles: list[str], book_title: str = '') -> list[bool]:
    """Which chapter titles give away what happens in that chapter.

    Judged from the title alone — enough to tell "苦绛珠魂归离恨天" (someone dies) from
    "葫芦僧乱判葫芦案" (just names the scene), so the rest of the table of contents stays readable.
    """
    out = [True] * len(titles)
    for k0 in range(0, len(titles), BATCH):
        chunk = list(range(k0, min(k0 + BATCH, len(titles))))
        qs = {f't{i}': {
            'type': 'choice',
            'instructions': f'A chapter of the novel 《{book_title}》 is called 「{titles[i]}」. The reader has not read '
                            'this chapter yet. Does the title itself give away what happens in it?',
            'criteria': {
                'spoils': 'Yes — it states an outcome: someone dies or is killed, a marriage or birth happens, a secret '
                          'or true identity is revealed, someone wins, loses, is caught, betrayed or rescued.',
                'safe': 'No — it only names a place, a person, an object, a scene or a vague hint, or is just a number.',
            }} for i in chunk}
        try:
            ans = jev({'note': 'Judge only the title text.'}, qs)
        except Exception:
            continue
        for i in chunk:
            probs = (ans.get(f't{i}') or {}).get('probabilities') or {}
            out[i] = probs.get('spoils', 1) >= 0.5
    return out


CRITICAL = re.compile(r'死|去世|身亡|亡故|病故|病逝|殁|薨|夭|自尽|自刎|投井|上吊|吞金|咽气|气绝|过世|归天|殒|丧命|遇害|被杀|'
                      r'娶|嫁|成亲|成婚|完婚|拜堂|过门|纳妾|二房|订婚|定亲|婚配|'
                      # who did it: a suspicion must not become a fact (DeepSeek on Great Expectations:
                      # "identified by his hammer as the attacker", 36 chapters before the confession)
                      r'凶手|元凶|主谋|幕后|行凶|刺杀|暗杀|下毒|毒杀|陷害|嫁祸|'
                      r'\b(?:attacker|assailant|culprit|murderer|killer|poisoner|poisoned|framed|behind the attack)\b|'
                      r'\b(?:die[sd]?|dying|dead|death|killed|murder(?:ed)?|drown(?:s|ed)|suicide|hanged|executed|perish(?:ed|es)|'
                      r'marr(?:y|ies|ied)|wedding|wed|widow(?:ed)?|engaged|betrothed)\b', re.I)


def check_critical(passage: str, items: dict[str, str]) -> dict[str, dict]:
    """Deaths and marriages must be narrated as having happened, not rumoured or foreseen.

    items: {key: statement}. Returns {key: {'fact': p, 'choice': ...}}."""
    out = {}
    keys = list(items)
    for k0 in range(0, len(keys), BATCH):
        chunk = keys[k0:k0 + BATCH]
        qs = {}
        for n, k in enumerate(chunk, 1):
            qs[f'c{n}'] = {
                'type': 'choice',
                'instructions': ('Statement about a Chinese novel: 「' + items[k] + '」. According to this_passage only, '
                                 'how is this presented?'),
                'criteria': {
                    'fact': 'The passage narrates it as something that actually happened / is actually the case in the story.',
                    'not_real': 'Only a rumour, misreport, suspicion, fear, dream, vision, prophecy, joke, curse, threat, plan, proposal or wish — the passage does not establish that it actually happened.',
                    'unsupported': 'The passage does not say this at all, or says the opposite.',
                },
            }
        ans = jev({'this_passage': passage}, qs)
        for n, k in enumerate(chunk, 1):
            a = ans.get(f'c{n}') or {}
            probs = a.get('probabilities') or {}
            out[k] = {'fact': round(probs.get('fact', 0), 3), 'choice': a.get('choice'),
                      'probs': {x: round(v, 3) for x, v in probs.items()}}
    return out


def same_question(a: str, b: str, da: str = '', db: str = '') -> str:
    """What the reader already knows about each name goes into the question, so a passage that merely
    fails to introduce someone (伊韦尔, known as the coach driver) cannot make him the blind beggar."""
    ka = f'（known so far as: {da}）' if da else ''
    kb = f'（known so far as: {db}）' if db else ''
    return f'In this_passage, are 「{a}」{ka} and 「{b}」{kb} the same person?'


def check_same(passage: str, pairs: dict[str, tuple]) -> dict[str, dict]:
    """"A 就是 B": does the passage itself establish that the two names are one person?
    pairs: key → (a, b) or (a, b, what is known about a, what is known about b)."""
    qs = {}
    for n, (k, pr) in enumerate(pairs.items(), 1):
        qs[f's{n}'] = {
            'type': 'choice',
            'instructions': same_question(*pr),
            'criteria': {
                'same': 'The passage makes clear these two names refer to one and the same person.',
                'different': 'They are different people (e.g. relatives, sisters, master and servant, two people with similar titles).',
                'unclear': 'The passage does not establish it.',
            },
        }
    if not qs:
        return {}
    ans = jev({'this_passage': passage}, qs)
    out = {}
    for n, k in enumerate(pairs, 1):
        a = ans.get(f's{n}') or {}
        probs = a.get('probabilities') or {}
        out[k] = {'same': round(probs.get('same', 0), 3), 'choice': a.get('choice'),
                  'probs': {x: round(v, 3) for x, v in probs.items()}}
    return out


ROUTES = {
    'who': 'Asks who a character is, what they are like, or their current situation.',
    'relation': 'Asks about the relationship between characters.',
    'recap': 'Asks what has happened so far, or to summarise/recall earlier plot.',
    'why': 'Asks why something happened or what a passage/behaviour means (interpretation of what has been read).',
    'future': 'Asks what WILL happen later, how the story ends, or anything that can only be answered from unread pages.',
    'other': 'Anything else (vocabulary, background knowledge, chit-chat).',
}


def route_question(question: str, context_hint: str = '') -> tuple[str, dict]:
    ans = jev({'question': question, 'reader_position': context_hint or 'middle of the novel'},
              {'route': {'type': 'choice',
                         'instructions': 'Classify the reader question about the novel they are currently reading.',
                         'criteria': ROUTES}})
    a = ans.get('route') or {}
    return a.get('choice') or 'other', a.get('probabilities') or {}
