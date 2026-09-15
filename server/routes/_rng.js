'use strict';

/**
 * Per-request deterministic RNG.
 *
 * The load generator decides endpoint, payload size and hold time; the server
 * still makes a few draws of its own (batch item sizes, the aggregate store's
 * payload size). Those run in a different process from k6 and under concurrent
 * scheduling, so seeding a single generator at startup would NOT make them
 * reproducible: the sequence of numbers would be fixed, but which request
 * received which number would still depend on the order handlers happened to
 * run.
 *
 * So the seed travels with the request. k6 derives one from its per-iteration
 * generator and sends it as `rng_seed`; the handler builds a generator from it
 * and draws in a fixed order. Iteration N then produces byte-identical work on
 * every run, whichever VU issued it and whichever order the server serviced it.
 *
 * WHY THIS MATTERS
 *
 * It makes the allocator comparison paired. Two conditions given the same seed
 * serve the same request stream, so workload variance cancels out of the
 * difference rather than inflating it.
 *
 * mulberry32, matching load-generator/traffic-models/markov-chain.js so both
 * sides of the wire use the same generator.
 */

function makeRng(seed) {
  if (seed === undefined || seed === null || !Number.isFinite(Number(seed))) {
    return Math.random;
  }
  let state = Number(seed) >>> 0;
  return function rng() {
    state |= 0;
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Generator for this request, falling back to Math.random when k6 sent no seed. */
function requestRng(req) {
  return makeRng(req && req.body ? req.body.rng_seed : undefined);
}

module.exports = { makeRng, requestRng };
