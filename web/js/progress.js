import { canReachLibrary } from './runtime.js';
// Persist the current anchor immediately; synchronize conditional, coalesced writes.
import { api, ConflictError } from './api.js';
import { store } from './util.js';
const active = new Map();
let syncing = false;
// A lost acknowledgement can turn a successful conditional PUT into a 409 on retry.
// The returned server snapshot is the receipt when it has the exact submitted anchor.
function matchesSubmitted(remote, local) {
  return remote && local && remote.pos === local.pos &&
    (remote.cutoff ?? remote.pos) === (local.cutoff ?? local.pos);
}
export async function retryOutbox() {
  if (syncing || !canReachLibrary()) return;
  syncing = true;
  try {
    for (const key of Object.keys(localStorage).filter((k) => k.startsWith('resume:'))) {
      const id = key.slice(7), local = store.get(key, null);
      if (active.has(id) || !local?.dirty || local.conflict) continue;
      try {
        const result = await api.progress(id, local.pos, local.pct, { cutoff: local.cutoff ?? local.pos, expected_t: local.base, updatedAt: local.updatedAt, timeout: 12000 });
        const latest = store.get(key, null);
        if (latest && (latest.revision || latest.updatedAt) === (local.revision || local.updatedAt)) store.set(key, { ...local, dirty: false, base: result.progress?.t ?? local.base });
      } catch (e) {
        const latest = store.get(key, null);
        if (!(e instanceof ConflictError) || !latest || (latest.revision || latest.updatedAt) !== (local.revision || local.updatedAt)) continue;
        const remote = e.data?.progress;
        store.set(key, matchesSubmitted(remote, local)
          ? { ...local, dirty: false, base: remote.t, conflict: null }
          : { ...local, conflict: remote });
      }
    }
  } finally { syncing = false; }
}
export class Progress {
  constructor(id, server, onState = () => {}) {
    this.id = id; this.onState = onState; this.base = server?.t ?? null;
    this.local = store.get(`resume:${id}`, null);
    if (!this.local?.dirty && (server?.t || 0) * 1000 > (this.local?.updatedAt || 0)) this.local = null;
    if (this.local?.dirty) this.base = this.local.base ?? this.base;
    this.server = server; this.conflict = this.local?.conflict || null; this.pending = null; this.stopped = false;
    this.owner = `${Date.now()}-${Math.random()}`; this.sequence = 0;
    active.set(id, this);
    this.online = () => this.flush(); this.hide = () => { if (document.hidden) this.flush(true); };
    addEventListener('online', this.online); addEventListener('pagehide', this.online); document.addEventListener('visibilitychange', this.hide);
    this.startTimer = setTimeout(() => this.flush(), 0);
  }
  get pos() { return this.local?.pos ?? this.server?.pos; }
  save(pos, pct, cutoff = pos) {
    if (this.local?.pos === pos && this.local?.pct === pct && this.local?.cutoff === cutoff) return;
    this.local = { pos, pct, cutoff, updatedAt: Date.now(), revision: `${this.owner}:${++this.sequence}`, base: this.base, dirty: true, ...(this.conflict ? { conflict: this.conflict } : {}) };
    this.storageError = !store.set(`resume:${this.id}`, this.local); clearTimeout(this.timer); this.timer = setTimeout(() => this.flush(), 1000);
  }
  async flush(keepalive = false) {
    if (!this.local?.dirty || this.pending || this.conflict || !canReachLibrary()) { if (!this.stopped) this.onState(this); return; }
    const key = `resume:${this.id}`;
    const same = (a, b) => a && b && (a.revision || a.updatedAt) === (b.revision || b.updatedAt);
    const durable = store.get(key, null);
    if (same(durable, this.local)) this.base = this.local.base = durable.base;
    const current = this.local;
    const sentBase = this.base;
    this.pending = api.progress(this.id, current.pos, current.pct, { cutoff: current.cutoff ?? current.pos, expected_t: this.base, updatedAt: current.updatedAt, keepalive, timeout: 12000 });
    let acknowledged = null;
    try { acknowledged = (await this.pending).progress; }
    catch (e) {
      if (e instanceof ConflictError) {
        const remote = e.data?.progress;
        if (matchesSubmitted(remote, current)) acknowledged = remote;
        else { this.conflict = remote; this.local.conflict = this.conflict; if (same(store.get(key, null), this.local)) store.set(key, this.local); }
      }
    }
    if (acknowledged) {
      this.base = acknowledged.t ?? this.base; this.server = acknowledged;
      if (this.local === current) this.local = { ...current, base: this.base, dirty: false }; else this.local.base = this.base;
      const latest = store.get(key, null);
      if (same(latest, this.local)) store.set(key, this.local);
      else if (latest?.dirty && latest.base === sentBase) store.set(key, { ...latest, base: this.base });
    }
    this.pending = null; if (!this.stopped) this.onState(this);
    if (!this.stopped && this.local?.dirty && this.local !== current && !this.conflict) this.flush();
  }
  useLocal() { this.base = this.conflict?.t ?? null; this.conflict = null; if (this.local) { delete this.local.conflict; this.local.dirty = true; this.local.base = this.base; store.set(`resume:${this.id}`, this.local); } return this.flush(); }
  useServer() {
    if (!this.conflict) return null;
    const remote = this.conflict; this.base = remote.t; this.conflict = null;
    this.local = { pos: remote.pos, pct: remote.pct, cutoff: remote.cutoff ?? remote.pos, updatedAt: (remote.t || 0) * 1000, base: remote.t, dirty: false };
    store.set(`resume:${this.id}`, this.local); this.onState(this); return remote.pos;
  }
  destroy() { this.stopped = true; if (active.get(this.id) === this) active.delete(this.id); clearTimeout(this.startTimer); clearTimeout(this.timer); this.flush(true); removeEventListener('online', this.online); removeEventListener('pagehide', this.online); document.removeEventListener('visibilitychange', this.hide); }
}
