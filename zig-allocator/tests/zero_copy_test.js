'use strict';

// Verifies that a Buffer handed back by samm_allocate is a window onto the
// mmap'd region itself, not a copy made somewhere along the N-API chain.
//
// The old proof was aliasing: hold a buffer across a bump wrap and watch the
// next generation overwrite it. The live==0 reset guard deliberately makes that
// impossible now -- an arena will grow rather than reclaim memory under live
// objects -- so zero-copy is established two other ways instead:
//
//   1. Structurally. A pooled V8 copy of a small allocation lands at a non-zero
//      byteOffset inside Node's shared 8KB pool. An external buffer owns an
//      ArrayBuffer of exactly its own length, at offset zero.
//   2. By residency. Touching N bytes of payload must move RSS by about N. A
//      copy somewhere in the chain would move it by roughly 2N.
//
// Run after `zig build`:  node tests/zero_copy_test.js

const assert = require('assert');
const path = require('path');

const ADDON_PATH = path.join(__dirname, '..', 'zig-out', 'lib', 'samm_allocator.node');
const addon = require(ADDON_PATH);

// Every call-site the server currently tracks, resolved to tokens once -- which
// is the whole point of interning: no request hashes a string.
const CALL_SITES = [
  'cache.js:cacheRoute',
  'batch.js:batchRoute',
  'fetch.js:fetchRoute',
  'process.js:processRoute',
  'aggregate.js:aggregateRoute',
];
const TOKENS = new Map(CALL_SITES.map((cs) => [cs, addon.samm_intern(cs)]));

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

/** Allocates `size` from whichever call-site will serve it, or null. */
function anyManaged(size) {
  for (const token of TOKENS.values()) {
    const buffer = addon.samm_allocate(token, size);
    if (buffer !== null) return buffer;
  }
  return null;
}

console.log('samm allocator — zero-copy verification\n');

check('interning returns a distinct token per call-site', () => {
  const tokens = [...TOKENS.values()];
  assert.ok(tokens.every((t) => Number.isInteger(t) && t >= 0));
  assert.strictEqual(new Set(tokens).size, tokens.length);
});

check('a managed call-site returns a real Buffer', () => {
  const managed = CALL_SITES
    .map((cs) => addon.samm_allocate(TOKENS.get(cs), 4096))
    .filter(Boolean);
  assert.ok(managed.length > 0, 'no call-site was routed to an arena');
  for (const buffer of managed) {
    assert.ok(Buffer.isBuffer(buffer));
    assert.strictEqual(buffer.length, 4096);
  }
});

check('an unmanaged call-site returns null rather than throwing', () => {
  const token = addon.samm_intern('not-a-real-call-site.js:nope');
  assert.strictEqual(addon.samm_allocate(token, 4096), null);
});

check('an unknown token returns null rather than throwing', () => {
  assert.strictEqual(addon.samm_allocate(999999, 4096), null);
});

check('buffers are external, not copies into Node’s shared pool', () => {
  // Small allocations are exactly where Node would pool a copy, so this is the
  // size that actually discriminates.
  const small = anyManaged(100);
  assert.ok(small, 'no call-site served a small allocation');
  assert.strictEqual(small.length, 100);
  assert.strictEqual(small.byteOffset, 0, 'buffer sits at an offset inside a shared pool');
  assert.strictEqual(
    small.buffer.byteLength,
    100,
    'backing ArrayBuffer is not exactly the allocation, so this is a pooled copy',
  );
});

check('the reserved region is not resident until it is touched', () => {
  // Lazy faulting: reserving the pool must not move RSS by the size of the
  // pool. The mapping is several GB of virtual span.
  const rssBytes = process.memoryUsage().rss;
  assert.ok(
    rssBytes < 256 * 1024 * 1024,
    `RSS is ${(rssBytes / (1024 * 1024)).toFixed(1)} MB, which suggests the mapping was populated eagerly`,
  );
});

check('touching N bytes of payload moves RSS by about N, not 2N', () => {
  const CHUNK = 1024 * 1024;
  const WANT = 48 * CHUNK;

  const held = [];
  let touched = 0;
  const before = process.memoryUsage().rss;
  while (touched < WANT) {
    const buffer = anyManaged(CHUNK);
    if (buffer === null) break;
    buffer.fill(0xab); // force every page resident
    held.push(buffer);
    touched += buffer.length;
  }
  const grew = process.memoryUsage().rss - before;

  assert.ok(touched >= 8 * CHUNK, `only ${touched / CHUNK} MB could be allocated`);
  assert.ok(
    grew < touched * 1.6,
    `RSS grew ${(grew / CHUNK).toFixed(1)} MB for ${(touched / CHUNK).toFixed(1)} MB of payload, ` +
      'which implies the bytes were copied rather than mapped',
  );
  held.length = 0;
});

check('a live generation grows the arena instead of wrapping over it', () => {
  const token = TOKENS.get('cache.js:cacheRoute');
  const before = addon.samm_stats();

  // Hold every buffer, so nothing finalizes and live never returns to zero.
  const held = [];
  for (let i = 0; i < 4000; i += 1) {
    const buffer = addon.samm_allocate(token, 4096);
    if (buffer === null) break;
    held.push(buffer);
  }

  const after = addon.samm_stats();
  assert.strictEqual(
    after.bumpResets,
    before.bumpResets,
    'the arena wrapped while objects were still alive, which is the corruption the guard exists to prevent',
  );
  assert.ok(
    after.grows > before.grows || after.bumpResetBlocked > before.bumpResetBlocked,
    'the arena neither grew nor reported being blocked',
  );
  held.length = 0;
});

check('an object too large for any arena is attributed to the right kind', () => {
  const before = addon.samm_stats();

  const HUGE_BYTES = 2 ** 40;
  for (const token of TOKENS.values()) {
    assert.strictEqual(addon.samm_allocate(token, HUGE_BYTES), null);
  }

  const after = addon.samm_stats();
  const oversize =
    after.bumpOversizeFallbacks - before.bumpOversizeFallbacks +
    (after.slabOversizeFallbacks - before.slabOversizeFallbacks);

  assert.ok(oversize > 0, 'an impossible request was refused without being attributed');
  assert.strictEqual(
    after.slabZeroSlotFallbacks - before.slabZeroSlotFallbacks,
    0,
    'an oversized request was blamed on an unprovisioned class',
  );
});

check('capacityFallbacks stays the sum of its five causes', () => {
  const s = addon.samm_stats();
  assert.strictEqual(
    s.capacityFallbacks,
    s.bumpOversizeFallbacks +
      s.slabOversizeFallbacks +
      s.slabZeroSlotFallbacks +
      s.slabExhaustedFallbacks +
      s.bumpResetBlocked,
  );
});

check('committed bytes track usage, not reservations, and stay under the ceiling', () => {
  const s = addon.samm_stats();
  assert.ok(
    s.committedBytes <= s.ceilingBytes,
    `committed ${s.committedBytes} exceeds ceiling ${s.ceilingBytes}`,
  );
  // Floors are an entitlement, not a prepayment: a stratum costs nothing until
  // it actually touches memory. This test allocates a trickle, so committed
  // must sit far below the sum of floors -- if it matched them, the allocator
  // would be back to reserving its whole budget up front and starving its own
  // elastic growth.
  assert.ok(
    s.committedBytes < s.reservedFloorBytes,
    `committed ${s.committedBytes} already at the floor total ${s.reservedFloorBytes}; ` +
      'floors appear to be pre-charged rather than charged on use',
  );
});

check('warmup makes the guaranteed floors resident', () => {
  const before = process.memoryUsage().rss;
  const warmed = addon.samm_warmup();
  const grew = process.memoryUsage().rss - before;

  assert.ok(warmed > 0, 'warmup touched nothing');
  assert.strictEqual(addon.samm_stats().warmedBytes, warmed);
  // It must actually fault the pages in, not just walk a counter.
  assert.ok(
    grew > warmed * 0.5,
    `warmup claimed ${(warmed / 2 ** 20).toFixed(1)} MB but RSS only moved ${(grew / 2 ** 20).toFixed(1)} MB`,
  );
});

console.log(`\nstats: ${JSON.stringify(addon.samm_stats(), null, 2)}`);

if (failures > 0) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log('\nall checks passed');
