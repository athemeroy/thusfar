// Temporal knowledge graph on the client.
//
// The server only ever sends records with p <= the position we ask for, and we only ask
// for the end of the page on screen. world(cutoff) folds every record with p <= cutoff into
// "what the reader knows at this page": people, names, relations, events, recaps.

import { api } from './api.js';
import { personColor } from './util.js';
import { t } from './i18n.js';

const GENERIC = new Set('父亲 母亲 爸爸 妈妈 爹 娘 儿子 女儿 丈夫 妻子 太太 夫人 先生 老爷 小姐 姑娘 少女 女孩 少年 男孩 青年 少爷 医生 大夫 校长 老师 神父 堂长 老板 老板娘 仆人 女仆 老头子 老太太 老头 孩子 哥哥 姐姐 弟弟 妹妹 叔叔 伯父 舅舅 姑妈 姨妈 祖父 祖母 爷爷 奶奶 外公 外婆 公公 婆婆 岳父 岳母 丈人 主人 客人 新娘 新郎 新娘子 新夫人 寡妇 邻居 朋友 同学 学生 病人 大人 老人 年轻人 女人 男人 闺女 媳妇 老婆 老公 东家 女婿 未婚女婿 未婚妻 未婚夫 儿媳'.split(' '));

export class KG {
  constructor(bookId, options = {}) {
    this.id = bookId;
    this.records = [];
    this.loadedTo = -1;
    this.frontier = 0;
    this.state = '';
    this.memo = new Map();
    this.pending = null;
    this.options = options;
    this.requestedTo = -1;
    this.incomplete = false;
  }

  // Make sure every record with p <= to is loaded.
  async ensure(to) {
    if (to <= this.loadedTo) return;
    this.requestedTo = Math.max(this.requestedTo, to);
    if (this.pending) return this.pending;
    this.pending = (async () => {
      do {
      const target = this.requestedTo;
      const from = this.loadedTo;
      let r = await api.kg(this.id, from, target, this.options);
      const validate = (data, expectedFrom) => {
        if (!Array.isArray(data.records) || data.from !== expectedFrom || !Number.isFinite(data.to) || data.to > target || data.to < Math.min(expectedFrom, target)) throw new Error(t('人物资料范围不一致，请刷新重试'));
        let p = expectedFrom;
        for (const x of data.records) { if (!Number.isFinite(x.p) || x.p < p || x.p <= expectedFrom || x.p > data.to) throw new Error(t('人物资料顺序不正确')); p = x.p; }
      };
      validate(r, from);
      if (typeof r.before === 'number' && r.before !== this.records.length) {
        // something was added behind us: start over once
        r = await api.kg(this.id, -1, target, this.options);
        validate(r, -1);
        this.records = [];
      }
      this.records.push(...r.records.filter((x) => x.p > (this.records.length ? from : -1)));
      this.frontier = r.frontier || 0;
      this.state = r.state || '';
      // while the AI is still reading, positions beyond its frontier may still receive records
      this.loadedTo = this.state === 'done' ? r.to : Math.min(r.to, this.frontier);
      this.incomplete = !!r.incomplete || this.loadedTo < target;
      this.memo.clear();
      if (this.incomplete || this.requestedTo <= this.loadedTo) break;
      } while (!this.options.signal?.aborted);
    })().finally(() => { this.pending = null; });
    await this.pending;
  }

  invalidate() {
    this.records = [];
    this.loadedTo = -1;
    this.requestedTo = -1;
    this.memo.clear();
  }

  world(cutoff) {
    const key = cutoff;
    if (this.memo.has(key)) return this.memo.get(key);
    const w = fold(this.records, cutoff);
    w.frontier = this.frontier;
    w.state = this.state;
    if (this.memo.size > 40) this.memo.clear();
    this.memo.set(key, w);
    return w;
  }
}

export function fold(records, cutoff) {
  const people = new Map();
  const merges = new Map();
  const relationRecords = [];
  const events = [];
  const recaps = [];
  let saga = null;

  const early = new Map();   // records that arrived just before their person entered
  const hold = (r) => { if (!early.has(r.id)) early.set(r.id, []); early.get(r.id).push(r); };
  const apply = (r) => {
    switch (r.t) {
      case 'person':
        people.set(r.id, {
          id: r.id, name: r.name, firstName: r.name, aliases: [], gender: r.gender, imp: r.imp || 1, intro: r.intro || '',
          tagline: r.intro || '', bio: '', bioP: null, chk: null, attrs: {}, events: [], n: 0,
          first: r.s ?? r.p, color: personColor(r.id), merged: [], trail: r.intro ? [{ p: r.p, t: r.intro }] : [],
          manual: !!r.manual, entityKind: r.entity_kind || 'person',
        });
        break;
      case 'name': {
        const p = people.get(r.id);
        if (!p) { hold(r); break; }
        if (p.name !== r.name) { p.aliases.push(p.name); p.name = r.name; }
        break;
      }
      case 'alias': {
        const p = people.get(r.id);
        if (p) p.aliases.push(r.alias); else hold(r);
        break;
      }
      case 'merge':
        merges.set(r.from, { into: r.into, p: r.p, s: r.s, reason: r.reason });
        break;
      case 'profile': {
        const p = people.get(r.id);
        if (!p) hold(r);
        if (p) {
          if (r.tagline) {
            p.tagline = r.tagline;
            const last = p.trail[p.trail.length - 1];
            if (last && r.p - last.p < 600 && p.trail.length > 1) { last.t = r.tagline; last.p = r.p; }   // same scene: keep the newer wording
            else if (!last || last.t !== r.tagline) p.trail.push({ p: r.p, t: r.tagline });
          }
          if (r.bio || r.manual) { p.bio = r.bio || ''; p.bioP = r.p; p.chk = r.chk || null; }
        }
        break;
      }
      case 'attr': {
        const p = people.get(r.id);
        if (p) (p.attrs[r.key] ||= []).push({ v: r.value, p: r.p, s: r.s }); else hold(r);
        break;
      }
      case 'rel': {
        relationRecords.push(r);
        break;
      }
      // (the label shown is chosen from the whole history below, not from the last record)
      case 'event': events.push({ ...r, who: [...r.who] }); break;
      case 'imp': { const p = people.get(r.id); if (p) p.imp = r.imp; break; }
      case 'cnt':
        for (const [id, n] of Object.entries(r.c)) { const p = people.get(id); if (p) p.n += n; }
        break;
      case 'recap': recaps.push(r); break;
      case 'saga': saga = r; break;
    }
    if (r.t === 'person' && early.has(r.id)) { const q = early.get(r.id); early.delete(r.id); q.forEach(apply); }
  };
  for (const r of records) {
    if (r.p > cutoff) break;
    apply(r);
  }

  const canon = (id) => {
    if (!merges.has(id)) return id;   // the common case; called for every event and relation
    const seen = new Set();
    while (merges.has(id) && !seen.has(id)) { seen.add(id); id = merges.get(id).into; }
    return id;
  };
  // fold merged records into the identity the reader now knows
  for (const [from, m] of merges) {
    const to = canon(from);
    const a = people.get(from), b = people.get(to);
    if (!a || !b || a === b) continue;
    const oldName = b.name;
    if (GENERIC.has(b.name) && !GENERIC.has(a.name)) b.name = a.name;
    b.aliases.push(a.name, ...a.aliases);
    b.n += a.n;
    b.first = Math.min(b.first, a.first);
    for (const [k, v] of Object.entries(a.attrs)) b.attrs[k] = [...v, ...(b.attrs[k] || [])].sort((x, y) => x.p - y.p);
    b.merged.push({ name: b.name !== oldName ? oldName : a.firstName || a.name,
      p: m.p, s: m.s, reason: m.reason });
    if (!b.bio && a.bio) { b.bio = a.bio; b.bioP = a.bioP; }
    people.delete(from);
  }
  const names = new Map();
  for (const p of people.values()) names.set(p.name, p.id);
  for (const p of people.values()) {
    // show real names and nicknames, not kinship words, couples, descriptions or someone else's name
    p.aliases = [...new Set(p.aliases)].filter((x) => x && x !== p.name && !GENERIC.has(x) && !GENERIC.has(x.replace(/^[他她的老小未]+/, ''))
      && !/的|夫妇|夫妻|们|一家|俩/.test(x) && !(names.has(x) && names.get(x) !== p.id));
  }
  for (const e of events) {
    const who = [...new Set(e.who.map(canon))].filter((id) => people.has(id));
    e.whoC = who;
    for (const id of who) people.get(id).events.push(e);
  }
  const relList = [];
  const seen = new Map();
  for (const r of relationRecords) {
    const a = canon(r.a), b = canon(r.b);
    if (a === b || !people.has(a) || !people.has(b)) continue;
    const ids = [a, b].sort();
    const k = [...ids, r.family || ''].join('|');
    const x = a === ids[0] ? { ...r, a, b } : { ...r, a: b, b: a, a_is: r.b_is, b_is: r.a_is };
    const prev = seen.get(k);
    // one history array per pair, appended in place: copying it per record was quadratic
    // (a main pair can have hundreds of records) and made late-book page turns slow
    const history = prev ? prev.history : [];
    if (prev) history.push({ ...prev, history: undefined, also: undefined });
    const latest = { ...prev, ...x, history };
    for (const field of ['a_is', 'b_is', 'desc', 'status']) if (!x[field] && prev?.[field]) latest[field] = prev[field];
    latest.times = history.length + 1;
    seen.set(k, latest);
  }
  for (const r of seen.values()) r.also = [...new Set(r.history.map((old) => old.b_is).filter((v) => v && v !== r.b_is))];
  relList.push(...seen.values());
  return {
    cutoff, people, canon, rels: relList, events, recaps, saga,
    relsOf(id) {
      id = canon(id);
      return relList.filter((r) => r.a === id || r.b === id).map((r) => {
        const mine = r.a === id;
        return { other: mine ? r.b : r.a, role: mine ? r.b_is : r.a_is, myRole: mine ? r.a_is : r.b_is, desc: r.desc,
          status: r.status, p: r.p, s: r.s, history: r.history,
          also: [...new Set((r.history || []).map((old) => mine ? old.b_is : old.a_is).filter((v) => v && v !== (mine ? r.b_is : r.a_is)))], times: r.times || 1 };
      }).sort((x, y) => (y.status !== 'ended') - (x.status !== 'ended') || y.p - x.p);
    },
    ranked() {
      return [...people.values()].sort((a, b) => (b.n + b.imp * 8 + b.events.length * 2) - (a.n + a.imp * 8 + a.events.length * 2));
    },
  };
}
