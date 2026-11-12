'use strict';

// Safety of the three buffer modes (SAMM_BUFFER_MODE = detach | chunk | view;
// see BUFFER MODES in src/node-api-interface/addon.zig).
//
// chunk and view hand out typed-array views into a shared ArrayBuffer instead
// of one external Buffer per object. What must hold in every mode:
//
//   1. No two live objects ever share a byte.
//   2. After its request ends, an escaped reference never shows another
//      request's data.
//
// What differs, and is asserted per mode so the difference is a tested fact:
//
//   detach, chunk   an escaped reference reads as EMPTY from the moment its
//                   region closes, and two requests never share an ArrayBuffer.
//   view            an escaped reference keeps its own bytes until its segment
//                   is recycled, then reads as empty; requests allocating in
//                   the same segment DO share an ArrayBuffer.
//
// Run after `zig build`, once per mode:
//   SAMM_BUFFER_MODE=chunk node tests/buffer_mode_test.js

const assert = require('assert');
const path = require('path');

process.env.SAMM_ALLOCATOR_ENABLED = 'true';
process.env.SAMM_ADDON_PATH = process.env.SAMM_ADDON_PATH
  || path.join(__dirname, '..', 'zig-out', 'lib', 'samm_allocator.node');
const samm = require('..');
const MODE = samm.bufferMode;

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`  ok   ${name}`);
  } catch (err) {
    failures += 1;
    console.log(`  FAIL ${name}`);
    console.log(`       ${err.message}`);
  }
}

// Deterministic, so a failure reproduces.
let seed = 0x9e3779b9;
function rand() {
  seed ^= seed << 13; seed >>>= 0;
  seed ^= seed >>> 17;
  seed ^= seed << 5; seed >>>= 0;
  return seed / 0x100000000;
}
const between = (lo, hi) => lo + Math.floor(rand() * (hi - lo));

// Every managed call-site, with the sizes its route really asks for.
const SITES = [
  ['batch.js:batchRoute', () => between(1024, 32768)],
  ['cache.js:cacheRoute', () => 4096],
  ['ingest.js:ingestRoute', () => between(65536, 1048576)],
  ['process.js:processRoute', () => between(4096, 4 * 1048576)],
  ['fetch.js:fetchRoute', () => 1048576],
];

// An object is stamped with its id at the start, the end and every 4 KB, so
// any overlap with another live object shows up as a wrong stamp.
// (The stride stamps stop 4 bytes short of the tail stamp, so none overlap.)
function stamp(buffer, id) {
  const tail = buffer.length - 4;
  for (let i = 0; i + 4 <= tail; i += 4096) buffer.writeUInt32LE(id, i);
  if (tail >= 0) buffer.writeUInt32LE(id, tail);
}
function stampIntact(buffer, id) {
  const tail = buffer.length - 4;
  for (let i = 0; i + 4 <= tail; i += 4096) if (buffer.readUInt32LE(i) !== id) return false;
  return tail < 0 || buffer.readUInt32LE(tail) === id;
}

console.log(`samm allocator — buffer mode "${MODE}" on ${process.version}\n`);

let nextId = 1;
function openRequest() {
  return { region: samm.openRegion(), objects: [] };
}
function allocateInto(request, site, size) {
  const buffer = samm.allocate(site, size, request.region);
  if (buffer === null) return null; // capacity fallback: the server would use a plain Buffer
  const id = nextId++;
  stamp(buffer, id);
  request.objects.push({ buffer, id, size });
  return buffer;
}

check('no two live objects ever share a byte, under interleaved requests', () => {
  const open = [];
  let allocated = 0;
  for (let step = 0; step < 6000; step += 1) {
    if (open.length < 24 && rand() < 0.55) open.push(openRequest());
    if (open.length === 0) continue;
    const request = open[between(0, open.length)];

    // one allocation, or a batch-style burst
    const [site, size] = SITES[between(0, SITES.length)];
    const burst = site.startsWith('batch') ? between(1, 60) : 1;
    for (let i = 0; i < burst; i += 1) if (allocateInto(request, site, size())) allocated += 1;

    if (rand() < 0.35) {
      // close one request: everything every OPEN request holds must be intact first
      for (const r of open) {
        for (const o of r.objects) {
          assert.strictEqual(o.buffer.length, o.size, `object ${o.id} changed length while its request was open`);
          assert.ok(stampIntact(o.buffer, o.id), `object ${o.id} was overwritten while live`);
        }
      }
      const index = between(0, open.length);
      samm.closeRegion(open[index].region);
      open.splice(index, 1);
    }
  }
  for (const r of open) {
    for (const o of r.objects) assert.ok(stampIntact(o.buffer, o.id), `object ${o.id} was overwritten while live`);
    samm.closeRegion(r.region);
  }
  assert.ok(allocated > 20000, `only ${allocated} managed allocations: the test did not exercise the arenas`);
});

check('an escaped reference never shows another request\'s data', () => {
  // Keep every buffer of some closed requests, then run enough traffic to
  // recycle the arenas several times over.
  const escaped = [];
  for (let i = 0; i < 20; i += 1) {
    const request = openRequest();
    for (let j = 0; j < 50; j += 1) allocateInto(request, 'batch.js:batchRoute', between(1024, 32768));
    allocateInto(request, 'ingest.js:ingestRoute', between(65536, 262144));
    escaped.push(...request.objects);
    samm.closeRegion(request.region);
  }

  for (let round = 0; round < 400; round += 1) {
    const request = openRequest();
    for (let j = 0; j < 100; j += 1) allocateInto(request, 'batch.js:batchRoute', between(1024, 32768));
    allocateInto(request, 'ingest.js:ingestRoute', between(65536, 262144));
    for (const o of request.objects) assert.ok(stampIntact(o.buffer, o.id), 'a live object was overwritten');
    samm.closeRegion(request.region);

    // An escaped reference is either cut off, or still exactly its own bytes.
    for (const o of escaped) {
      if (o.buffer.length === 0) continue;
      assert.strictEqual(o.buffer.length, o.size);
      assert.ok(stampIntact(o.buffer, o.id), `escaped object ${o.id} shows bytes that are not its own`);
    }
  }
  const stillReadable = escaped.filter((o) => o.buffer.length !== 0).length;
  assert.strictEqual(stillReadable, 0, `${stillReadable} of ${escaped.length} escaped references were never cut off`);
});

check(MODE === 'view'
  ? 'view: an escaped reference keeps its own bytes until its segment is recycled'
  : `${MODE}: an escaped reference reads as empty the moment its request ends`, () => {
  const request = openRequest();
  for (let j = 0; j < 40; j += 1) allocateInto(request, 'batch.js:batchRoute', 8192);
  const held = request.objects.slice();
  samm.closeRegion(request.region);
  const readable = held.filter((o) => o.buffer.length !== 0);
  if (MODE === 'view') {
    assert.ok(readable.length > 0, 'expected views to outlive the region in view mode');
    for (const o of readable) assert.ok(stampIntact(o.buffer, o.id), 'a surviving view lost its own bytes');
  } else {
    assert.strictEqual(readable.length, 0, `${readable.length} of ${held.length} were still readable after close`);
    assert.strictEqual(held[0].buffer.toString(), '');
  }
});

check(MODE === 'view'
  ? 'view: requests in the same segment share one ArrayBuffer (the known exposure)'
  : `${MODE}: two requests never share an ArrayBuffer`, () => {
  const a = openRequest();
  const b = openRequest();
  for (let j = 0; j < 80; j += 1) {
    allocateInto(a, 'batch.js:batchRoute', between(1024, 32768));
    allocateInto(b, 'batch.js:batchRoute', between(1024, 32768));
  }
  const buffersOfA = new Set(a.objects.map((o) => o.buffer.buffer));
  const shared = b.objects.filter((o) => buffersOfA.has(o.buffer.buffer)).length;
  if (MODE === 'view') {
    assert.ok(shared > 0, 'expected interleaved requests to share a segment buffer in view mode');
  } else {
    assert.strictEqual(shared, 0, `${shared} of request B's objects sit in an ArrayBuffer request A can reach`);
    // and what A can reach through .buffer holds A's objects and nothing else
    if (MODE === 'chunk') {
      for (const ab of buffersOfA) {
        const whole = Buffer.from(ab);
        for (const o of b.objects) {
          assert.ok(!stampInside(whole, o.id), `request B's object ${o.id} is visible through request A's ArrayBuffer`);
        }
      }
    }
  }
  samm.closeRegion(a.region);
  samm.closeRegion(b.region);

  function stampInside(whole, id) {
    for (let i = 0; i + 4 <= whole.length; i += 64) if (whole.readUInt32LE(i) === id) return true;
    return false;
  }
});

check('objects are counted once, nothing fails to detach, regions do not leak', () => {
  const before = samm.stats();
  let made = 0;
  for (let i = 0; i < 300; i += 1) {
    const request = openRequest();
    for (let j = 0; j < 30; j += 1) if (allocateInto(request, 'batch.js:batchRoute', 4096)) made += 1;
    if (allocateInto(request, 'cache.js:cacheRoute', 4096)) made += 1;
    samm.closeRegion(request.region);
  }
  const after = samm.stats();
  assert.strictEqual(after.regionReclaimed - before.regionReclaimed, made, 'reclaimed objects do not match allocations');
  assert.strictEqual(after.detachFailures, 0);
  assert.strictEqual(after.regionsOpened - after.regionsClosed, 0, 'a region was left open');
  if (MODE !== 'detach') {
    assert.ok(after.viewedAllocations > before.viewedAllocations, 'no object was served as a view');
    assert.ok(after.sharedBuffers - before.sharedBuffers < made / 4, 'views are not sharing buffers');
  }
});

check('a region id that outlived its region cannot join the request holding the slot now', () => {
  // A handler still running after its client disconnected holds a closed
  // region's id. The slot is reused straight away.
  const stale = samm.openRegion();
  samm.allocate('batch.js:batchRoute', 4096, stale);
  samm.closeRegion(stale);
  const current = openRequest();
  for (let j = 0; j < 4; j += 1) allocateInto(current, 'batch.js:batchRoute', 4096);

  const unscopedBefore = samm.stats().unscopedAllocations;
  const late = samm.allocate('batch.js:batchRoute', 4096, stale);
  assert.ok(late !== null);
  assert.strictEqual(samm.stats().unscopedAllocations, unscopedBefore + 1, 'the late allocation joined a region');
  assert.ok(!current.objects.some((o) => o.buffer.buffer === late.buffer), 'it shares an ArrayBuffer with the new request');
  assert.strictEqual(samm.closeRegion(stale), 0, 'a stale id closed the new request\'s region');

  samm.closeRegion(current.region);
  assert.strictEqual(late.length, 4096, 'closing the new request detached the late allocation');
});

check('an unscoped allocation is still an ordinary Buffer with its own finalizer', () => {
  const before = samm.stats().unscopedAllocations;
  const buffer = samm.allocate('batch.js:batchRoute', 4096);
  assert.ok(buffer !== null);
  assert.strictEqual(buffer.byteOffset, 0);
  assert.strictEqual(samm.stats().unscopedAllocations, before + 1);
});

console.log(`\nstats: ${JSON.stringify(samm.stats())}`);
if (failures > 0) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log('\nall checks passed');
