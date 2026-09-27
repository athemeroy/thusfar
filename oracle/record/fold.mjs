// Run the actual browser KG.world(cutoff) at exactly 20 positions for one recorded book.
// node oracle/record/fold.mjs BOOK_DIR OUTPUT.jsonl
import fs from 'node:fs';
import path from 'node:path';
import { KG } from '../../web/js/kg.js';

const [bookDir, output] = process.argv.slice(2);
if (!bookDir || !output) throw new Error('usage: node oracle/record/fold.mjs BOOK_DIR OUTPUT.jsonl');
const book = JSON.parse(fs.readFileSync(path.join(bookDir, 'book.json'), 'utf8'));
const graph = JSON.parse(fs.readFileSync(path.join(bookDir, 'kg.json'), 'utf8'));
const status = JSON.parse(fs.readFileSync(path.join(bookDir, 'status.json'), 'utf8'));
const records = graph.log;
if (!Array.isArray(records)) throw new Error('kg.json has no log array');
const length = Number.isInteger(book.len) ? book.len : records.at(-1)?.p ?? 0;
if (length < 0) throw new Error('invalid book length');
const kg = new KG(path.basename(bookDir));
kg.records = records;
kg.frontier = status.frontier || 0;
kg.state = status.state || '';

const rows = [];
for (let i = 0; i < 20; i++) {
  const cutoff = Math.round(length * i / 19);
  const world = kg.world(cutoff);
  const ids = new Set(records.flatMap((r) => [r.id, r.from, r.into, r.a, r.b, ...(r.who || [])]).filter(Boolean));
  rows.push({
    cutoff,
    frontier: world.frontier,
    state: world.state,
    people: Object.fromEntries(world.people),
    rels: world.rels,
    events: world.events,
    recaps: world.recaps,
    saga: world.saga,
    canon: Object.fromEntries([...ids].sort().map((id) => [id, world.canon(id)])),
    relsOf: Object.fromEntries([...world.people.keys()].sort().map((id) => [id, world.relsOf(id)])),
    ranked: world.ranked().map((person) => person.id),
  });
}
fs.mkdirSync(path.dirname(output), { recursive: true });
fs.writeFileSync(output, rows.map((row) => JSON.stringify(row)).join('\n') + '\n');
console.log(`recorded ${rows.length} KG.world cutoffs`);
