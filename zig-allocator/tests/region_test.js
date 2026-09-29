'use strict';

// Verifies deterministic, region-scoped reclamation.
//
// This is the mechanism that makes the allocator's reclamation deterministic
// rather than GC-scheduled. Everything allocated against a region is released
// in one batch when the region closes — at the response boundary, which is a
// structural event — instead of whenever V8 gets around to collecting each
// Buffer. Measured at 500 RPS, the GC-driven path left 49,383 requests unable
// to recycle a bump segment because finalizers had not run yet.
//
// The safety property matters as much as the timing one: a buffer that escapes
// its request must not be allowed to read memory that now belongs to another
// request. Closing a region detaches every buffer it owns, so an escaped
// reference sees a zero-length detached buffer instead of recycled bytes.
//
// Run after `zig build`:  node tests/region_test.js

const assert = require('assert');
const path = require('path');

const ADDON_PATH = path.join(__dirname, '..', 'zig-out', 'lib', 'samm_allocator.node');
const addon = require(ADDON_PATH);

const CALL_SITES = [
  'batch.js:batchRoute',
  'cache.js:cacheRoute',
  'fetch.js:fetchRoute',
  'process.js:processRoute',
];
const TOKENS = CALL_SITES.map((cs) => addon.samm_intern(cs));

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

/** Allocates `size` against `region` from whichever call-site will serve it. */
function anyManaged(size, region) {
  for (const token of TOKENS) {
    const buffer = addon.samm_allocate(token, size, region);
    if (buffer !== null) return buffer;
  }
  return null;
}

console.log('samm allocator — deterministic region reclamation\n');

check('a region hands out an id and reclaims exactly what it owns', () => {
  const region = addon.samm_region_open();
  assert.ok(region >= 0, 'no region id was available');

  const held = [];
  for (let i = 0; i < 64; i += 1) {
    const buffer = anyManaged(4096, region);
    assert.ok(buffer !== null, `allocation ${i} was refused`);
    held.push(buffer);
  }

  const reclaimed = addon.samm_region_close(region);
  assert.strictEqual(reclaimed, held.length, 'region reclaimed a different count than it issued');
});

check('reclamation happens without any garbage collection', () => {
  // No global.gc() anywhere in this file, and no event-loop turn between the
  // allocations and the close. If reclamation depended on V8 the counters
  // below could not move.
  const before = addon.samm_stats();

  const region = addon.samm_region_open();
  for (let i = 0; i < 128; i += 1) anyManaged(8192, region);
  addon.samm_region_close(region);

  const after = addon.samm_stats();
  assert.strictEqual(
    after.regionReclaimed - before.regionReclaimed,
    128,
    'allocations were not reclaimed synchronously at region close',
  );
});

check('an escaped buffer is detached, not left pointing at recycled memory', () => {
  const region = addon.samm_region_open();
  const escaped = anyManaged(4096, region);
  assert.ok(escaped !== null);

  escaped.fill(0x7e);
  assert.strictEqual(escaped[0], 0x7e);
  assert.strictEqual(escaped.byteLength, 4096);

  addon.samm_region_close(region);

  // The reference survived its region. It must now be inert rather than a
  // window onto memory another request owns.
  assert.strictEqual(escaped.byteLength, 0, 'escaped buffer was not detached');
  assert.strictEqual(escaped[0], undefined, 'escaped buffer still reads recycled bytes');
  assert.strictEqual(addon.samm_stats().detachFailures, 0, 'a buffer could not be detached');
});

check('space is genuinely reusable after close, not merely accounted for', () => {
  // Drive far more allocations through one region-at-a-time loop than the pool
  // could hold at once. Only real reclamation makes this possible.
  const rounds = 200;
  const perRound = 64;
  for (let r = 0; r < rounds; r += 1) {
    const region = addon.samm_region_open();
    assert.ok(region >= 0, `ran out of regions at round ${r}`);
    for (let i = 0; i < perRound; i += 1) {
      assert.ok(anyManaged(65536, region) !== null, `refused at round ${r}, alloc ${i}`);
    }
    addon.samm_region_close(region);
  }

  const s = addon.samm_stats();
  assert.strictEqual(s.bumpResetBlocked, 0, 'a bump arena still could not recycle');
  assert.strictEqual(s.regionsExhausted, 0, 'ran out of region slots');
  assert.ok(s.committedBytes <= s.ceilingBytes);
});

check('regions are returned to the pool, so ids do not leak', () => {
  const before = addon.samm_stats();
  assert.strictEqual(
    before.regionsOpened - before.regionsClosed,
    0,
    'some region was opened but never closed',
  );
});

check('an unscoped allocation still works, via the GC-driven path', () => {
  // Passing no region is legal: reclamation falls back to the finalizer. That
  // is the correct lifetime model for an object that deliberately outlives its
  // request, like aggregate.js's persistentStore entries.
  const before = addon.samm_stats().unscopedAllocations;
  const buffer = anyManaged(4096, -1);
  assert.ok(buffer !== null, 'unscoped allocation was refused');
  assert.strictEqual(buffer.length, 4096);
  assert.strictEqual(
    addon.samm_stats().unscopedAllocations,
    before + 1,
    'unscoped allocation was not counted as such',
  );
});

console.log(`\nstats: ${JSON.stringify(addon.samm_stats())}`);

if (failures > 0) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log('\nall checks passed');
