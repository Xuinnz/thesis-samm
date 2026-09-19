// ingest endpoint
// VARYING SIZE / VARYING LIFETIME, request-scoped
// system fallback candidate
'use strict';

const { allocateBuffer, writeWholeBuffer } = require('./_alloc-utils');
const { requestRng } = require('./_rng');

const INGEST_MIN_BYTES = 64 * 1024;         // 64 KB
const INGEST_MAX_BYTES = 1024 * 1024;       // 1 MB

async function ingestRoute(req, res) {
    // Size drawn from the request's own seeded generator, so iteration N sends
    // the same payload size on every run whichever VU issued it. See _rng.js.
    const rng = requestRng(req);
    const bytes = INGEST_MIN_BYTES + Math.floor(rng() * (INGEST_MAX_BYTES - INGEST_MIN_BYTES));

    const buffer = allocateBuffer(bytes, 'ingest.js:ingestRoute', req);

    // Downstream write time, log-normal, sampled by k6 and sent with the request.
    const holdMs = Number(req.body && req.body.hold_ms) || 10;
    await new Promise((resolve) => setTimeout(resolve, holdMs));

    const checksum = writeWholeBuffer(buffer);

    res.status(200).json({ route: 'ingest', bytes, hold_ms: holdMs, checksum });
}

module.exports = ingestRoute;
