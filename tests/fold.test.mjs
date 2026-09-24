// node tests/fold.test.mjs — client-side fold: nothing past the cutoff, early records held, merges.
import assert from 'node:assert/strict';
import { fold } from '../web/js/kg.js';

const log = [
  { t: 'person', p: 10, s: 10, id: 'P1', name: '黑衣人', intro: '穿黑斗篷的人', imp: 3 },
  { t: 'attr', p: 12, id: 'P2', key: '职业', value: '掌柜' },          // arrives before P2 enters
  { t: 'person', p: 15, s: 15, id: 'P2', name: '掌柜', intro: '客栈掌柜', imp: 2 },
  { t: 'event', p: 20, s: 18, who: ['P1', 'P2'], text: '黑衣人进客栈', imp: 2 },
  { t: 'person', p: 40, s: 40, id: 'P3', name: '陈明', intro: '失踪多年的人', imp: 3 },
  { t: 'merge', p: 42, s: 40, from: 'P1', into: 'P3', reason: '摘下斗篷' },
  { t: 'alias', p: 43, id: 'P3', alias: '太太' },                      // generic: never shown
  { t: 'profile', p: 50, id: 'P3', tagline: '归来的人', bio: '陈明失踪多年后回来。' },
  { t: 'rel', p: 55, s: 55, a: 'P3', b: 'P2', a_is: '客人', b_is: '掌柜', desc: '旧识', status: 'new' },
];

// before the reveal: the man in black is his own person, 陈明 does not exist yet
let w = fold(log, 30);
assert.equal(w.people.size, 2);
assert.ok(w.people.has('P1') && !w.people.has('P3'));
assert.equal(w.people.get('P2').attrs['职业'][0].v, '掌柜', 'early attr is held until the person enters');
assert.deepEqual(w.people.get('P1').events.map((e) => e.text), ['黑衣人进客栈']);

// after the reveal: one person, known as 陈明, remembering he was the man in black
w = fold(log, 60);
assert.equal(w.canon('P1'), 'P3');
const cm = w.people.get('P3');
assert.ok(!w.people.has('P1'));
assert.ok(cm.aliases.includes('黑衣人'));
assert.ok(!cm.aliases.includes('太太'));
assert.equal(cm.merged[0].name, '黑衣人');
assert.equal(cm.events.length, 1, 'events of the earlier identity follow the merge');
assert.equal(w.relsOf('P3')[0].role, '掌柜');

// the cutoff is absolute: nothing at p > cutoff leaks in
for (let cut = 0; cut <= 60; cut++) {
  const x = fold(log, cut);
  for (const p of x.people.values()) assert.ok(p.first <= cut);
  for (const e of x.events) assert.ok(e.p <= cut);
  if (cut < 50) assert.equal(x.people.get('P3')?.bio || '', '');
}
console.log('fold tests ok');

// A reveal may be merged in the reverse direction: the generic id survives,
// but its visible name must become the newly learned real name only afterward.
const reveal = [
  { t: 'person', p: 10, id: 'P10', name: '少女' },
  { t: 'person', p: 30, id: 'P11', name: '丛雨' },
  { t: 'merge', p: 35, from: 'P11', into: 'P10', reason: '原文点名' },
];
assert.equal(fold(reveal, 29).people.get('P10').name, '少女');
assert.equal(fold(reveal, 34).people.get('P10').name, '少女');
const revealed = fold(reveal, 35).people.get('P10');
assert.equal(revealed.name, '丛雨');
assert.ok(!revealed.aliases.includes('少女'));
assert.equal(revealed.merged[0].name, '少女');
