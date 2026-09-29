'use strict';

// Regression test for the bump arena under sustained traffic.
//
// An earlier design gated the cursor wrap on the WHOLE arena being dead. That
// sounds like the safest possible check, but Little's Law makes it unreachable:
// the busiest call-site in the trace runs at 1,526 alloc/s with a 128ms median
// lifespan, so ~195 objects are live at any instant and an arena-wide liveness
// test never passes. The arena could then only grow, never wrap -- it ran to its
// span and every request after that fell back to System. Measured before the
// fix: 0 resets, 116 grows, 3,483 fallbacks, 232MB of shared budget consumed.
//
// Per-segment liveness is reachable, because a segment's objects were allocated
// a full cycle earlier and have long since been collected.
//
// The event-loop turns below are load-bearing, not decoration. N-API defers
// these finalizers to a safe point rather than running them inside GC, so a
// purely synchronous loop never reclaims anything and this test would report a
// failure that a real server never experiences.
//
// Run:  node tests/steady_state_test.js

const assert = require('assert');
const path = require('path');

const ADDON_PATH = path.join(__dirname, '..', 'zig-out', 'lib', 'samm_allocator.node');
const addon = require(ADDON_PATH);

// Shape taken from the characterization trace for batch.js:batchRoute.
const CALL_SITE = 'batch.js:batchRoute';
const OBJECT_BYTES = 16881; // p50 allocation size
const CONCURRENT = 195; // ~= 1526 alloc/s x 128ms, by Little's Law
const BATCHES = 40;
const PER_BATCH = 500;

const tick = () => new Promise((resolve) => setImmediate(resolve));

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

(async () => {
  console.log('samm allocator — steady-state segment reuse\n');

  const token = addon.samm_intern(CALL_SITE);
  const before = addon.samm_stats();

  let ring = [];
  let served = 0;
  for (let batch = 0; batch < BATCHES; batch += 1) {
    for (let i = 0; i < PER_BATCH; i += 1) {
      const buffer = addon.samm_allocate(token, OBJECT_BYTES);
      if (buffer !== null) {
        served += 1;
        ring.push(buffer);
      }
      if (ring.length > CONCURRENT) ring.shift();
    }
    await tick(); // let deferred finalizers run, as a server would between requests
  }

  const after = addon.samm_stats();
  const total = BATCHES * PER_BATCH;
  const resets = after.bumpResets - before.bumpResets;
  const grows = after.grows - before.grows;
  const blocked = after.bumpResetBlocked - before.bumpResetBlocked;

  console.log(
    `  ${served}/${total} served, ${resets} resets, ${grows} grows, ${blocked} blocked\n`,
  );

  check('the arena actually recycles its segments', () => {
    assert.ok(
      resets > 0,
      'the arena never wrapped, so segments are not being reused and it can only grow',
    );
  });

  check('sustained traffic is served without falling back to System', () => {
    assert.strictEqual(blocked, 0, `${blocked} requests fell back to System`);
    assert.strictEqual(served, total, `only ${served} of ${total} requests were served`);
  });

  check('recycling is preferred over borrowing from the shared budget', () => {
    // Growth is the escape hatch, not the steady state. If the arena is mostly
    // growing rather than wrapping, segment reuse has regressed.
    assert.ok(
      grows < resets * 2 + 16,
      `${grows} grows against ${resets} resets suggests the arena is growing instead of recycling`,
    );
  });

  check('borrowed budget stays modest and under the ceiling', () => {
    const borrowed = after.committedBytes - after.reservedFloorBytes;
    assert.ok(
      after.committedBytes <= after.ceilingBytes,
      'committed bytes exceeded the ceiling',
    );
    assert.ok(
      borrowed < (after.ceilingBytes - after.reservedFloorBytes) / 2,
      `borrowed ${(borrowed / 2 ** 20).toFixed(0)}MB of shared budget, which is more than half the elastic headroom`,
    );
  });

  check('live buffers were never handed out twice', () => {
    // Every buffer still in the ring must be distinct memory. If a segment were
    // reused while its objects were alive, two of these would alias.
    ring.forEach((buffer, i) => buffer.writeUInt32LE(i + 1, 0));
    ring.forEach((buffer, i) => {
      assert.strictEqual(
        buffer.readUInt32LE(0),
        i + 1,
        'two live buffers share memory, so a segment was reused while still live',
      );
    });
  });

  ring = null;
  console.log(`\nstats: ${JSON.stringify(addon.samm_stats())}`);

  if (failures > 0) {
    console.log(`\n${failures} check(s) failed`);
    process.exit(1);
  }
  console.log('\nall checks passed');
})();
