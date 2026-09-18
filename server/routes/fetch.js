// FETCH
// Forces the engine to hold onto allocated memory while waiting for an external response.
// fixed size / varying life
// candidate for slab

'use strict';

const { allocateBuffer, writeWholeBuffer } = require('./_alloc-utils');

// Defines the size of the receive buffer (default 1MB)
// 1MB is chosen because it fits perfectly into a predefined memory "slab" 
// without wasting space, and it keeps CPU page faults manageable during stress tests.
const FETCH_BASE_BYTES = (() => {
  const raw = process.env.FETCH_BYTES;
  if (raw === undefined || raw === '') return 1 * 1024 * 1024;
  const n = Number(raw);
  if (!Number.isFinite(n) || n <= 0) {
    throw new Error(`FETCH_BYTES must be a positive byte count; got ${JSON.stringify(raw)}`);
  }
  return n;
})();


async function fetchRoute(req, res) {
    const bytes = FETCH_BASE_BYTES;

    const buffer = allocateBuffer(bytes, 'fetch.js:fetchRoute', req);
    const holdMs = Number(req.body && req.body.hold_ms) || 10;

    await new Promise((resolve) => setTimeout(resolve, holdMs));

    // A receive buffer is filled end to end by the transfer that fills it.
    const checksum = writeWholeBuffer(buffer);

    res.status(200).json({
        route: 'fetch',
        bytes,
        hold_ms: holdMs,    
        checksum,
    });
}

module.exports = fetchRoute;