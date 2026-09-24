import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fold, KG } from '../web/js/kg.js';
import { api, ConflictError } from '../web/js/api.js';
import { pronounSpan } from '../web/js/text.js';
import { Progress, retryOutbox } from '../web/js/progress.js';
import { aiState } from '../web/js/shelf.js';
import { attributeLabel } from '../web/js/person.js';
import { qualityPending } from '../web/js/util.js';
const fixtures = JSON.parse(fs.readFileSync(new URL('./temporal-fixtures.json', import.meta.url)));
for (const test of fixtures.cases) {
  const actual = fold(test.records, test.cutoff).rels;
  assert.equal(actual.length, test.expected_rels.length, test.name);
  test.expected_rels.forEach((expected, i) => { for (const [k, v] of Object.entries(expected)) assert.equal(actual[i][k], v, `${test.name}:${k}`); });
}
for (const [text, offset, expected] of [['张三说他会来', 3, { start:3,end:4,text:'他' }], ['张三说他们会来',4,{start:3,end:5,text:'他们'}], ['😀她来了',2,{start:2,end:3,text:'她'}], ['Then she came',6,{start:5,end:8,text:'she'}], ['shelter',2,null]]) assert.deepEqual(pronounSpan(text, offset), expected);
const records = [{t:'person',p:0,id:'P1',name:'A'},{t:'person',p:0,id:'P2',name:'B'},{t:'event',p:1,who:['P1'],text:'event'},{t:'merge',p:10,from:'P1',into:'P2'}];
const early = fold(records,5); fold(records,20); assert.deepEqual(early.events[0].whoC,['P1']);
const original = api.kg;
try {
  let calls=0;
  api.kg=async (_id,from,to)=>{calls++;await new Promise(r=>setTimeout(r,5));return{from,to,records:[],before:0,state:'done',frontier:to};};
  const kg=new KG('fixture'); await Promise.all([kg.ensure(100),kg.ensure(200),kg.ensure(300)]); assert.equal(kg.loadedTo,300);assert.equal(calls,2);
  api.kg=async()=>({from:-1,to:100,records:[],before:0,state:'done',frontier:100,incomplete:true});
  const offline=new KG('fixture');await offline.ensure(300);assert.equal(offline.loadedTo,100);assert.equal(offline.incomplete,true);
  api.kg=async()=>({from:10,to:20,records:[],state:'done'});await assert.rejects(new KG('fixture').ensure(300),/范围/);
} finally {api.kg=original;}
const values = new Map();
globalThis.localStorage = { getItem: (k) => values.get(k) ?? null, setItem: (k,v) => values.set(k,v) };
const navDescriptor = Object.getOwnPropertyDescriptor(globalThis, 'navigator');
Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { onLine: false } });
globalThis.addEventListener = globalThis.removeEventListener = () => {};
globalThis.document = { addEventListener() {}, removeEventListener() {}, hidden: false };
const progress = new Progress('fixture', {pos:100,t:1,pct:1});
progress.save(200,2); progress.save(30,.3); progress.destroy();
const resumed = new Progress('fixture', {pos:100,t:1,pct:1});
assert.equal(resumed.pos,30); assert.equal(resumed.local.dirty,true);
localStorage.setItem = () => {throw new Error('quota')}; resumed.save(40,.4); assert.equal(resumed.storageError,true); resumed.destroy();
localStorage.setItem = (k,v) => values.set(k,v);
values.clear(); navigator.onLine = true;
const originalProgress = api.progress;
try {
  let complete;
  api.progress = () => new Promise((resolve) => {complete=resolve;});
  const old = new Progress('race', {pos:0,pct:0,t:1}); old.save(100,10,120);
  const request = old.flush(); old.destroy();
  const fresh = new Progress('race', {pos:0,pct:0,t:1}); fresh.save(30,3,50);
  complete({ok:true,progress:{pos:100,pct:10,t:2}}); await request;
  const durable = JSON.parse(values.get('resume:race'));
  assert.equal(durable.pos,30,'old reader completion cannot overwrite newer rewind');
  assert.equal(durable.cutoff,50);
  assert.equal(durable.dirty,true); assert.equal(durable.base,2);
  navigator.onLine=false; fresh.destroy();
} finally {api.progress=originalProgress;}
navigator.onLine = true;
try {
  api.progress = async (_id, pos, _pct, { cutoff }) => { throw new ConflictError('进度冲突', { progress: { pos, cutoff, t: 7 } }); };
  const replay = new Progress('lost-receipt', { pos: 0, cutoff: 0, t: 1 });
  replay.save(80, 8, 100);
  await replay.flush();
  assert.equal(replay.conflict, null, 'a lost acknowledgement of our own write is not a cross-device conflict');
  assert.equal(replay.local.dirty, false);
  assert.equal(JSON.parse(values.get('resume:lost-receipt')).base, 7);
  replay.destroy();

  let rejectFirst, secondSent, calls = 0;
  api.progress = async (_id, pos, _pct, options) => {
    if (++calls === 1) return new Promise((_, reject) => { rejectFirst = reject; });
    secondSent = { pos, base: options.expected_t };
    return { progress: { pos, cutoff: options.cutoff, t: 8 } };
  };
  const newer = new Progress('lost-then-rewind', { pos: 0, cutoff: 0, t: 1 });
  newer.save(80, 8, 100);
  const firstWrite = newer.flush();
  newer.save(30, 3, 50);
  rejectFirst(new ConflictError('进度冲突', { progress: { pos: 80, cutoff: 100, t: 7 } }));
  await firstWrite;
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(secondSent, { pos: 30, base: 7 }, 'a newer rewind retries from the acknowledged revision');
  assert.equal(JSON.parse(values.get('resume:lost-then-rewind')).dirty, false);
  newer.destroy();

  api.progress = async () => { throw new ConflictError('进度冲突', { progress: { pos: 80, cutoff: 101, t: 8 } }); };
  const changed = new Progress('actual-conflict', { pos: 0, cutoff: 0, t: 1 });
  changed.save(80, 8, 100);
  await changed.flush();
  assert.equal(changed.conflict.cutoff, 101, 'a different cutoff still needs an explicit choice');
  assert.equal(changed.local.dirty, true);
  changed.destroy();

  const outboxKey = 'resume:outbox-receipt';
  localStorage[outboxKey] = true; // Object.keys(localStorage) models the browser Storage key enumeration.
  values.set(outboxKey, JSON.stringify({ pos: 40, cutoff: 50, pct: 5, base: 1, revision: 'saved-1', dirty: true }));
  api.progress = async () => { throw new ConflictError('进度冲突', { progress: { pos: 40, cutoff: 50, t: 9 } }); };
  await retryOutbox();
  assert.equal(JSON.parse(values.get(outboxKey)).dirty, false, 'reloaded outbox also reconciles its own acknowledged write');
  assert.equal(JSON.parse(values.get(outboxKey)).base, 9);
  delete localStorage[outboxKey];
} finally {api.progress=originalProgress;}
const lastPage=new Progress('last-page',{pos:0,pct:0,t:1});lastPage.save(950,100,1000);
assert.equal(lastPage.pos,950);assert.equal(lastPage.local.cutoff,1000);assert.equal(lastPage.local.pct,100);lastPage.destroy();
for (const quality of [{state:'pending',pending:['internal-job-key']},{state:'verified',pending:['unfinished-job']}]) {
  assert.equal(qualityPending({state:'done',quality}),true);
  const label=aiState({state:'done',quality})[1];assert.match(label,/待核对/);assert.doesNotMatch(label,/internal|unfinished/);
}
for (const [key, label] of Object.entries({identity:'身份',occupation:'职业',age:'年龄',residence:'住处',situation:'处境',alive:'生死',appearance:'外貌',personality:'性格'})) assert.equal(attributeLabel(key), label);
assert.equal(attributeLabel('自定义字段'), '自定义字段');
if (navDescriptor) Object.defineProperty(globalThis,'navigator',navDescriptor);
console.log('frontend tests passed: temporal transitions, pronoun UTF-16 spans, immutable folds, serialized KG and exact coverage');
