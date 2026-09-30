"""Process one book: sequential extraction → Jev decisions → temporal KG, resumable.

Layout under data/books/<id>/:
  book.json            parsed text (pipeline.parse)
  work/segs/NNNN.json  per-segment model output + Jev decisions (the replayable source of truth)
  work/recaps/CCCC.json chapter recap + story-so-far
  kg.json              compiled event log (served to readers, sliced by position)
  mentions/CCCC.json   name highlights per chapter
  status.json          progress for the UI

Usage: python -m pipeline.run data/books/<id> [--model deepseek-flash+nothink] [--limit N]
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import math
import threading
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
import json
import os
import re
import sys
import time
import traceback
from pathlib import Path

from .classify import classify_chapters
from .extract import build_messages, extract_segment, segments, seg_text
from .judge import (BATCH, CRITICAL, check_and_families, current_value, importance, check_critical, check_facts, check_same, guard_texts,
                     label, record_questions, relations_by_judge, resolve_mentions, title_spoilers, trees, verify_records)
from .kg import KG, zh, quarantine_identities
from .kind import works as kind_works, detect as detect_kind
from .lang import LIFE_KEYS, card_lang, out_note, scale
from .link import core, is_generic, link_segment, related

STOPWORDS = set('that with this from have were been they their them what when where which would could should about into than then there these those will your said says like just very only also some more most much such upon over under after before while being does did'.split())
from .local import LOCAL_MODEL, extract_local, sanitize
from .llm import JEV_STATS, chat, chat_json, explain, jev, LLMError
from .provenance import SCHEMA, digest, source_fingerprint

# cheap by default: reading a book must not be expensive
DEFAULT_MODEL = os.environ.get('EXTRACT_MODEL', 'deepseek-flash+nothink')
RECAP_MODEL = os.environ.get('RECAP_MODEL', 'deepseek-flash+nothink')
EXTRACTOR_REVISION = hashlib.sha256(Path(__file__).with_name('local.py').read_bytes()).hexdigest()
RELATION_JUDGE_REVISION = 2  # v2 adds captured biographies, story state and immediate prior text


class Cancelled(Exception):
    """The in-process worker asked to stop at a durable segment boundary."""


class AlreadyRunning(Exception):
    """A book's pipeline lock is held by another runner."""


def wjson(path: Path, data, compact=True):
    path.parent.mkdir(parents=True, exist_ok=True)
    # unique temp name: background biography threads publish too (a shared name raced once)
    tmp = path.with_suffix(f'{path.suffix}.{os.getpid()}.{threading.get_ident()}.tmp')
    tmp.write_text(json.dumps(data, ensure_ascii=False, separators=(',', ':') if compact else None,
                              indent=None if compact else 1))
    tmp.replace(path)


def log(msg: str):
    print(time.strftime('%H:%M:%S'), msg, flush=True)


REWRITE = """下面这份人物简介由 AI 生成，自动校验认为它可能包含【原文】和【旧简介】都没有交代的内容（可能是编造，也可能是后文才揭示的剧透）。
请逐句核对，只保留能从【原文】或【旧简介】直接得到支持的内容，重写这份简介。不要补充任何原文之外的信息。

【旧简介】{old}

【原文】
{text}

【待核对的简介】
一句话身份：{tagline}
简介：{bio}

只输出 JSON：{{"tagline": "≤18字", "bio": "60～160字"}}"""

CHAPTER_RECAP = """你在为一款防剧透阅读器写章节梗概。读者刚读完《{title}》的「{chapter}」。
只能使用下面给出的本章事件，绝不能写入任何后文情节，即使你知道这部作品。

【本章发生的事】（按顺序）
{events}

写本章梗概：80～200 字，按情节顺序，具体到人名。只输出梗概正文。"""

SAGA = """你在为一款防剧透阅读器更新“前情提要”。读者已读到《{title}》的「{chapter}」结束。
只能使用下面的材料，绝不能写入任何后文情节，即使你知道这部作品。

【此前的前情提要】
{saga}

【之后各章梗概】
{recaps}

写截至目前的全书前情提要：300～700 字，融合此前提要与新的各章梗概，详略得当，越近的情节写得越具体。只输出提要正文。"""

RECAP = """你在为一款防剧透阅读器写“前情提要”。读者刚读完《{title}》的「{chapter}」。
只能使用下面给出的信息，绝不能写入任何后文情节，即使你知道这部作品。

【此前的前情提要】
{saga}

【本章发生的事】（按顺序）
{events}

【本章人物动态】
{profiles}

按下面的格式输出，不要其他内容：
<recap>本章梗概，80～200字，按情节顺序，具体到人名</recap>
<saga>截至本章结束的全书前情提要，200～600字，融合此前提要与本章，详略得当，越近的情节写得越具体</saga>"""


RELATION_WORDS = """下面是《{title}》的一段原文，以及其中几对同时出场的人物。自动判断认为他们之间**有关系但不属于常见类别**（亲属、婚恋、主仆、师生、朋友、敌对、生意往来都不是）。
请只根据这段原文，写出每一对的关系；本段看不出关系的，b_is 留空。

【本段原文】
{text}

【人物对】
{pairs}

只输出 JSON：{{"1": {{"b_is": "B 对 A 而言是什么（≤8字）", "a_is": "A 对 B 而言是什么（≤8字）", "desc": "≤20字说明", "quote": "本段原文里逐字出现的一句支持它的片段"}}}}"""


CONSOLIDATE = """你在为一款防剧透阅读器编写“人物表”。读者刚读完《{title}》的「{chapter}」。
只能使用下面给出的资料，绝不能写入任何后文情节，即使你知道这部作品。

为每个人物写：
- tagline：一句话身份（≤18字），说清他是谁、现在处于什么位置；
- bio：100～160字的人物小传，写法像书前的人物表：
  第一句交代他是谁（身份、与主要人物的关系）；接着一句概括性格；然后按时间顺序概括至今的人生轨迹，只挑真正改变他处境或关系的大事，每件事一句话；最后一句写目前处境。
要求：用概括性的语言，不要场景细节和琐事（吃什么、穿什么、某个动作）；年龄、身份、住处等用最新的信息；不评价、不预测，不写资料里没有的内容。

{dossiers}

只输出 JSON：{{"P1": {{"tagline": "...", "bio": "..."}}, ...}}"""


def settle_rewrites(rec: dict) -> None:
    """Keep a JEV-triggered rewrite only if JEV judges it clearly better than the original.

    JEV can flag a correct description (false positive) and the LLM rewrite can then make it
    worse; comparing both scores keeps whichever version the evidence supports."""
    guard = rec.get('guard') or {}
    for who, c in (guard.get('checks') or {}).items():
        if c.get('verdict') != 'rewritten':
            continue
        if c.get('verified') and c.get('after_verdict') == 'ok':
            continue
        before, after = c.get('first') or 0, c.get('jev') or 0
        if after >= max(0.5, before + 0.2):
            continue
        orig = (guard.get('rewrites') or {}).get(who, {}).get('before') or {}
        for pr in rec['data'].get('profiles', []):
            if str(pr.get('who')) == who and orig:
                pr['tagline'] = orig.get('tagline') or pr.get('tagline')
                pr['bio'] = orig.get('bio') or pr.get('bio')
        c['verdict'] = 'kept'
    # Attribute checks (guard.attrs) are recorded for inspection only. Evaluated on Bovary they
    # removed correct facts (a shared title like 包法利夫人 confuses the judge) and missed the one
    # real prior-knowledge leak, so they must not delete anything.


def drop_unsupported(data: dict, support: dict, thr: float = 0.3) -> tuple[dict, list]:
    """Remove records the segment's own text does not support (see Runner.add_support)."""
    if not support:
        return data, []
    keep = {'events': [], 'facts': [], 'rels': []}
    dropped = []
    for field, prefix in (('events', 'e'), ('facts', 'a'), ('rels', 'r')):
        for j, x in enumerate(data.get(field) or []):
            v = support.get(f'{prefix}{j}')
            if v and (v['p'] < thr or (v.get('choice') == 'contradicted' and v['p'] < 0.5)):
                dropped.append([f'{prefix}{j}', v['p'], v.get('choice')])
            else:
                keep[field].append(x)
    return dict(data, **keep), dropped


def attr_facts(data: dict, who_of) -> dict:
    """{index: (name, who they are, attribute, value)} for the segment's attribute records."""
    out = {}
    for i, a in enumerate(data.get('attrs', [])):
        if a.get('key') and a.get('value'):
            name, desc = who_of(a.get('who'))
            out[str(i)] = (name, desc, a['key'], a['value'])
    return out


def check_attrs(text: str, data: dict, who_of) -> dict:
    return check_facts(text, attr_facts(data, who_of))


class Runner:
    def __init__(self, root: Path, model: str = DEFAULT_MODEL, cancel_event=None):
        self.root = root
        self.model = model
        self.cancel_event = cancel_event
        self.book = json.loads((root / 'book.json').read_text())
        legacy_cache = (root / 'work/segs').exists()
        if (not self.book.get('genre') and not legacy_cache) or self.book.get('genre_provisional'):
            genre, confidence = detect_kind(self.book)
            if confidence > 0:
                self.book.update(genre=genre, genre_p=confidence, genre_provisional=False)
                wjson(root / 'book.json', self.book)
            elif os.environ.get('DETECT_KIND', '1') == '1':
                raise LLMError('书籍类型尚未确认，请稍后重试或手动选择类型')
        if not self.book.get('classified'):
            kinds = classify_chapters(self.book)
            for c, k in zip(self.book['chapters'], kinds):
                c['kind'] = k
            self.book['classified'] = True
            wjson(root / 'book.json', self.book)
        body = [i for i, c in enumerate(self.book['chapters']) if c['kind'] == 'body']
        self.segs = segments(self.book, body)
        if not self.segs:
            raise ValueError('未找到正文段落；请检查解析和章节分类，不能将 0/0 标记为完成')
        if any(len(seg_text(self.book, seg)) > 12000 for seg in self.segs):
            raise ValueError('正文含超过核对上限的长段落；请先拆分段落，避免截断证据')
        self.kg = KG(self.book)
        self.work = root / 'work'
        self.replaying = False
        self.deferred = []
        prior_status = json.loads((root / 'status.json').read_text()) if (root / 'status.json').exists() else {}
        self.quality_pending = set((prior_status.get('quality') or {}).get('pending') or [])
        self.refused = set(prior_status.get('refused') or [])
        self.input_sha256 = source_fingerprint(self.book, self.segs)
        manifest = self.work / 'cache-manifest.json'
        if manifest.exists() and json.loads(manifest.read_text()).get('input_sha256') != self.input_sha256:
            raise ValueError('书籍或分段已变更，旧缓存不能混用；请先执行分离的数据修复')
        if not manifest.exists():
            wjson(manifest, {'schema': SCHEMA, 'input_sha256': self.input_sha256,
                             'legacy_adopted': (self.work / 'segs').exists()})
        prior_path = root / 'kg.json'
        self.prior_log = json.loads(prior_path.read_text()).get('log', []) if prior_path.exists() else []
        policy_path = self.work / 'repair-policy.json'
        self.repair_policy = json.loads(policy_path.read_text()) if policy_path.exists() else {}
        if self.repair_policy.get('input_sha256') not in (None, self.input_sha256):
            raise LLMError('修复隔离策略与书籍来源不符')
        self.quality_pending.update(self.repair_policy.get('pending', []))
        self.restore_quality_retry_context()
        os.environ.setdefault('JUDGE_LOG_DIR', str(self.work / 'judge'))
        self.usage_path = self.work / 'usage.json'
        self.usage = json.loads(self.usage_path.read_text()) if self.usage_path.exists() else {}
        self.status_lock = threading.Lock()
        for k in ('prompt', 'completion', 'jev_calls', 'llm_calls'):
            self.usage.setdefault(k, 0)
        self.usage.setdefault('by_model', {})
        self.lock = threading.RLock()          # kg.log is also extended by background biography jobs
        self.publish_lock = threading.Lock()
        self.pool = ThreadPoolExecutor(4)
        self.recap_pool = ThreadPoolExecutor(4)   # chapter recaps are independent
        self.saga_pool = ThreadPoolExecutor(1)    # the story-so-far chain must stay in order
        self.two_phase = False
        self.last_saga = self.segs[0]['o0'] if self.segs else 0
        self.recap_futures: dict[int, object] = {}
        self.pending = []
        self.last_bio = self.segs[0]['o0'] if self.segs else 0
        self.dedupe_seen: set[tuple] = set()
        # a collection is several books in one file: each work keeps its own cast
        self.works = kind_works(self.book) if self.book.get('genre') == 'collection' else []
        self.desc_pairs: set[tuple] = set()

    def checkpoint(self):
        if self.cancel_event is not None and self.cancel_event.is_set():
            raise Cancelled()

    def await_future(self, future):
        if self.cancel_event is None:
            return future.result()
        while True:
            self.checkpoint()
            try:
                return future.result(timeout=.5)
            except FutureTimeout:
                continue

    def close(self, cancelled=False):
        for pool in (getattr(self, 'local_pool', None), self.pool, self.recap_pool, self.saga_pool):
            if pool is not None:
                pool.shutdown(wait=True, cancel_futures=cancelled)

    # ------------------------------------------------------------ helpers
    def seg_path(self, i: int) -> Path:
        return self.work / 'segs' / f'{i:04d}.json'

    def recap_path(self, ci: int) -> Path:
        return self.work / 'recaps' / f'{ci:04d}.json'

    def bio_path(self, ci: int) -> Path:
        return self.work / 'bios' / f'{ci:04d}.json'

    def chapter_name(self, ci: int) -> str:
        c = self.book['chapters'][ci]
        return (c['parent'] + ' · ' if c.get('parent') else '') + c['title']

    def count(self, model: str, usage: dict | None):
        """Accumulate model usage across runs (persisted), per model."""
        u = usage or {}
        m = self.usage['by_model'].setdefault(model, {'calls': 0, 'prompt': 0, 'completion': 0})
        m['calls'] += 1
        m['prompt'] += u.get('prompt_tokens') or 0
        m['completion'] += u.get('completion_tokens') or 0
        self.usage['llm_calls'] += 1
        self.usage['prompt'] += u.get('prompt_tokens') or 0
        self.usage['completion'] += u.get('completion_tokens') or 0
        wjson(self.usage_path, self.usage, compact=False)

    def cached_generation(self, key, model, messages, *, json_output=False, **kw):
        """Persist a successful draft before verification; retry checks, not generation."""
        fingerprint = digest([model, messages, json_output, kw])
        path = self.work / 'drafts' / f'{key}-{fingerprint}.json'
        if path.exists():
            return json.loads(path.read_text())['value']
        fn = chat_json if json_output else chat
        value, usage = fn(model, messages, **kw)
        with self.lock:
            self.count(model, usage)
        wjson(path, {'input_sha256': fingerprint, 'value': value})
        return value

    def queue_final(self, kind, key, args, pool):
        """Keep retryable finalization obligations and the exact captured inputs."""
        path = self.work / 'jobs' / f'{kind}-{key}.json'
        job = {'kind': kind, 'key': key, 'args': args, 'state': 'pending'}
        if path.exists():
            saved = json.loads(path.read_text())
            if saved.get('state') != 'complete':
                job = saved  # retry the original captured context
        wjson(path, job)
        self.quality_pending.add(path.stem)
        if getattr(self, 'replaying', False):
            self.deferred.append((path, pool))
            return None
        future = pool.submit(self.execute_final, path)
        self.pending.append(future)
        return future

    def execute_final(self, path):
        job = json.loads(path.read_text())
        methods = {'bio': self._bio_job, 'recap': self._chapter_recap_job,
                   'classic-recap': self._recap_job, 'saga': self._saga_job}
        try:
            result = methods[job['kind']](*job['args'])
            if result is False:
                raise LLMError('章节整理尚未通过验证')
        except Exception as e:
            job.update(state='failed', error=f'{type(e).__name__}: {e}'[:300])
            wjson(path, job)
            self.quality_pending.add(path.stem)
            raise
        job.update(state='complete')
        job.pop('error', None)
        wjson(path, job)
        self.quality_pending.discard(path.stem)
        if job['kind'] == 'bio':
            prefix = f"bio-unverified-{job['args'][1]}-"
            self.quality_pending.difference_update(k for k in list(self.quality_pending) if k.startswith(prefix))
        return result

    def acknowledge_final_cache(self, kind, key):
        """Finish the output-written/job-not-acknowledged crash window offline."""
        path = self.work / 'jobs' / f'{kind}-{key}.json'
        if path.exists():
            job = json.loads(path.read_text())
            if job.get('state') != 'complete':
                job.update(state='complete')
                job.pop('error', None)
                wjson(path, job)
        self.quality_pending.discard(path.stem)

    def resume_final_jobs(self):
        for path, pool in self.deferred:
            job = json.loads(path.read_text())
            future = pool.submit(self.execute_final, path)
            self.pending.append(future)
            if job['kind'] == 'recap':
                self.recap_futures[int(job['key'])] = future
        self.deferred = []

    def earlier_saga(self, end_pos, fallback=''):
        with self.lock:
            before = max((r for r in self.kg.log if r.get('t') == 'saga' and r['p'] < end_pos),
                         key=lambda r: r['p'], default=None)
        return before['text'] if before else fallback

    @staticmethod
    def verified_summary(record, *fields):
        return not record.get('guard_error') and all(
            not record.get(field) or record.get('guard', {}).get(field, {}).get('verdict') == 'ok'
            or (record.get('guard', {}).get(field, {}).get('verdict') == 'flag'
                and isinstance(record.get(field + '_flagged'), str)
                and record.get(field + '_flagged') != record.get(field)
                and record.get('fallback_kind') == 'verified-input-excerpt')
            for field in fields)

    def quarantined(self, path):
        return path.relative_to(self.root).as_posix() in getattr(self, 'repair_policy', {}).get('blocked', [])

    def restore_quality_retry_context(self):
        journal = self.work / 'quality-retry.json'
        saved = json.loads(journal.read_text()) if journal.exists() else {}
        if saved.get('state') != 'rebuilding':
            return
        if saved.get('input_sha256') != self.input_sha256:
            raise LLMError('质量重试来源已变更，已保留归档，请先检查')
        first = saved['first_segment']
        cutoff = self.segs[first]['o0'] if first < len(self.segs) else float('inf')
        self.prior_log = [r for r in self.prior_log if r.get('t') == 'merge'
                          and r.get('kind') == 'dedupe' and r.get('p', 0) < cutoff]

    def prepare_quality_retry(self):
        """Explicitly rebuild quarantined output, archiving derived inputs first.

        Called under main's per-book lock. Extraction and teacher captures remain
        byte-for-byte intact. A small journal resumes an interrupted archive
        without creating a second attempt or discarding its originals.
        """
        journal = self.work / 'quality-retry.json'
        saved = json.loads(journal.read_text()) if journal.exists() else {}
        if saved.get('state') == 'rebuilding':
            self.restore_quality_retry_context()
            return
        if saved.get('state') == 'archiving':
            transaction = saved
        else:
            start = self.repair_policy.get('quarantine_after')
            if start is None and 'quarantined-critical-checks' in self.quality_pending:
                start = 0
            first = next((i for i, seg in enumerate(self.segs) if start is not None and seg['o1'] >= start), len(self.segs))
            candidates = []
            for directory in ('bios', 'recaps', 'sagas', 'jobs', 'finalize', 'drafts'):
                candidates.extend((self.work / directory).glob('*.json'))
            candidates.extend(self.seg_path(i) for i in range(first, len(self.segs)) if self.seg_path(i).exists())
            candidates.extend(path for path in (self.work / 'dedupe').glob('*.json')
                              if any(s['chapter'] == int(path.stem) for s in self.segs[first:]))
            archive = self.work / 'retry-archive' / f'{time.time_ns()}-{os.getpid()}'
            rows = []
            for path in sorted(set(candidates)):
                relative = path.relative_to(self.root).as_posix()
                rows.append({'path': relative, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
            transaction = {'state': 'archiving', 'archive': archive.relative_to(self.root).as_posix(),
                           'first_segment': first, 'files': rows, 'input_sha256': self.input_sha256}
            for path in (self.root / 'kg.json', self.root / 'status.json', self.work / 'repair-policy.json'):
                if path.exists():
                    target = archive / 'snapshot' / path.relative_to(self.root)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(path.read_bytes())
            wjson(journal, transaction)
        if transaction['input_sha256'] != self.input_sha256:
            raise LLMError('质量重试来源已变更，已保留归档，请先检查')
        archive = self.root / transaction['archive']
        for row in transaction['files']:
            original, target = self.root / row['path'], archive / row['path']
            for path in (original, target):
                if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() != row['sha256']:
                    raise LLMError('质量重试文件在归档期间变更：' + row['path'])
            if target.exists():
                original.unlink(missing_ok=True)
            elif original.exists():
                target.parent.mkdir(parents=True, exist_ok=True)
                original.replace(target)
            else:
                raise LLMError('质量重试原件及归档均缺失：' + row['path'])
        self.quality_pending = {'quality-rebuild'} | (self.quality_pending & {'chapter-titles'})
        self.repair_policy = {'schema': SCHEMA, 'input_sha256': self.input_sha256,
                              'blocked': [], 'pending': sorted(self.quality_pending)}
        wjson(self.work / 'repair-policy.json', self.repair_policy)
        # Keep only earlier identity decisions. Every derived claim is rebuilt
        # from captured chronological inputs, never copied from the old graph.
        first = transaction['first_segment']
        cutoff = self.segs[first]['o0'] if first < len(self.segs) else float('inf')
        self.prior_log = [r for r in self.prior_log if r.get('t') == 'merge'
                          and r.get('kind') == 'dedupe' and r.get('p', 0) < cutoff]
        transaction['state'] = 'rebuilding'
        wjson(journal, transaction)

    def finish_quality_retry(self):
        if 'quality-rebuild' not in self.quality_pending:
            return
        self.quality_pending.discard('quality-rebuild')
        self.repair_policy['pending'] = sorted(self.quality_pending)
        wjson(self.work / 'repair-policy.json', self.repair_policy)
        journal = self.work / 'quality-retry.json'
        if journal.exists():
            transaction = json.loads(journal.read_text())
            transaction['state'] = 'complete'
            wjson(journal, transaction)

    def notify(self, notice: str | None):
        """Tell the reader why the job is waiting (a retry after a failed model call) without
        waiting for the segment to finish; cleared by the next regular status write."""
        path = self.root / 'status.json'
        with self.status_lock:
            try:
                state = json.loads(path.read_text())
            except (OSError, ValueError):
                return
            state.update(notice=notice, updated=time.time())
            wjson(path, state, compact=False)

    def status(self, state: str, done: int, error: str | None = None):
        seg = self.segs[done - 1] if done else None
        with self.lock, self.status_lock:
            self.usage['jev'] = dict(JEV_STATS)  # judge calls and payload in this process
            self._status(state, done, seg, error)

    def _status(self, state, done, seg, error):
        # A guard can finish after the last model call persisted its usage.
        # Flush the same snapshot at every progress boundary, including a partial run.
        usage = copy.deepcopy(self.usage)
        wjson(self.usage_path, usage, compact=False)
        wjson(self.root / 'status.json', {
            'state': state, 'done': done, 'total': len(self.segs),
            'frontier': seg['o1'] if seg else 0,
            'body_start': self.segs[0]['o0'] if self.segs else 0,
            'body_end': self.segs[-1]['o1'] if self.segs else 0,
            'model': self.model, 'people': sum(1 for p in self.kg.people.values() if not p.get('merged_into')),
            'updated': time.time(), 'error': error, 'usage': usage,
            'refused': sorted(getattr(self, 'refused', set())),
            'quality': {'state': 'pending' if getattr(self, 'quality_pending', set()) else 'verified',
                        'pending': sorted(getattr(self, 'quality_pending', set()))},
        }, compact=False)

    def publish(self):
        with self.lock, self.publish_lock:
            self._publish()

    def _publish(self):
        rows, mentions, _, _, _ = quarantine_identities(self.kg.log, self.kg.mentions,
                                                       self.repair_policy.get('identity_taint', {}))
        ordered = []
        for index, row in enumerate(rows):
            kind = row['t']
            if kind == 'profile' and row.get('kind') == 'chapter':
                phase = 1
            elif kind == 'recap':
                phase = 2
            elif kind == 'saga':
                phase = 3
            else:
                phase = 0
            # Extraction records keep their same-position causal order. Independent
            # finalization pools use a total tie-breaker instead of completion order.
            tie = (row.get('chapter', -1), row.get('id', ''),
                   json.dumps(row, ensure_ascii=False, sort_keys=True)) if phase else ()
            ordered.append((row['p'], phase, tie, index, row))
        log_sorted = [row for _, _, _, _, row in sorted(ordered)]
        wjson(self.root / 'kg.json', {'log': log_sorted, 'segments': [[s['o0'], s['o1'], s['chapter']] for s in self.segs]})
        by_ch: dict[int, list] = {}
        chapters = self.book['chapters']
        ci = 0
        for m in sorted(mentions):
            while ci < len(chapters) - 1 and m[0] >= chapters[ci]['o1']:
                ci += 1
            by_ch.setdefault(ci, []).append(m)
        for c, ms in by_ch.items():
            wjson(self.root / 'mentions' / f'{c:04d}.json', ms)
        for path in (self.root / 'mentions').glob('*.json'):
            if path.stem.isdigit() and int(path.stem) not in by_ch:
                path.unlink()

    # ------------------------------------------------------------ one segment
    def process(self, i: int) -> dict:
        seg = self.segs[i]
        state = self.kg.prompt_state()
        t0 = time.time()
        raw_path = self.work / 'classic_raw' / f'{i:04d}.json'
        if raw_path.exists():
            cached = json.loads(raw_path.read_text())
            if cached.get('input_sha256') != self.input_sha256 or cached.get('model') != self.model:
                raise LLMError('经典抽取缓存来源不符')
            data, usage = cached['data'], cached['usage']
        else:
            data, usage = extract_segment(self.book, state, seg, self.model)
            self.count(self.model, usage)
            wjson(raw_path, {'model': self.model, 'input_sha256': self.input_sha256, 'data': data, 'usage': usage})
        t1 = time.time()
        plan = self.kg.plan(seg, data)
        # --- Jev guard on generated descriptions
        text = seg_text(self.book, seg)
        items, earlier = {}, {}
        intro_of = {np.get('ref'): np.get('intro') for np in data['new_people']}
        for pr in data['profiles']:
            who = str(pr.get('who'))
            items[who] = f"{pr.get('tagline', '')}。{pr.get('bio', '')}"
            pid = self.kg.lookup(who, plan['refmap'])
            if pid in self.kg.people and self.kg.people[pid].get('bio'):
                earlier[who] = self.kg.people[pid]['bio']
        for ref, intro in intro_of.items():
            if intro and f'intro:{ref}' not in items:
                items[f'intro:{ref}'] = intro
        guard = {'checks': {}, 'rewrites': {}}
        try:
            verdicts = guard_texts(text, earlier, items)
            self.usage['jev_calls'] += 1
        except Exception as e:
            raise LLMError(f'第 {i} 段人物描述验证失败，已保留抽取缓存：{e}') from e
        if any(verdicts.get(k, {}).get('verdict') not in ('ok', 'flag') for k in items):
            raise LLMError('人物描述缺少有效验证结果')
        for pr in data['profiles']:
            who = str(pr.get('who'))
            v = verdicts.get(who)
            if not v:
                continue
            guard['checks'][who] = {'jev': v['p'], 'verdict': v['verdict']}
            if v['verdict'] == 'flag':
                try:
                    fixed = self.cached_generation(f'rewrite-{i}-{who}', self.model, [{'role': 'user', 'content': REWRITE.format(
                        old=earlier.get(who) or '（无）', text=text, tagline=pr.get('tagline', ''), bio=pr.get('bio', ''))}],
                        max_tokens=1500, temperature=0.1, json_output=True)
                    guard['rewrites'][who] = {'before': {'tagline': pr.get('tagline'), 'bio': pr.get('bio')}}
                    pr['tagline'] = fixed.get('tagline') or pr.get('tagline')
                    pr['bio'] = fixed.get('bio') or pr.get('bio')
                    again = guard_texts(text, earlier, {who: f"{pr['tagline']}。{pr['bio']}"}).get(who, {})
                    if again.get('verdict') not in ('ok', 'flag'):
                        raise LLMError('重写后的人物描述缺少有效验证结果')
                    guard['checks'][who] = {'jev': again.get('p'), 'verdict': 'rewritten' if again['verdict'] == 'ok' else 'withheld',
                                            'first': v['p'], 'after_verdict': again['verdict'], 'verified': True}
                    if again['verdict'] == 'flag':
                        pr['_withheld'] = True
                except Exception as e:
                    raise LLMError(f'人物描述重写尚未验证：{e}') from e
        data['profiles'] = [pr for pr in data['profiles'] if not pr.pop('_withheld', False)]
        for ref in intro_of:
            v = verdicts.get(f'intro:{ref}')
            if v and v['verdict'] == 'flag':
                for np in data['new_people']:
                    if np.get('ref') == ref:
                        guard['rewrites'][f'intro:{ref}'] = np.get('intro')
                        np['intro'] = ''
        # --- Jev check of short attribute facts
        try:
            refnames = {np.get('ref'): np.get('name') for np in data['new_people']}
            intros = {np.get('ref'): np.get('intro') for np in data['new_people']}

            def who_of(w):
                if w in refnames:
                    return refnames[w], intros.get(w) or '本段新出场的人物'
                pp = self.kg.people.get(self.kg.lookup(w, plan['refmap']) or '') or {}
                return pp.get('name', str(w)), pp.get('tagline') or pp.get('intro') or ''
            guard['attrs'] = check_attrs(text, data, who_of)
            self.usage['jev_calls'] += 1
        except Exception as e:
            guard['attrs_error'] = str(e)[:200]
        # --- Jev mention disambiguation
        try:
            decisions, raw = resolve_mentions(self.book, seg, plan['occs'], self._describe_factory(data, plan))
            self.usage['jev_calls'] += (len([o for o in plan['occs'] if o['ambiguous']]) + 15) // 16
        except Exception as e:
            decisions, raw = {}, {'error': str(e)[:200]}
        record = {'seg': i, 'o0': seg['o0'], 'o1': seg['o1'], 'model': self.model, 'data': data,
                  'raw': usage.get('_raw'),
                  'decisions': decisions, 'jev_raw': raw, 'guard': guard,
                  'timing': {'llm': round(t1 - t0, 1), 'total': round(time.time() - t0, 1)},
                  'usage': {'prompt': usage.get('prompt_tokens'), 'completion': usage.get('completion_tokens')}}
        wjson(self.seg_path(i), record)
        return record

    def _describe_factory(self, data, plan):
        intro = {plan['refmap'].get(np.get('ref')): np for np in data['new_people']}

        def describe(pid):
            if pid in self.kg.people:
                return self.kg.describe(pid)
            np = intro.get(pid) or {}
            return f"{np.get('name', '')}（{np.get('intro', '本段新出场')}）"
        return describe

    def apply(self, rec: dict):
        settle_rewrites(rec)
        seg = self.segs[rec['seg']]
        if any(k in rec and rec[k] != seg[k] for k in ('o0', 'o1')):
            raise LLMError('分段边界与缓存不符，拒绝混用旧结果')
        provenance = rec.get('provenance') or {}
        if provenance.get('input_sha256') and provenance['input_sha256'] != getattr(self, 'input_sha256', None):
            raise LLMError('书籍输入与缓存不符，拒绝重放')
        with self.lock:
            plan = self.kg.plan(seg, rec['data'])
            self.kg.commit(seg, rec['data'], plan, rec.get('decisions') or {}, rec.get('guard'))

    # ------------------------------------------------------------ chapter recaps
    def recap(self, ci: int, end_pos: int, start_pos: int):
        path = self.recap_path(ci)
        if self.quarantined(path):
            return
        if path.exists():
            r = json.loads(path.read_text())
            if self.verified_summary(r, 'recap', 'saga'):
                with self.lock:
                    self.kg.add_recap(ci, end_pos, r['recap'], r.get('saga', ''))
                self.acknowledge_final_cache('recap' if self.two_phase else 'classic-recap', ci)
                return
        with self.lock:
            events = [e for e in self.kg.log if e['t'] == 'event' and start_pos <= e['p'] <= end_pos]
            names = {x: self.kg.people[x]['name'] for e in events for x in e['who'] if x in self.kg.people}
            profs = [(self.kg.people[e['id']]['name'], e['tagline']) for e in self.kg.log
                     if e['t'] == 'profile' and start_pos <= e['p'] <= end_pos and e['id'] in self.kg.people and e.get('tagline')]
        if self.two_phase:
            f = self.queue_final('recap', ci, [ci, end_pos, events, names], self.recap_pool)
            self.recap_futures[ci] = f
        else:
            self.queue_final('classic-recap', ci, [ci, end_pos, events, names, profs, self.kg.saga], self.saga_pool)

    def _chapter_recap_job(self, ci, end_pos, events, names):
        ev_text = '\n'.join(f"- {e['text']}（{'、'.join(names[x] for x in e['who'] if x in names)}）" for e in events)
        if not ev_text:
            r = {'chapter': ci, 'recap': ''}
        else:
            try:
                txt = self.cached_generation(f'recap-{ci}', os.environ.get('RECAP_MODEL', RECAP_MODEL), [{'role': 'user', 'content': CHAPTER_RECAP.format(
                    title=self.book['title'], chapter=self.chapter_name(ci), events=ev_text) + out_note(self.book)}],
                    max_tokens=1200 * scale(self.book), temperature=0.3)
            except Exception as e:
                log(f'recap failed for chapter {ci}: {e}')
                raise
            r = {'chapter': ci, 'recap': zh(txt.strip())}
            try:
                v = guard_texts(ev_text, {}, {'recap': r['recap']})
                if v.get('recap', {}).get('verdict') not in ('ok', 'flag'):
                    raise LLMError('章节摘要缺少有效验证结果')
                r['guard'] = v
                if v.get('recap', {}).get('verdict') == 'flag':
                    r['recap_flagged'] = r['recap']
                    r['recap'] = '；'.join(e['text'] for e in events if e.get('imp', 1) >= 2)[:300]
                    r['fallback_kind'] = 'verified-input-excerpt'
            except Exception as e:
                raise LLMError(f'章节摘要验证失败：{e}') from e
        wjson(self.recap_path(ci), r)
        with self.lock:
            self.kg.add_recap(ci, end_pos, r['recap'], '')
        return r

    def saga_path(self, end_pos: int) -> Path:
        return self.work / 'sagas' / f'{end_pos:09d}.json'

    def saga(self, end_pos: int, chapters: list[int]):
        """Update the story so far from the recaps of the given chapters (ordered chain)."""
        path = self.saga_path(end_pos)
        if self.quarantined(path):
            return
        if path.exists():
            r = json.loads(path.read_text())
            if self.verified_summary(r, 'saga'):
                with self.lock:
                    self.kg.add_recap(-1, end_pos, '', r['saga'])
                self.acknowledge_final_cache('saga', end_pos)
                return
        self.queue_final('saga', end_pos, [end_pos, chapters, None, self.kg.saga], self.saga_pool)

    def _saga_job(self, end_pos, chapters, futs=None, before=None):
        for path in (self.work / 'jobs').glob('saga-*.json'):
            earlier = json.loads(path.read_text())
            if int(earlier['key']) < end_pos and earlier.get('state') != 'complete':
                raise LLMError('较早的前情提要尚未完成，后续整理已暂停')
        futs = futs or [self.recap_futures.get(ci) for ci in chapters]
        recaps = []
        for ci, f in zip(chapters, futs):
            if self.quarantined(self.recap_path(ci)):
                raise LLMError('前情提要依赖的章节摘要仍在隔离中')
            r = f.result() if f else (json.loads(self.recap_path(ci).read_text()) if self.recap_path(ci).exists() else None)
            if r is None or not self.verified_summary(r, 'recap'):
                raise LLMError('前情提要所需的章节摘要尚未通过验证')
            if r and r.get('recap'):
                recaps.append(f"【{self.chapter_name(ci)}】{r['recap']}")
        if not recaps:
            raise LLMError('前情提要所需的章节摘要尚未完成')
        before = self.earlier_saga(end_pos, before or '')
        try:
            txt = self.cached_generation(f'saga-{end_pos}', os.environ.get('RECAP_MODEL', RECAP_MODEL), [{'role': 'user', 'content': SAGA.format(
                title=self.book['title'], chapter=self.chapter_name(chapters[-1]), saga=before or '（故事刚开始）',
                recaps='\n'.join(recaps)) + out_note(self.book)}], max_tokens=2500 * scale(self.book), temperature=0.3)
        except Exception as e:
            log(f'saga failed at {end_pos}: {e}')
            raise
        r = {'end': end_pos, 'saga': zh(txt.strip())}
        try:
            v = guard_texts('\n'.join(recaps), {'previous_story_so_far': before}, {'saga': r['saga']})
            if v.get('saga', {}).get('verdict') not in ('ok', 'flag'):
                raise LLMError('前情提要缺少有效验证结果')
            r['guard'] = v
            if v.get('saga', {}).get('verdict') == 'flag':
                r['saga_flagged'] = r['saga']
                r['saga'] = (before + '\n' + '\n'.join(recaps)).strip()[-1500:]
                r['fallback_kind'] = 'verified-input-excerpt'
        except Exception as e:
            raise LLMError(f'前情提要验证失败：{e}') from e
        wjson(self.saga_path(end_pos), r)
        with self.lock:
            self.kg.add_recap(-1, end_pos, '', r['saga'])

    def _recap_job(self, ci, end_pos, events, names, profs, saga_before=None):
        ev_text = '\n'.join(f"- {e['text']}（{'、'.join(names[x] for x in e['who'] if x in names)}）" for e in events) or '（本章没有记录到事件）'
        pr_text = '\n'.join(f'- {n}：{t}' for n, t in profs) or '（无）'
        saga_before = self.earlier_saga(end_pos, saga_before or '')
        prompt = RECAP.format(title=self.book['title'], chapter=self.chapter_name(ci), saga=saga_before or '（故事刚开始）',
                              events=ev_text, profiles=pr_text)
        try:
            txt = self.cached_generation(f'classic-recap-{ci}', os.environ.get('RECAP_MODEL', RECAP_MODEL),
                                         [{'role': 'user', 'content': prompt}], max_tokens=3000, temperature=0.3)
            out = {k: (re.search(f'<{k}>(.*?)</{k}>', txt, re.S) or re.search(f'<{k}>(.*)', txt, re.S) or [None, ''])[1] for k in ('recap', 'saga')}
            if not out['saga']:
                raise ValueError('提要格式不对：' + txt[:200])
        except Exception as e:
            log(f'recap failed for chapter {ci}: {e}')
            raise
        r = {'chapter': ci, 'recap': (out.get('recap') or '').strip(), 'saga': (out.get('saga') or '').strip()}
        try:
            v = guard_texts(ev_text, {'previous_story_so_far': saga_before}, {'recap': r['recap'], 'saga': r['saga']})
            if any(v.get(k, {}).get('verdict') not in ('ok', 'flag') for k in ('recap', 'saga')):
                raise LLMError('章节整理缺少有效验证结果')
            r['guard'] = v
            if v.get('recap', {}).get('verdict') == 'flag':
                r['recap_flagged'] = r['recap']
                r['recap'] = '；'.join(e['text'] for e in events if e.get('imp', 1) >= 2)[:300]
                r['fallback_kind'] = 'verified-input-excerpt'
            if v.get('saga', {}).get('verdict') == 'flag':
                r['saga_flagged'] = r['saga']
                r['saga'] = (saga_before + '\n' + r['recap']).strip() if r['recap'] else saga_before
                r['fallback_kind'] = 'verified-input-excerpt'
        except Exception as e:
            raise LLMError(f'章节整理验证失败：{e}') from e
        wjson(self.recap_path(ci), r)
        with self.lock:
            self.kg.add_recap(ci, end_pos, r['recap'], r['saga'])

    # ------------------------------------------------------------ chapter-end duplicate check
    def dedupe_path(self, ci: int) -> Path:
        return self.work / 'dedupe' / f'{ci:04d}.json'

    def dedupe(self, ci: int, end_pos: int, start_pos: int):
        """Linking prefers a duplicate to a wrong merge; here, at a chapter end, pairs of records that
        look like one person (same or related names, never together in one event or relation) are shown
        to JEV with what is known up to this point. Accepted merges take effect from the chapter end."""
        path = self.dedupe_path(ci)
        if self.quarantined(path) or end_pos >= getattr(self, 'repair_policy', {}).get('quarantine_after', float('inf')):
            return
        if path.exists():
            out = json.loads(path.read_text())
        elif getattr(self, 'replaying', False):
            merged = [[r['from'], r['into']] for r in self.prior_log
                      if r.get('t') == 'merge' and r.get('kind') == 'dedupe' and r.get('p') == end_pos]
            out = {'pairs': merged, 'merged': merged}
        else:
            with self.lock:
                pairs, dossiers = self._dedupe_candidates(end_pos, start_pos)
            out = {'chapter': ci, 'end': end_pos, 'pairs': pairs, 'answers': {}, 'merged': []}
            if pairs:
                try:
                    out['answers'] = self._dedupe_ask(pairs, dossiers)
                    self.usage['jev_calls'] += (len(pairs) + 15) // 16
                except Exception as e:
                    log(f'dedupe failed at chapter {ci}: {e}')
                    return
                for a, b in pairs:
                    # a description matched to a name needs more certainty than two records with the same name
                    need = 0.9 if (a, b) in self.desc_pairs else 0.8
                    if out['answers'].get(f'{a}|{b}', 0) >= need:
                        out['merged'].append([a, b])
            wjson(path, out)
        with self.lock:
            for a, b in out['pairs']:
                self.dedupe_seen.add((a, b))
            for a, b in out['merged']:
                a, b = self.kg.canon(a), self.kg.canon(b)
                if a and b and a != b and a in self.kg.people and b in self.kg.people:
                    self.kg.log.append(self.kg.merge(a, b, end_pos, end_pos, '章末核对：同一人物的重复记录', kind='dedupe'))
        if out['merged']:
            log(f"dedupe chapter {ci}: merged {len(out['merged'])} of {len(out['pairs'])} pairs")

    def _dedupe_candidates(self, end_pos: int, start_pos: int):
        kg = self.kg
        scope = self.scope_start(end_pos)
        people = {pid: p for pid, p in kg.people.items()
                  if not p.get('merged_into') and scope <= p.get('first', 0) <= end_pos}
        together = set()
        for r in kg.log:
            if r['t'] == 'event' and len(r['who']) > 1:
                ws = sorted({kg.canon(w) for w in r['who']})
                together |= {(x, y) for x in ws for y in ws if x < y}
        for r in kg.rels.values():
            together.add(tuple(sorted((kg.canon(r['a']), kg.canon(r['b'])))))
        recent = {pid for pid, p in people.items() if p.get('first', 0) >= start_pos or p.get('last_seg', -1) >= kg.seg - 6}

        def names(p):
            return {n for n in p['aliases'] | {p['name']} if len(n) >= 2}
        pairs = []
        for a in sorted(recent, key=lambda x: (people[x].get('first', 0), x)):
            pa = people[a]
            for b, pb in people.items():
                if b == a or (min(a, b), max(a, b)) in together or pa.get('gender') and pb.get('gender') and pa['gender'] != pb['gender']:
                    continue
                x, y = sorted((a, b), key=lambda q: (people[q].get('first', 0), q))   # merge the later record into the earlier
                if (y, x) in self.dedupe_seen or (y, x) in pairs:
                    continue
                na, nb = names(pa), names(pb)
                proper_a = {n for n in na if not is_generic(n)}
                proper_b = {n for n in nb if not is_generic(n)}
                same_name = bool(na & nb)
                same_core = bool({core(n) for n in proper_a} & {core(n) for n in proper_b} - {''})
                close = any(related(m, n) or related(n, m) for m in sorted(proper_a) for n in sorted(proper_b)) if proper_a and proper_b else False
                if same_name or same_core or close:
                    pairs.append((y, x))
        # someone first known only by a description ("the little man") and later named in the text
        # ("a man of the name of Hyde"): propose the named people whose records share the most words
        def words(pid):
            p = people[pid]
            txt = ' '.join([p.get('intro') or '', p.get('tagline') or ''] +
                           [e['text'] for e in kg.log[-4000:] if e['t'] == 'event' and pid in {kg.canon(w) for w in e['who']}])
            en = {w.lower() for w in re.findall(r'[A-Za-z]{4,}', txt)} - STOPWORDS
            zh_ = re.sub(r'[^\u4e00-\u9fff]', '', txt)
            return en | {zh_[i:i + 2] for i in range(len(zh_) - 1)}
        nameless = [a for a in sorted(recent) if not any(not is_generic(n) for n in sorted(names(people[a])))]
        named = [b for b in people if b not in nameless and any(not is_generic(n) for n in sorted(names(people[b])))
                 and (b in recent or people[b].get('first', 0) >= start_pos)]
        for a in nameless:
            wa = words(a)
            scored = []
            for b in named:
                pa, pb = people[a], people[b]
                if (min(a, b), max(a, b)) in together or pa.get('gender') and pb.get('gender') and pa['gender'] != pb['gender']:
                    continue
                if (a, b) in self.dedupe_seen or (b, a) in self.dedupe_seen:
                    continue
                k = len(wa & words(b))
                if k >= 3:
                    scored.append((k, b))
            for _, b in sorted(scored, reverse=True)[:2]:
                pr = (a, b) if people[a].get('first', 0) > people[b].get('first', 0) else (b, a)
                pairs.append(pr)
                self.desc_pairs.add(pr)
        pairs = list(dict.fromkeys(pairs))[:32]
        dossiers = {}
        for pid in sorted({q for pr in pairs for q in pr}):
            p = kg.people[pid]
            evs = [e['text'] for e in kg.log if e['t'] == 'event' and e['p'] <= end_pos and pid in {kg.canon(w) for w in e['who']}]
            rels = [f"{kg.people[r['b'] if r['a'] == pid else r['a']]['name']}（{r['b_is'] if r['a'] == pid else r['a_is']}）"
                    for r in kg.rels.values() if pid in (r['a'], r['b'])]
            al = '、'.join(sorted((p['aliases'] | p.get('weak', set())) - {p['name']})[:8])
            dossiers[pid] = (f"{p['name']}（又称：{al or '无'}；性别：{p.get('gender') or '未知'}）：{p.get('tagline') or p.get('intro') or ''}。"
                             f"关系：{'、'.join(rels[:6]) or '无'}。经历：{'；'.join(evs[:4] + (['……'] + evs[-4:] if len(evs) > 8 else evs[4:8]))}")[:900]
            if any(pid in pr for pr in self.desc_pairs):
                # the words around the first appearance are the evidence for "that stranger was X"
                dossiers[pid] += f"\n首次出场处原文：「{self._text_around(p.get('first', 0), 500)}」"
        return [list(pr) for pr in pairs], dossiers

    def _text_around(self, pos: int, width: int) -> str:
        blocks = self.book['blocks']
        lo, hi = 0, len(blocks) - 1
        while lo < hi:                      # last block starting at or before pos
            mid = (lo + hi + 1) // 2
            if blocks[mid]['o'] <= pos:
                lo = mid
            else:
                hi = mid - 1
        text = ' '.join(b['t'] for b in blocks[max(0, lo - 2):lo + 2])
        at = sum(len(b['t']) + 1 for b in blocks[max(0, lo - 2):lo]) + (pos - blocks[lo]['o'])
        return text[max(0, at - width // 2):at + width // 2]

    def _dedupe_ask(self, pairs, dossiers) -> dict:
        out = {}
        for k0 in range(0, len(pairs), 16):
            chunk = pairs[k0:k0 + 16]
            qs = {}
            for n, (a, b) in enumerate(chunk, 1):
                qs[f'd{n}'] = {
                    'type': 'choice',
                    'instructions': ('Two character records were built from a novel, read up to the same point. '
                                     f'Record A: {dossiers[a]}\nRecord B: {dossiers[b]}\n'
                                     'Are A and B the same character recorded twice? A story may keep a stranger\'s identity '
                                     'secret on purpose: similar descriptions are not enough — say "same" only if the records '
                                     'themselves establish it (same name, or the text says who that person is).'),
                    'criteria': {
                        'same': 'Clearly one character, established by the records: compatible names, same role and situation, nothing contradicts.',
                        'different': 'Different characters: e.g. relatives sharing a surname, two people with the same job or title, or anything contradicts.',
                        'unclear': 'Cannot tell from these records.'}}
            ans = jev({'note': 'Judge only from the two records given.'}, qs)
            for n, (a, b) in enumerate(chunk, 1):
                out[f'{a}|{b}'] = round(((ans.get(f'd{n}') or {}).get('probabilities') or {}).get('same', 0), 3)
        return out

    # ------------------------------------------------------------ chapter-end biographies
    def consolidate(self, ci: int, end_pos: int, start_pos: int):
        """Rewrite biographies of people active since start_pos as whole-life summaries.

        The dossier is a snapshot of the graph now; the model call runs in the background so
        extraction of the next segment is not blocked. Cached results apply synchronously."""
        path = self.bio_path(ci)
        if self.quarantined(path):
            return
        if path.exists():
            cached = json.loads(path.read_text())
            self._apply_bios(cached, end_pos)
            if all((value.get('chk') or {}).get('verdict') == 'ok' for value in cached.get('bios', {}).values()):
                self.acknowledge_final_cache('bio', ci)
                return
        with self.lock:
            dossiers, chosen = self._dossiers(end_pos, start_pos)
        if not chosen:
            wjson(path, {'chapter': ci, 'bios': {}})
            return
        self.queue_final('bio', ci, [ci, end_pos, dossiers, chosen], self.pool)

    def rate_importance(self, end_pos: int, start_pos: int):
        """Let the judge say who matters so far; the cast list and the graph follow this."""
        if os.environ.get('JUDGE_IMPORTANCE', '1') != '1':
            return
        kg = self.kg
        if end_pos >= getattr(self, 'repair_policy', {}).get('quarantine_after', float('inf')):
            return
        saved = self.work / 'finalize' / f'{end_pos}-importance.json'
        if saved.exists() or getattr(self, 'replaying', False):
            records = (json.loads(saved.read_text())['records'] if saved.exists() else
                       [r for r in self.prior_log if r.get('t') == 'imp' and r.get('p') == end_pos])
            for record in records:
                if record.get('id') in kg.people:
                    kg.people[record['id']].update(imp=record['imp'], imp_p=end_pos)
                    kg.log.append(dict(record))
            return
        concept = self.book.get('genre') in ('nonfiction', 'reference')
        fresh = [p for p in kg.people.values()
                 if not p.get('merged_into') and p.get('first', 0) <= end_pos
                 and (p.get('imp_p', -1) < start_pos) and (p.get('mentions', 0) >= 2 or p.get('first', 0) >= start_pos)]
        fresh.sort(key=lambda p: -(p.get('mentions', 0)))
        fresh = fresh[:BATCH]
        if not fresh:
            return
        dossiers = {}
        for p in fresh:
            evs = [e['text'] for e in kg.log if e['t'] == 'event' and e['p'] <= end_pos
                   and p['id'] in {kg.canon(w) for w in e['who']}][:6]
            dossiers[p['id']] = (f"{p['name']}（{p.get('tagline') or p.get('intro') or ''}；出现 {p.get('mentions', 0)} 次）"
                                 f"：{'；'.join(evs) or '本段之前没有记录到事件'}")[:600]
        try:
            rated = importance(dossiers, concept)
            self.usage['jev_calls'] += 1
        except Exception as e:
            log(f'importance failed at {end_pos}: {type(e).__name__}: {e}')
            return
        for pid, imp in rated.items():
            p = kg.people.get(pid)
            if not p or imp == p.get('imp'):
                continue
            p['imp'] = imp
            p['imp_p'] = end_pos
            kg.log.append({'t': 'imp', 'p': end_pos, 'id': pid, 'imp': imp})
        for p in fresh:
            p['imp_p'] = end_pos
        wjson(saved, {'records': [r for r in kg.log if r.get('t') == 'imp' and r.get('p') == end_pos]})

    def settle_attrs(self, end_pos: int, start_pos: int):
        """When a person's 住处/职业/处境 has been said more than one way, ask which one holds now."""
        if os.environ.get('JUDGE_ATTRS', '1') != '1':
            return
        kg = self.kg
        if end_pos >= getattr(self, 'repair_policy', {}).get('quarantine_after', float('inf')):
            return
        saved = self.work / 'finalize' / f'{end_pos}-attrs.json'
        if saved.exists() or getattr(self, 'replaying', False):
            records = (json.loads(saved.read_text())['records'] if saved.exists() else
                       [r for r in self.prior_log if r.get('t') == 'attr' and r.get('by') == 'judge' and r.get('p') == end_pos])
            kg.log.extend(dict(r) for r in records)
            return
        seen: dict = {}
        for r in kg.log:
            if r['t'] == 'attr' and r['p'] <= end_pos:
                pid = kg.canon(r['id'])
                if pid in kg.people:
                    seen.setdefault((pid, r['key']), []).append((r['p'], r['value']))
        items = {}
        for (pid, key), vals in seen.items():
            if len(vals) < 2 or vals[-1][0] < start_pos:      # only what this chapter touched
                continue
            ordered = [v for _p, v in sorted(vals)][-4:]
            if len(set(ordered)) < 2:
                continue
            items[f'{pid}|{key}'] = (kg.people[pid]['name'], key, list(dict.fromkeys(ordered)))
        items = dict(list(items.items())[:BATCH])
        if not items:
            return
        try:
            chosen = current_value(items)
            self.usage['jev_calls'] += 1
        except Exception as e:
            log(f'attribute settling failed at {end_pos}: {type(e).__name__}: {e}')
            return
        for k, value in chosen.items():
            pid, key = k.split('|', 1)
            latest = max((r for r in kg.log if r['t'] == 'attr' and kg.canon(r['id']) == pid and r['key'] == key
                          and r['p'] <= end_pos), key=lambda r: r['p'], default=None)
            if latest is not None and latest['value'] != value:
                # restate the one that holds, at the end of the chapter, so the card shows it
                kg.log.append({'t': 'attr', 'p': end_pos, 's': end_pos, 'id': pid, 'key': key,
                               'value': value, 'by': 'judge'})
        wjson(saved, {'records': [r for r in kg.log if r.get('t') == 'attr' and r.get('by') == 'judge' and r.get('p') == end_pos]})

    def _dossiers(self, end_pos: int, start_pos: int):
        kg = self.kg
        events = [e for e in kg.log if e['t'] == 'event' and start_pos <= e['p'] <= end_pos]
        active: dict[str, int] = {}
        for e in events:
            for w in e['who']:
                c = kg.canon(w)
                active[c] = active.get(c, 0) + 1
        chosen = [pid for pid, n in active.items() if pid in kg.people and (n >= 2 or (kg.people[pid].get('imp', 1) >= 3 and n))]
        chosen = sorted(chosen, key=lambda x: -active[x])[:10]
        blocks = []
        for pid in chosen:
            p = kg.people[pid]
            attrs = {}
            for r in kg.log:
                if r['t'] == 'attr' and kg.canon(r['id']) == pid and r['p'] <= end_pos:
                    attrs[r['key']] = r['value']
            rels = [f"{kg.people[r['b'] if r['a'] == pid else r['a']]['name']}（{r['b_is'] if r['a'] == pid else r['a_is']}）"
                    for r in kg.rels.values() if pid in (r['a'], r['b']) and r.get('status') != 'ended'
                    and (r['b'] if r['a'] == pid else r['a']) in kg.people]
            history = [e for e in kg.log if e['t'] == 'event' and e['p'] <= end_pos
                       and pid in {kg.canon(w) for w in e['who']} and (e.get('imp', 1) >= 2 or e['p'] >= start_pos)]
            history = sorted(history, key=lambda e: e['p'])[-45:]
            blocks.append(f"【{pid}｜{p['name']}】\n别称：{'、'.join(sorted(a for a in p['aliases'] if a != p['name'])[:6]) or '无'}\n"
                          f"当前一句话身份：{p.get('tagline') or ''}\n"
                          f"档案（最新）：{'；'.join(f'{k}：{v}' for k, v in attrs.items()) or '无'}\n关系：{'、'.join(rels) or '无'}\n"
                          f"至今经历（按时间）：\n" + '\n'.join('- ' + e['text'] for e in history))
        return '\n\n'.join(blocks), chosen

    def _bio_job(self, ci: int, end_pos: int, dossiers: str, chosen: list):
        try:
            data = self.cached_generation(f'bio-{ci}', self.model, [{'role': 'user', 'content': CONSOLIDATE.format(
                title=self.book['title'], chapter=self.chapter_name(ci), dossiers=dossiers) + out_note(self.book)}],
                max_tokens=6000 * scale(self.book), temperature=0.2, json_output=True)
        except Exception as e:
            log(f'consolidation failed for chapter {ci}: {e}')
            raise
        bios = {pid: v for pid, v in (data or {}).items() if pid in chosen and isinstance(v, dict) and v.get('bio')}
        try:
            verdicts = guard_texts(dossiers, {}, {pid: f"{v.get('tagline', '')}。{v['bio']}" for pid, v in bios.items()})
            self.usage['jev_calls'] += 1
        except Exception as e:
            raise LLMError(f'人物小传验证失败：{e}') from e
        for pid, v in list(bios.items()):
            vd = verdicts.get(pid) or {}
            if vd.get('verdict') not in ('ok', 'flag'):
                raise LLMError('人物小传缺少有效验证结果')
            v['chk'] = {'jev': vd.get('p'), 'verdict': vd['verdict']}
            if vd.get('verdict') == 'flag':
                bios.pop(pid)       # keep the extraction-time biography instead
        out = {'chapter': ci, 'bios': bios}
        wjson(self.bio_path(ci), out)
        self._apply_bios(out, end_pos)
        self.publish()
        log(f'biographies for chapter {ci}: {len(bios)} people')

    def _apply_bios(self, out: dict, end_pos: int):
        with self.lock:
            for pid, v in out['bios'].items():
                if pid not in self.kg.people:
                    continue
                if (v.get('chk') or {}).get('verdict') != 'ok':
                    self.quality_pending.add(f'bio-unverified-{end_pos}-{pid}')
                    continue
                k = scale(self.book)
                rec = {'t': 'profile', 'p': end_pos, 'id': pid, 'tagline': zh((v.get('tagline') or '')[:30 * k]),
                       'bio': zh(v['bio'][:420 * k]), 'chk': v.get('chk'), 'kind': 'chapter'}
                self.kg.log.append(rec)
                person = self.kg.people[pid]
                if end_pos >= person.get('profile_p', -1):
                    person['tagline'] = rec['tagline'] or person.get('tagline', '')
                    person['bio'] = rec['bio']
                    person['profile_p'] = end_pos

    # ------------------------------------------------------------ main loop
    def run(self, limit: int | None = None):
        if limit != 0 and self.repair_policy.get('identity_taint'):
            raise LLMError('人物关联结果已隔离，请显式重试质量检查后继续处理')
        done = 0
        self.replaying = True
        for i in range(len(self.segs)):
            self.checkpoint()
            p = self.seg_path(i)
            if not p.exists():
                break
            self.apply(json.loads(p.read_text()))
            self._maybe_recap(i)
            done = i + 1
        self.replaying = False
        if limit != 0:
            self.resume_final_jobs()
            for future in self.pending:
                self.await_future(future)
        finalized = len(self.pending)
        log(f'replayed {done}/{len(self.segs)} segments')
        if done == len(self.segs):
            if limit != 0:
                self.finish_quality_retry()
        self.publish()
        self.status('running' if done < len(self.segs) else 'done', done)
        n = 0
        for i in range(done, len(self.segs)):
            self.checkpoint()
            if limit is not None and n >= limit:
                break
            for attempt in range(3):
                try:
                    rec = self.process(i)
                    break
                except Cancelled:
                    raise
                except Exception as e:
                    log(f'segment {i} failed (attempt {attempt + 1}): {e}')
                    traceback.print_exc()
                    self.status('running', i, error=str(e)[:300])
                    if self.cancel_event is None:
                        time.sleep(20 * (attempt + 1))
                    elif self.cancel_event.wait(20 * (attempt + 1)):
                        raise Cancelled()
            else:
                self.status('error', i, error='连续失败，已暂停')
                return
            self.checkpoint()
            self.apply(rec)
            self._maybe_recap(i)
            # The next segment's prompt reads KG state; settle this chapter's
            # final jobs before that snapshot can observe a timing-dependent subset.
            for future in self.pending[finalized:]:
                self.await_future(future)
            finalized = len(self.pending)
            self.publish()
            done = i + 1
            n += 1
            if done == len(self.segs):
                self.finish_quality_retry()
            self.status('running' if done < len(self.segs) else 'done', done)
            d = rec['data']
            log(f"seg {i + 1}/{len(self.segs)} {rec['timing']} new={len(d['new_people'])} ev={len(d['events'])} "
                f"rel={len(d['rels'])} prof={len(d['profiles'])} amb={len(rec['decisions'])} "
                f"rewrites={len(rec['guard'].get('rewrites', {}))} people={sum(1 for p in self.kg.people.values() if not p.get('merged_into'))}")

    # ------------------------------------------------------------ two-phase mode
    def local_path(self, i: int) -> Path:
        return self.work / 'local' / f'{i:04d}.json'

    def scope_start(self, pos: int) -> int:
        """Where the work containing this position begins (0 when the book is one work)."""
        for a, b in getattr(self, 'works', []):
            if a <= pos <= b:
                return a
        return 0

    def cast_hint(self, limit: int = 90) -> str:
        """Compact list of people known so far (called under the lock, from phase-2 state)."""
        kg = self.kg
        start = self.scope_start(self.segs[min(kg.seg, len(self.segs) - 1)]['o0']) if self.works and self.segs else 0
        people = [p for p in kg.people.values() if not p.get('merged_into') and p.get('first', 0) >= start]
        people.sort(key=lambda p: (-(p.get('mentions', 0) + 20 * (kg.seg - p.get('last_seg', -99) <= 6)), p['id']))
        rows = []
        for p in people[:limit]:
            al = '、'.join(sorted((p['aliases'] | p.get('weak', set())) - {p['name']})[:6])
            rows.append(f"{p['id']}｜{p['name']}｜{al or '—'}｜{(p.get('tagline') or p.get('intro') or '')[:24]}")
        return '\n'.join(rows)

    def relation_memory(self, limit: int = 90) -> dict:
        """Spoiler-bounded character memory captured when a phase-1 job is submitted.

        The relation judge used to see only one segment and two display names. Keep
        the small biographies: they identify who each local record is, while the
        current passage remains the required evidence for adding a tie.
        """
        kg = self.kg
        start = self.scope_start(self.segs[min(kg.seg, len(self.segs) - 1)]['o0']) if self.works and self.segs else 0
        people = [p for p in kg.people.values() if not p.get('merged_into') and p.get('first', 0) >= start]
        people.sort(key=lambda p: (-(p.get('mentions', 0) + 20 * (kg.seg - p.get('last_seg', -99) <= 6)), p['id']))
        chosen = {p['id']: p for p in people[:limit]}
        events = {pid: [] for pid in chosen}
        relation_rows = {pid: [] for pid in chosen}
        for row in kg.log[-3000:]:
            if row.get('t') != 'event':
                continue
            for raw in row.get('who', []):
                pid = kg.canon(raw)
                if pid in events:
                    events[pid].append(row.get('text', ''))
        for rel in kg.rels.values():
            for pid in (rel.get('a'), rel.get('b')):
                if pid not in relation_rows:
                    continue
                other = rel['b'] if rel['a'] == pid else rel['a']
                if other not in kg.people:
                    continue
                role = rel.get('b_is') if rel['a'] == pid else rel.get('a_is')
                relation_rows[pid].append(f"{kg.people[other]['name']}（{role or '关系未命名'}）")
        records = {}
        for pid, person in chosen.items():
            records[pid] = {
                'name': person['name'],
                'aliases': sorted((person.get('aliases', set()) | person.get('weak', set())) - {person['name']})[:6],
                'tagline': (person.get('tagline') or person.get('intro') or '')[:120],
                'bio': (person.get('bio') or '')[:520],
                'known_relations': relation_rows[pid][:8],
                'recent_events': [text for text in events[pid][-6:] if text],
            }
        return {'story': (kg.saga or '')[:1800], 'recent_events': list(kg.recent[-12:]), 'people': records}

    def relation_context(self, i: int, data: dict, memory: dict | None) -> dict:
        memory = memory or {}
        known = memory.get('people') or {}
        characters = {}
        for person in data.get('people', []):
            lid = str(person.get('id'))
            row = {'name_in_this_passage': (person.get('name') or '').lstrip('*'),
                   'description_in_this_passage': person.get('role') or ''}
            prior = known.get(str(person.get('known')))
            if prior:
                row['known_before'] = prior
            elif person.get('known_name'):
                row['known_before'] = {'name': person['known_name']}
            characters[lid] = row
        story = memory.get('story') or ''
        recent = [x for x in memory.get('recent_events', []) if x]
        if recent:
            story += ('\n' if story else '') + '最近事件：' + '；'.join(recent)
        previous = ''
        if i:
            scope = self.scope_start(self.segs[i]['o0'])
            if self.segs[i - 1]['o0'] >= scope:
                previous = seg_text(self.book, self.segs[i - 1])[-1600:]
        return {'story_before_this_passage': story[:2600], 'previous_passage_tail': previous,
                'character_context': characters}

    def support_items(self, data: dict, *, sample_events: bool = True, checked_events=()) -> dict:
        """The records worth checking against the passage, named the way this segment names people.

        Measured pass rates: events 99%, attributes 98%, relations 91%. Checking every event spends
        three quarters of the judge's budget confirming what is already right, so events are checked
        when they claim something risky (a death, a marriage, who did it) and otherwise sampled.
        """
        name = {str(p.get('id')): (p.get('name') or '').lstrip('*') for p in data.get('people', [])}
        rate = int(os.environ.get('EVENT_CHECK_ONE_IN', '6'))
        items = {}
        for j, e in enumerate(data.get('events', [])):
            text = e.get('text') or ''
            if not text:
                continue
            risky = bool(CRITICAL.search(text)) or e.get('imp', 1) >= 3
            sampled = sample_events and (rate <= 1 or
                       int.from_bytes(hashlib.sha256(text.encode()).digest()[:8], 'big') % rate == 0)
            if risky or sampled or f'e{j}' in checked_events:
                items[f'e{j}'] = ('event', text)
        for j, a in enumerate(data.get('facts', [])):
            if a.get('value'):
                items[f'a{j}'] = ('attr', f"{name.get(str(a.get('who')), '?')}｜{a.get('key')}：{a['value']}")
        for j, r in enumerate(data.get('rels', [])):
            if r.get('b_is') and r.get('by') != 'judge':      # the judge chose these already
                items[f'r{j}'] = ('rel', f"{name.get(str(r.get('b')), '?')} 是 {name.get(str(r.get('a')), '?')} 的{r['b_is']}")
        return items

    @staticmethod
    def _valid_support(answer) -> bool:
        choices = {'supported', 'not_in_passage', 'contradicted'}
        if not isinstance(answer, dict) or answer.get('choice') not in choices:
            return False
        probs, p = answer.get('probs'), answer.get('p')
        valid = lambda v: isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and 0 <= v <= 1
        return (valid(p) and isinstance(probs, dict) and answer['choice'] in probs
                and all(k in choices and valid(v) for k, v in probs.items()))

    def _pending_support(self, rec: dict, i: int) -> tuple[dict, dict]:
        """Keep unchanged checks; key positions alone cannot identify a rewritten claim.

        Legacy records retain their original sampled events. Their unmodified answers can
        be adopted once, but an old relation marked fixed_by was worded *after* its old
        support check and must be checked again. Fresh records use stable event sampling.
        """
        if 'support_sampling' not in rec:
            rec['support_sampling'] = 'sha256-v1' if rec.get('support') is None else 'legacy'
        support = rec.get('support') if isinstance(rec.get('support'), dict) else {}
        rec['support'] = support
        fingerprints = rec.get('support_fingerprints')
        if not isinstance(fingerprints, dict):
            fingerprints = rec['support_fingerprints'] = {}
        items = self.support_items(rec['data'], sample_events=rec['support_sampling'] != 'legacy',
                                   checked_events=support)
        questions = record_questions(items)
        text = seg_text(self.book, self.segs[i])[:12000]
        wanted = {key: hashlib.sha256(json.dumps(
            [text, questions[f'v_{key}']], ensure_ascii=False, sort_keys=True).encode()).hexdigest()
                  for key in items}
        # Removed or judge-only relations must not retain an indexed answer that could
        # later be mistaken for a different record at that position.
        for key in set(support) | set(fingerprints):
            if key not in items:
                support.pop(key, None)
                fingerprints.pop(key, None)
        pending = {}
        for key, item in items.items():
            valid = self._valid_support(support.get(key))
            if valid and fingerprints.get(key) == wanted[key]:
                continue
            legacy_rewrite = key.startswith('r') and rec['data']['rels'][int(key[1:])].get('fixed_by')
            if valid and key not in fingerprints and not legacy_rewrite:
                fingerprints[key] = wanted[key]
                adopted = rec.setdefault('support_legacy_adopted', [])
                if key not in adopted:
                    adopted.append(key)
                continue
            support.pop(key, None)
            fingerprints.pop(key, None)
            pending[key] = item
        if pending:
            rec['support_pending'] = sorted(pending)
        else:
            rec.pop('support_pending', None)
        return pending, wanted

    def _merge_support(self, rec: dict, items: dict, fingerprints: dict, answers: dict):
        """Partial judge responses retain their valid answers, never fabricate success."""
        missing = []
        for key in items:
            answer = answers.get(key) if isinstance(answers, dict) else None
            if self._valid_support(answer):
                rec['support'][key] = answer
                rec['support_fingerprints'][key] = fingerprints[key]
            else:
                missing.append(key)
        if missing:
            rec['support_pending'] = sorted(missing)
            raise LLMError('裁判缺少有效的核对结果：' + ','.join(missing))
        rec.pop('support_pending', None)
        rec.pop('support_error', None)

    def name_relations(self, i: int, model: str, pairs: list, names: dict, text: str) -> dict:
        """The judge said these two are related but none of its labels fit — let the model write it.

        Only this rare case costs an LLM call, and the answer must quote the passage verbatim."""
        rows = '\n'.join(f"{n}. A={names.get(a, a)}｜B={names.get(b, b)}" for n, (a, b) in enumerate(pairs, 1))
        try:
            data, u = chat_json(model, [{'role': 'user', 'content': RELATION_WORDS.format(
                title=self.book['title'], text=text[:12000], pairs=rows)}], max_tokens=600 * scale(self.book), temperature=0.2)
            with self.lock:
                self.count(model, u)
        except Exception as e:
            log(f'relation wording failed for segment {i}: {type(e).__name__}: {e}')
            return {}
        flat = re.sub(r'\s+', '', text)
        out = {}
        for n, (a, b) in enumerate(pairs, 1):
            x = (data or {}).get(str(n)) or {}
            quote = re.sub(r'\s+', '', str(x.get('quote') or ''))
            if isinstance(x, dict) and x.get('b_is') and quote and quote in flat:
                out[(a, b)] = x
        return out

    def add_relations(self, rec: dict, i: int, model: str = '') -> dict:
        """Relations the judge can see: code lists the people a segment shows together, the judge
        says what they are to each other (a closed list). Adds pairs the model missed and replaces
        labels that read like prompt text. Runs in the parallel worker."""
        if os.environ.get('JUDGE_RELATIONS', '1') != '1':
            return rec
        if rec.get('judge_rels') is not None and rec.get('relation_judge_revision') == RELATION_JUDGE_REVISION:
            return rec
        data = rec['data']
        names = {str(p.get('id')): (p.get('name') or '').lstrip('*') for p in data.get('people', [])}
        seen, pairs, where = set(), [], {}
        for e in data.get('events', []):
            who = [w for w in dict.fromkeys(e.get('who') or []) if w in names]
            for x in range(len(who)):
                for y in range(x + 1, len(who)):
                    k = (who[x], who[y])
                    if k not in seen and (k[1], k[0]) not in seen:
                        seen.add(k)
                        pairs.append(k)
                        where[k] = (e.get('para'), e.get('quote'))   # anchor it where they appear together
        pairs = pairs[:12]
        if not pairs:
            rec['judge_rels'] = {}
            rec['relation_judge_revision'] = RELATION_JUDGE_REVISION
            return rec
        lang = 'en' if card_lang(self.book) == 'en' else 'zh'
        kind = 'concept' if self.book.get('genre') in ('nonfiction', 'reference') else 'novel'
        inverse = trees(kind)[2]
        try:
            text = seg_text(self.book, self.segs[i])[:12000]
            items, fingerprints = self._pending_support(rec, i)
            context = rec.get('relation_context') or {}
            support, fam = check_and_families(text, items, pairs, names, kind, context)
            if items:
                self._merge_support(rec, items, fingerprints, support)
            got = relations_by_judge(text, pairs, names, fam, kind, context)
            with self.lock:
                self.usage['jev_calls'] += 3 * ((len(pairs) + len(items) + 47) // 48)
        except Exception as e:
            log(f'relation check failed for segment {i}: {type(e).__name__}: {e}')
            rec['relation_check_error'] = f'{type(e).__name__}: {e}'[:300]
            wjson(self.local_path(i), rec)
            raise
        have = {tuple(sorted((str(r.get('a')), str(r.get('b'))))): r for r in data.get('rels', [])}
        added = 0
        # "there is a tie here, but none of the roles fits": only then does a model write the words
        other = [k for k, v in got.items() if any(t['role'] == 'other' for t in v['ties']) and tuple(sorted(k)) not in have]
        worded = self.name_relations(i, model or LOCAL_MODEL, other, names, seg_text(self.book, self.segs[i])) if other else {}
        for (a, b), v in got.items():
            ties = [t for t in v['ties'] if t['role'] != 'other']
            facets = [label(v[f][0], lang) for f in ('state', 'stance')
                      if v.get(f) and v[f][0] not in ('current', 'neutral')]
            note = ('；' if lang != 'en' else '; ').join(facets + [label(t['role'], lang) for t in ties[1:]])
            ended = (v.get('state') or ('', 0))[0] == 'former'
            x = worded.get((a, b))
            r = have.get(tuple(sorted((a, b))))
            para, quote = where.get((a, b), (None, ''))
            if r is not None:
                # a label that reads like prompt text or a whole sentence is replaced by the chosen role
                lab = str(r.get('b_is') or '')
                other = names.get(a, '') + names.get(b, '')
                # a whole clause, a prompt echo, or a phrase containing the other person's name is
                # a description, not a role — the judge's word is better
                same = str(r.get('a')) == a
                expected_b = label(ties[0]['role'] if same else inverse[ties[0]['role']], lang) if ties else ''
                expected_a = label(inverse[ties[0]['role']] if same else ties[0]['role'], lang) if ties else ''
                canonical = {label(role, lang) for table in trees(kind)[1].values() for role in table}
                confident_conflict = bool(ties and ties[0]['p'] >= .85 and lab in canonical and lab != expected_b)
                bad = (not lab or len(lab) > (14 if lang != 'en' else 40) or '而言' in lab or re.match(r'^[abAB]\s*的', lab)
                       or (ties and ties[0]['p'] >= 0.7 and len(lab) > (8 if lang != 'en' else 24))
                       or confident_conflict
                       or any(n and len(n) >= 2 and n in lab for n in (names.get(a, ''), names.get(b, ''))))
                if bad and ties:
                    r['b_is'] = expected_b
                    r['a_is'] = expected_a
                    r['fixed_by'] = 'judge'
                if note and not r.get('desc'):
                    r['desc'] = note
            elif x:
                data.setdefault('rels', []).append(
                    {'a': a, 'b': b, 'b_is': str(x['b_is'])[:14], 'a_is': str(x.get('a_is') or '')[:14],
                     'desc': str(x.get('desc') or note)[:40], 'para': para, 'quote': x.get('quote') or quote, 'by': 'judge+llm'})
                added += 1
            elif ties:
                t = ties[0]
                data.setdefault('rels', []).append(
                    {'a': a, 'b': b, 'b_is': label(t['role'], lang), 'a_is': label(inverse[t['role']], lang),
                     'desc': note, 'para': para, 'quote': quote, 'by': 'judge', 'p': t['p'],
                     'status': 'ended' if ended else 'new'})
                added += 1
        rec['judge_rels'] = {f'{a}|{b}': v for (a, b), v in got.items()}
        rec['relation_judge_revision'] = RELATION_JUDGE_REVISION
        rec['judge_rels_added'] = added
        rec.pop('relation_check_error', None)
        # Added judge+LLM wording and replacements of an old model label have new
        # support questions. Invalidate only those keys before exposing this cache.
        self._pending_support(rec, i)
        wjson(self.local_path(i), rec)
        return rec

    def add_support(self, rec: dict, i: int) -> dict:
        """Ask the judge whether this segment's own text supports each record it produced.

        Runs in the parallel phase-1 worker: it needs nothing but the segment, so it costs no
        sequential time. Measured on the dev set: events 99% supported, attributes 98%,
        relations 91% — the low scorers are real errors (reversed roles, wrong person)."""
        if os.environ.get('VERIFY_RECORDS', '1') != '1':
            return rec
        items, fingerprints = self._pending_support(rec, i)
        try:
            if items:
                answers = verify_records(seg_text(self.book, self.segs[i]), items)
                with self.lock:
                    self.usage['jev_calls'] += (len(items) + 47) // 48
                self._merge_support(rec, items, fingerprints, answers)
            rec.pop('support_error', None)
        except Exception as e:
            log(f'support check failed for segment {i}: {type(e).__name__}: {e}')
            rec['support_error'] = f'{type(e).__name__}: {e}'[:300]
            wjson(self.local_path(i), rec)
            raise
        wjson(self.local_path(i), rec)
        return rec

    def _local_job(self, i: int, model: str, hint: str = '', relation_memory: dict | None = None):
        path = self.local_path(i)
        if path.exists():
            rec = json.loads(path.read_text())
            if rec.get('empty'):
                raise LLMError(f'第 {i} 段缓存来自抽取失败，须先隔离失败缓存再重试')
            if rec.get('refused'):
                with self.lock:
                    self.refused.add(i)
                return self.add_support(self.add_relations(rec, i, model), i)
            provenance = rec.get('provenance') or {}
            if provenance and (provenance.get('input_sha256') != getattr(self, 'input_sha256', None)
                               or provenance.get('extractor_revision') != EXTRACTOR_REVISION
                               or rec.get('model') != model):
                raise LLMError('抽取缓存的输入、模型或提示版本已变更；请隔离旧缓存后重建')
            rec['data'] = sanitize(rec['data'])
            if not rec.get('relation_context'):
                rec['relation_context'] = self.relation_context(i, rec['data'], relation_memory)
            return self.add_support(self.add_relations(rec, i, model), i)
        seg = self.segs[i]
        refusals = 0
        for attempt in range(4):
            try:
                t0 = time.time()
                data, usage = extract_local(self.book, seg, self.segs[i - 1] if i else None, model, hint)
                # remember which name the hinted id stood for (ids are only stable within one run)
                shown = dict(row.split('｜')[:2] for row in hint.splitlines() if row.count('｜') >= 2)
                for lp in data['people']:
                    if lp.get('known') in shown:
                        lp['known_name'] = shown[lp['known']]
                rec = {'seg': i, 'model': model, 'data': data, 'raw': usage.pop('_raw', None), 'hint_size': len(hint),
                       'relation_context': self.relation_context(i, data, relation_memory),
                       'provenance': {'schema': SCHEMA, 'input_sha256': getattr(self, 'input_sha256', None),
                                      'extractor_revision': EXTRACTOR_REVISION},
                       'usage': {'prompt': usage.get('prompt_tokens'), 'completion': usage.get('completion_tokens')},
                       'seconds': round(time.time() - t0, 1)}
                with self.lock:
                    self.count(model, usage)
                wjson(path, rec)
                break
            except Exception as e:
                log(f'local segment {i} failed (attempt {attempt + 1}): {e}')
                if str(e).startswith('REFUSED:'):
                    refusals += 1
                    if refusals >= 2:
                        # The model will not read this passage (usually a provider content filter).
                        # Stopping the whole book here helps no one: record the passage as skipped,
                        # say so in the status, and keep reading the rest.
                        data = sanitize({})
                        rec = {'seg': i, 'model': model, 'data': data, 'refused': str(e)[len('REFUSED:'):].strip(),
                               'relation_context': self.relation_context(i, data, relation_memory),
                               'provenance': {'schema': SCHEMA, 'input_sha256': getattr(self, 'input_sha256', None),
                                              'extractor_revision': EXTRACTOR_REVISION},
                               'usage': {}, 'seconds': 0}
                        wjson(path, rec)
                        with self.lock:
                            self.refused.add(i)
                        break
                    continue
                reason = explain(e)
                if reason:
                    # a missing/invalid key, an empty balance or a wrong model name: retrying only
                    # hides the cause behind a progress bar that never moves
                    raise LLMError(reason) from e
                last_error = e
                self.notify(f'模型请求失败，正在重试（第 {attempt + 1} 次）：{str(e)[:160]}')
                # A model that returned malformed JSON is not asking us to slow down — it just
                # sampled badly, and the next draw is usually fine. Waiting only helps when the
                # other side is rate limiting or down. Measured on 我真没想重生啊: these blind
                # waits turned a 6.8s median segment into a 131s 90th percentile.
                rate_limited = isinstance(e, LLMError) and re.search(r'\b(429|5\d\d)\b|timed out|timeout',
                                                                    str(e), re.I)
                if attempt < 3:
                    time.sleep((15 * (attempt + 1)) if rate_limited else 1.0)
        else:
            # A failed check must not repeat a successful extraction: that cache is already
            # persisted above, and the next attempt resumes only its missing judge work.
            raise LLMError(f'第 {i} 段连续四次请求模型都失败，已暂停：{str(last_error)[:200]}')
        return self.add_support(self.add_relations(rec, i, model), i)

    def link(self, i: int, local_rec: dict) -> dict:
        seg = self.segs[i]
        text = seg_text(self.book, seg)
        t0 = time.time()
        local, dropped = drop_unsupported(local_rec['data'], local_rec.get('support') or {})
        with self.lock:
            data, link_rec = link_segment(self.kg, seg, local, text, self.scope_start(seg['o0']))
        guard = {'checks': {}, 'rewrites': {}}
        try:
            self.verify_critical(data, local_rec['data'], link_rec, text, guard)
        except Exception as e:
            guard['critical_error'] = str(e)[:200]
            wjson(self.work / 'verification' / f'{i:04d}.json',
                  {'state': 'failed', 'stage': 'critical', 'error': str(e)[:300], 'seg': i})
            raise LLMError(f'第 {i} 段关键事实尚未验证，已保留抽取缓存：{e}') from e
        with self.lock:
            plan = self.kg.plan(seg, data)
        intros = {np['ref']: np.get('intro') for np in data['new_people'] if np.get('intro')}
        if intros:
            try:
                v = guard_texts(text, {}, {f'intro:{k}': t for k, t in intros.items()})
                if any(v.get(f'intro:{k}', {}).get('verdict') not in ('ok', 'flag') for k in intros):
                    raise LLMError('人物简介缺少有效验证结果')
                for k, x in v.items():
                    if x['verdict'] == 'flag':
                        ref = k.split(':', 1)[1]
                        guard['rewrites'][k] = intros[ref]
                        for np in data['new_people']:
                            if np['ref'] == ref:
                                np['intro'] = ''
                        data['profiles'] = [pr for pr in data['profiles'] if pr['who'] != ref]
                self.usage['jev_calls'] += 1
            except Exception as e:
                guard['error'] = str(e)[:200]
                wjson(self.work / 'verification' / f'{i:04d}.json',
                      {'state': 'failed', 'stage': 'intro', 'error': str(e)[:300], 'seg': i})
                raise LLMError(f'第 {i} 段人物简介尚未验证：{e}') from e
        try:
            decisions, raw = resolve_mentions(self.book, seg, plan['occs'], self._describe_factory(data, plan))
            self.usage['jev_calls'] += (len([o for o in plan['occs'] if o['ambiguous']]) + 15) // 16
        except Exception as e:
            decisions, raw = {}, {'error': str(e)[:200]}
        rec = {'seg': i, 'o0': seg['o0'], 'o1': seg['o1'], 'mode': 'two-phase', 'model': local_rec.get('model'),
               'provenance': {'schema': SCHEMA, 'input_sha256': getattr(self, 'input_sha256', None)},
               'data': data, 'link': link_rec, 'decisions': decisions, 'jev_raw': raw, 'guard': guard,
               'dropped': dropped,
               'timing': {'local': local_rec.get('seconds'), 'link': round(time.time() - t0, 1)}}
        wjson(self.seg_path(i), rec)
        wjson(self.work / 'verification' / f'{i:04d}.json', {'state': 'complete', 'seg': i})
        return rec

    def verify_critical(self, data: dict, local: dict, link_rec: dict, text: str, guard: dict):
        """Deaths/marriages must be narrated as fact; "A is B" must be established by the passage."""
        # name of each id as this segment calls it (unambiguous within the segment)
        seg_name = {}
        for lp in local.get('people', []):
            d = link_rec['decisions'].get(str(lp.get('id'))) or {}
            seg_name[d.get('to') or f"N{lp.get('id')}"] = lp.get('name') or ''
        nm = lambda x: seg_name.get(x) or (self.kg.people.get(x) or {}).get('name') or str(x)  # noqa: E731
        items = {}
        for i, e in enumerate(data['events']):
            if CRITICAL.search(e.get('text') or ''):
                items[f'e{i}'] = e['text']
        for i, a in enumerate(data['attrs']):
            if str(a.get('key', '')).lower() in LIFE_KEYS or CRITICAL.search(a.get('value') or ''):
                items[f'a{i}'] = f"{nm(a.get('who'))}：{a.get('value')}"
        for i, r in enumerate(data['rels']):
            label = f"{r.get('a_is', '')}{r.get('b_is', '')}"
            if re.search(r'妻|夫|妾|姨娘|二房|wife|husband|spouse|fianc|betrothed|bride|groom', label, re.I):
                items[f'r{i}'] = f"{nm(r.get('b'))}是{nm(r.get('a'))}的{r.get('b_is')}"
        if items:
            v = check_critical(text, items)
            if any(k not in v or not isinstance(v[k].get('fact'), (int, float)) for k in items):
                raise LLMError('关键事实缺少有效验证结果')
            guard['critical'] = v
            self.usage['jev_calls'] += 1
            drop = {k for k, x in v.items() if x['fact'] < 0.5}
            data['events'] = [e for i, e in enumerate(data['events']) if f'e{i}' not in drop]
            data['attrs'] = [a for i, a in enumerate(data['attrs']) if f'a{i}' not in drop]
            data['rels'] = [r for i, r in enumerate(data['rels']) if f'r{i}' not in drop]
        role = {}
        for lp in local.get('people', []):
            d = link_rec['decisions'].get(str(lp.get('id'))) or {}
            role[d.get('to') or f"N{lp.get('id')}"] = lp.get('role') or ''

        def known(x):
            p = self.kg.people.get(x)
            return (p.get('tagline') or p.get('intro') or '') if p else ''
        if data['merges']:
            pairs = {str(i): (nm(m['from']), nm(m['into']), known(m['from']) or role.get(m['from'], ''),
                              known(m['into']) or role.get(m['into'], '')) for i, m in enumerate(data['merges'])}
            v = check_same(text, pairs)
            guard['merges'] = v
            self.usage['jev_calls'] += 1
            data['merges'] = [m for i, m in enumerate(data['merges']) if v.get(str(i), {}).get('same', 0) >= 0.7]

    def mark_titles(self):
        """Flag the chapter titles that give away their own chapter, so the rest stay visible."""
        chapters = self.book['chapters']
        if os.environ.get('JUDGE_TITLES', '1') != '1' or (all('spoil' in c for c in chapters)
                                                      and 'chapter-titles' not in self.quality_pending):
            return
        spoils = title_spoilers([(c.get('parent') + ' · ' if c.get('parent') else '') + c['title'] for c in chapters],
                                self.book.get('title', ''))
        if len(spoils) != len(chapters):
            raise LLMError('章节标题验证结果不完整')
        for c, bad in zip(chapters, spoils):
            c['spoil'] = bool(bad)
        self.usage['jev_calls'] += (len(chapters) + BATCH - 1) // BATCH
        self.quality_pending.discard('chapter-titles')
        wjson(self.root / 'book.json', self.book)
        log(f"chapter titles: {sum(1 for c in chapters if c['spoil'])}/{len(chapters)} give something away")

    def run2(self, limit: int | None = None, concurrency: int = 12, model: str = LOCAL_MODEL):
        """Two-phase run: local extraction in parallel, linking in order (resumable)."""
        if limit != 0 and self.repair_policy.get('identity_taint'):
            raise LLMError('人物关联结果已隔离，请显式重试质量检查后继续处理')
        self.two_phase = True
        try:
            if limit != 0:
                self.mark_titles()
        except Exception as e:
            log(f'title check failed: {type(e).__name__}: {e}')
            for chapter in self.book['chapters']:
                chapter.setdefault('spoil', True)
            self.quality_pending.add('chapter-titles')
            wjson(self.root / 'book.json', self.book)
        done = 0
        self.replaying = True
        for i in range(len(self.segs)):
            self.checkpoint()
            p = self.seg_path(i)
            if not p.exists():
                break
            self.apply(json.loads(p.read_text()))
            self._maybe_recap(i)
            done = i + 1
        self.replaying = False
        if limit != 0:
            self.resume_final_jobs()
            for future in self.pending:
                self.await_future(future)
        finalized = len(self.pending)
        log(f'replayed {done}/{len(self.segs)} segments')
        self.publish()
        self.status('running' if done < len(self.segs) else ('finalizing' if self.pending else 'done'), done)
        end = len(self.segs) if limit is None else min(len(self.segs), done + limit)
        local_pool = ThreadPoolExecutor(concurrency)
        self.local_pool = local_pool
        futures = {}
        next_job = [done]     # next segment to submit (kept apart from the loop variable)

        def submit_upto(k, current):
            self.checkpoint()
            # the cast shown to segment j is the one linked so far (segments < current), never later text
            cap = min(end, k + 1)
            # A future chapter must not receive a hint before the current
            # chapter's biography and recap have settled into the graph.
            for j in range(current + 1, cap):
                if self.segs[j]['chapter'] != self.segs[current]['chapter']:
                    cap = j
                    break
            if next_job[0] >= cap:
                return
            with self.lock:
                hint = self.cast_hint()
                relation_memory = self.relation_memory()
            while next_job[0] < cap:
                futures[next_job[0]] = local_pool.submit(self._local_job, next_job[0], model, hint, relation_memory)
                next_job[0] += 1
        if done < end:
            submit_upto(done + concurrency - 1, done)
            # A slow model can take minutes per passage; say what the 0% is waiting for.
            self.notify(f'已把 {next_job[0] - done} 段发给 {model.split("+")[0]}，正在等它回复；每整理完一段，进度会更新')
        t_start = time.time()
        for i in range(done, end):
            self.checkpoint()
            submit_upto(i + concurrency - 1, i)
            try:
                local_rec = self.await_future(futures[i])
                self.checkpoint()
                rec = self.link(i, local_rec)
                self.checkpoint()
                self.apply(rec)
                self._maybe_recap(i)
                for future in self.pending[finalized:]:
                    self.await_future(future)
                finalized = len(self.pending)
            except Cancelled:
                local_pool.shutdown(wait=False, cancel_futures=True)
                raise
            except Exception as e:
                log(f'segment {i}: {type(e).__name__}: {e}')
                self.status('error', i, error=(str(e) if isinstance(e, LLMError) else f'{type(e).__name__}: {e}')[:300])
                local_pool.shutdown(wait=False, cancel_futures=True)
                raise
            done = i + 1
            if done % 3 == 0 or done == end:
                self.publish()
            self.status('running' if done < len(self.segs) else 'finalizing', done)
            ln = rec['link']['decisions']
            hows = {}
            for d in ln.values():
                hows[d['how']] = hows.get(d['how'], 0) + 1
            log(f"seg {done}/{len(self.segs)} local={local_rec.get('seconds')}s link={rec['timing']['link']}s "
                f"people={len(ln)} {hows} ev={len(rec['data']['events'])} rel={len(rec['data']['rels'])} "
                f"cast={sum(1 for p in self.kg.people.values() if not p.get('merged_into'))} elapsed={round(time.time() - t_start)}s")
        local_pool.shutdown(wait=True)
        for f in self.pending:
            self.await_future(f)
        self.publish()
        if done == len(self.segs) and limit != 0:
            self.finish_quality_retry()
        self.status('running' if done < len(self.segs) else 'done', done)

    def _maybe_recap(self, i: int):
        seg = self.segs[i]
        last = i == len(self.segs) - 1 or self.segs[i + 1]['chapter'] != seg['chapter']
        if last:
            start = min(s['o0'] for s in self.segs if s['chapter'] == seg['chapter'])
            do_bio = seg['o1'] - self.last_bio >= 12000 or i == len(self.segs) - 1
            if do_bio and self.two_phase:
                self.dedupe(seg['chapter'], seg['o1'], self.last_bio)
                for step in (self.rate_importance, self.settle_attrs):
                    try:
                        step(seg['o1'], self.last_bio)
                    except Exception as e:
                        log(f'{step.__name__} failed: {type(e).__name__}: {e}')
            # A newly queued bio can append chapter profile rows immediately.
            # Snapshot the classic recap's profile inputs under the same lock
            # that _apply_bios uses, after applying any existing bio cache.
            with self.lock:
                if do_bio:
                    self.consolidate(seg['chapter'], seg['o1'], self.last_bio)
                    self.last_bio = seg['o1']
                self.recap(seg['chapter'], seg['o1'], start)
            if self.two_phase and (seg['o1'] - self.last_saga >= 30000 or i == len(self.segs) - 1):
                chs = sorted({s['chapter'] for s in self.segs if self.last_saga < s['o1'] <= seg['o1']})
                self.saga(seg['o1'], chs)
                self.last_saga = seg['o1']


def run_book(root: Path, *, model=DEFAULT_MODEL, limit=None, classic=False,
             retry_quality=False, local_model=LOCAL_MODEL, concurrency=12, cancel_event=None):
    """Run the same resumable pipeline from a subprocess or an Android worker thread."""
    import fcntl
    root = Path(root)
    (root / 'work').mkdir(parents=True, exist_ok=True)
    with (root / 'work' / 'run.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            raise AlreadyRunning(f'{root} is already being processed') from exc
        runner = None
        cancelled = False
        try:
            if cancel_event is not None and cancel_event.is_set():
                raise Cancelled()
            runner = Runner(root, model, cancel_event=cancel_event)
            use_classic = classic or (runner.seg_path(0).exists() and json.loads(runner.seg_path(0).read_text()).get('mode') != 'two-phase')
            retry_path = runner.work / 'quality-retry.json'
            if retry_quality or (retry_path.exists() and json.loads(retry_path.read_text()).get('state') == 'archiving'):
                runner.prepare_quality_retry()
            if use_classic:
                runner.run(limit)
            else:
                runner.run2(limit, concurrency, local_model)
            state = json.loads((root / 'status.json').read_text())
            if state['state'] == 'error':
                raise RuntimeError(state.get('error') or '书籍处理失败')
        except Cancelled:
            cancelled = True
            if runner is not None:
                path = root / 'status.json'
                state = json.loads(path.read_text()) if path.exists() else {}
                state.update(state='paused', updated=time.time(), error=None)
                wjson(path, state, compact=False)
            raise
        except Exception as exc:
            path = root / 'status.json'
            state = json.loads(path.read_text()) if path.exists() else {}
            state.update(state='error', error=(str(exc) if isinstance(exc, LLMError) else f'{type(exc).__name__}: {exc}')[:300],
                         notice=None, updated=time.time())
            wjson(path, state, compact=False)
            raise
        finally:
            if runner is not None:
                runner.close(cancelled=cancelled)
            fcntl.flock(lock, fcntl.LOCK_UN)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('root', type=Path)
    ap.add_argument('--model', default=DEFAULT_MODEL)
    ap.add_argument('--limit', type=int)
    ap.add_argument('--two-phase', action='store_true', default=os.environ.get('PIPELINE_MODE', 'two') == 'two')
    ap.add_argument('--classic', action='store_true', help='old sequential mode (used for the first two books)')
    ap.add_argument('--retry-quality', action='store_true', help='archive quarantined derived output and explicitly rebuild it')
    ap.add_argument('--local-model', default=LOCAL_MODEL)
    ap.add_argument('--concurrency', type=int, default=int(os.environ.get('LOCAL_CONCURRENCY', '12')))
    a = ap.parse_args()
    try:
        run_book(a.root, model=a.model, limit=a.limit,
                 classic=a.classic, retry_quality=a.retry_quality,
                 local_model=a.local_model, concurrency=a.concurrency)
    except AlreadyRunning:
        log(f'{a.root} is already being processed by another process; exiting')
        raise SystemExit(75)


if __name__ == '__main__':
    main()
