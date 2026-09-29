'use strict';

// Verifies the reclaim half of the bridge: when V8 collects a Buffer, the
// finalizer must return its slab slot so the space can be reused. Without this
// the allocator leaks its own arenas.
//
// This also exercises handle packing. The slot index no longer travels in a
// heap-allocated struct -- it is packed into the pointer-sized finalize_hint
// N-API already carries -- so if the packing were wrong, the wrong slot would be
// freed and reuse would hand back corrupted or double-issued memory.
//
// Needs a real collection:  node --expose-gc tests/finalizer_test.js

const assert = require('assert');
const path = require('path');

const ADDON_PATH = path.join(__dirname, '..', 'zig-out', 'lib', 'samm_allocator.node');
const addon = require(ADDON_PATH);

const CALL_SITES = [
  'process.js:processRoute',
  'fetch.js:fetchRoute',
  'cache.js:cacheRoute',
  'batch.js:batchRoute',
  'aggregate.js:aggregateRoute',
];
const TOKENS = CALL_SITES.map((cs) => addon.samm_intern(cs));

// Which request sizes map to a provisioned slab class is decided by the ML
// Refinery, so the test discovers one rather than assuming.
const CANDIDATE_SIZES = [1048576, 2097152, 4194304, 65536, 131072, 8388608];
const MAX_SLOTS = 4096;

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

/** Finds a token and size whose slab class can be driven to its cap. */
function exhaustSomeSlabClass() {
  for (const token of TOKENS) {
    for (const size of CANDIDATE_SIZES) {
      const before = addon.samm_stats().slabExhaustedFallbacks;

      const held = [];
      for (let i = 0; i < MAX_SLOTS; i += 1) {
        const buffer = addon.samm_allocate(token, size);
        if (buffer === null) break;
        held.push(buffer);
      }

      if (held.length > 0 && addon.samm_stats().slabExhaustedFallbacks > before) {
        return { token, size, held };
      }
      held.length = 0;
    }
  }
  return null;
}

async function collect() {
  global.gc();
  await new Promise((resolve) => setImmediate(resolve));
  global.gc();
}

(async () => {
  console.log('samm allocator — finalizer reclaim\n');

  if (typeof global.gc !== 'function') {
    console.log('  this test needs --expose-gc:  node --expose-gc tests/finalizer_test.js');
    process.exit(1);
  }

  const found = exhaustSomeSlabClass();
  if (found === null) {
    console.log('  no slab-routed call-site could be exhausted; nothing to verify');
    process.exit(1);
  }

  const { token, size } = found;
  const slots = found.held.length;
  console.log(`  using ${size} byte requests (${slots} slot(s) before the cap)\n`);

  check('a class at its cap refuses further allocations', () => {
    assert.strictEqual(addon.samm_allocate(token, size), null);
  });

  // Write a marker through every buffer before dropping it, so that if the
  // finalizer freed the wrong slot we would be handing out memory that is still
  // referenced elsewhere.
  found.held.forEach((buffer, i) => buffer.writeUInt8(i & 0xff, 0));
  found.held.length = 0;
  await collect();

  check('collected buffers return their slots to the bitmap', () => {
    const recycled = addon.samm_allocate(token, size);
    assert.ok(
      recycled !== null,
      'the class was still exhausted after GC, so finalizers did not run or did not free',
    );
    assert.strictEqual(recycled.length, size);
  });

  check('the whole class becomes available again, not just one slot', () => {
    const reclaimed = [];
    for (let i = 0; i < slots; i += 1) {
      const buffer = addon.samm_allocate(token, size);
      if (buffer === null) break;
      reclaimed.push(buffer);
    }
    // One slot is already held by the previous check.
    assert.strictEqual(
      reclaimed.length,
      slots - 1,
      `expected ${slots - 1} further slots, got ${reclaimed.length}`,
    );

    // Every reclaimed slot must be distinct memory. Writing a unique marker
    // through each and reading them all back catches a mis-packed handle that
    // freed one slot twice.
    reclaimed.forEach((buffer, i) => buffer.writeUInt32LE(i + 1, 0));
    reclaimed.forEach((buffer, i) => {
      assert.strictEqual(
        buffer.readUInt32LE(0),
        i + 1,
        'two live buffers share memory, so a slot was issued twice',
      );
    });
    reclaimed.length = 0;
  });

  check('recycling does not leak budget', () => {
    const s = addon.samm_stats();
    assert.ok(
      s.committedBytes <= s.ceilingBytes,
      'committed bytes grew past the ceiling across an allocate/free cycle',
    );
  });

  console.log(`\nstats: ${JSON.stringify(addon.samm_stats())}`);

  if (failures > 0) {
    console.log(`\n${failures} check(s) failed`);
    process.exit(1);
  }
  console.log('\nall checks passed');
})();
