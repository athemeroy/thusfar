import assert from 'node:assert/strict';
import { HUB_LIMITS, NotebookHubLoader, filterHubNotes, mergeHubNotes, validateHubQuote } from '../web/js/notebook-hub.js';

const note = (id, extra = {}) => ({ id, kind: 'note', start: 2, end: 3, quote: '甲', text: '最初的想法', revision: 1, updated: 10, ...extra });
const dirty = note('note-local', { dirty: true, text: '本机仍待同步', operation: 'op-local' });
const local = [dirty, note('note-deleted', { dirty: true, deleted: true })];
const remote = [note('note-local', { revision: 9, text: '云端另一版' }), note('note-deleted', { revision: 8 }), note('note-remote', { text: '远端已保存' })];
const localBefore = JSON.stringify(local), remoteBefore = JSON.stringify(remote);
const merged = mergeHubNotes(local, remote);
assert.equal(merged.find((n) => n.id === dirty.id).text, '本机仍待同步');
assert.ok(!merged.some((n) => n.id === 'note-deleted'), 'a pending deletion must not be resurrected');
assert.equal(JSON.stringify(local), localBefore); assert.equal(JSON.stringify(remote), remoteBefore);
assert.throws(() => mergeHubNotes([], [{...note('bad-note'), start:-1}]), /格式/);

const states = [{ book: { id:'book-a', title:'远山与夜色', author:'作者甲' }, phase:'loaded', notes:merged },
  { book:{id:'book-b',title:'Other Book'}, phase:'unavailable', notes:[note('bookmark-one',{kind:'bookmark',quote:'',text:'',start:0,end:0,updated:20}),note('conflict-one',{conflict:{item:note('conflict-one',{text:'后来理解的秘密'})}})] }];
assert.equal(filterHubNotes(states,{query:'远山 待同步'}).length,1);
assert.equal(filterHubNotes(states,{book:'book-b',kind:'bookmark'}).length,1);
assert.equal(filterHubNotes(states,{sync:'pending'}).length,1);
assert.equal(filterHubNotes(states,{sync:'conflict',query:'后来理解'}).length,1);
assert.equal(filterHubNotes(states,{query:'不存在'}).length,0);

// Controlled responses prove three-way concurrency and partial/unavailable semantics.
let inFlight=0, peak=0, calls=[]; const finishes=new Map();
const books=Array.from({length:7},(_,i)=>({id:`book-${i}`,title:`Book ${i}`}));
books.push({id:'hidden-book',title:'Hidden',hidden:true});
const original=note('local-survives',{dirty:true});
const loader=new NotebookHubLoader({books,readLocal:(b)=>b.id==='book-4'?[original]:[],loadRemote:(id,signal)=>{
  calls.push(id);inFlight++;peak=Math.max(peak,inFlight);
  return new Promise((resolve,reject)=>{
    finishes.set(id,(error)=>{inFlight--;error?reject(error):resolve({items:[note(`remote-${id}`)]});});
    signal.addEventListener('abort',()=>{inFlight--;reject(new DOMException('Cancelled','AbortError'));},{once:true});
  });
}});
const done=loader.start();await new Promise(r=>setTimeout(r,0));assert.equal(calls.length,3);
finishes.get('book-0')();await new Promise(r=>setTimeout(r,0));assert.equal(calls.length,4);
finishes.get('book-1')();finishes.get('book-2')();await new Promise(r=>setTimeout(r,0));
finishes.get('book-3')();finishes.get('book-4')(new Error('这本书没有离线下载'));finishes.get('book-5')();await new Promise(r=>setTimeout(r,0));
finishes.get('book-6')();await done;
assert.equal(peak,HUB_LIMITS.concurrency);assert.ok(!calls.includes('hidden-book'));
assert.equal(loader.states.get('book-4').phase,'unavailable');
assert.equal(loader.states.get('book-4').notes[0].id,original.id);
assert.equal(original.dirty,true);
loader.retry('book-4');await new Promise(r=>setTimeout(r,0));finishes.get('book-4')();await loader.idle();
assert.equal(loader.states.get('book-4').phase,'loaded');assert.ok(loader.states.get('book-4').notes.some(n=>n.id===original.id));
loader.destroy();

let notifications=0, cancelled=0, started=0;
const abort=new AbortController();
const cancellable=new NotebookHubLoader({books,signal:abort.signal,readLocal:()=>[],onChange:()=>notifications++,loadRemote:(_id,signal)=>{
  started++;return new Promise((_resolve,reject)=>signal.addEventListener('abort',()=>{cancelled++;reject(new DOMException('Cancelled','AbortError'));},{once:true}));
}});
const cancelledDone=cancellable.start();await new Promise(r=>setTimeout(r,0));abort.abort();const before=notifications;
await cancelledDone;assert.equal(started,3);assert.equal(cancelled,3);assert.equal(notifications,before,'unmounted hub never renders late responses');

let attempt=0;
const paused=new NotebookHubLoader({books:[books[0]],readLocal:()=>[],loadRemote:(_id,signal)=>{
  attempt++;if(attempt>1)return Promise.resolve({items:[]});return new Promise((_resolve,reject)=>signal.addEventListener('abort',()=>reject(new DOMException('Cancelled','AbortError')),{once:true}));
}});
const pausedDone=paused.start();await new Promise(r=>setTimeout(r,0));paused.pause();await pausedDone;
assert.equal(paused.states.get('book-0').phase,'pending');await paused.start();assert.equal(paused.states.get('book-0').phase,'loaded');paused.destroy();

// A bounded projection must say "partial", including after a local storage event.
const many=Array.from({length:HUB_LIMITS.perBook+3},(_,i)=>note(`large-${i}`,{updated:i}));
const bounded=new NotebookHubLoader({books:[books[0]],readLocal:()=>[],loadRemote:async()=>({items:many})});
await bounded.start();assert.equal(bounded.states.get('book-0').notes.length,HUB_LIMITS.perBook);
assert.equal(bounded.states.get('book-0').partial,true);assert.equal(bounded.states.get('book-0').omitted,3);
bounded.refreshLocal('book-0');assert.equal(bounded.states.get('book-0').partial,true);bounded.destroy();

const chapter={o0:0,o1:10,blocks:[{k:'p',o:0,t:'😀甲后来明白了'}]};
const preview=validateHubQuote(note('source-good'),{len:10},chapter);
assert.equal(preview.parts[0].quote,'甲');
assert.throws(()=>validateHubQuote(note('source-wrong',{quote:'乙'}),{len:10},chapter),/不一致/);
assert.throws(()=>validateHubQuote(note('source-range',{start:9,end:30}),{len:10},chapter),/位置/);
assert.ok(validateHubQuote(note('point-anchor',{kind:'bookmark',start:2,end:2,quote:''}),{len:10},chapter).parts.length);
console.log('notebook hub tests passed: pending preservation, hidden-book allowlist, search/filter, concurrency/cancel/retry, bounded partial states, and UTF-16 source validation');
