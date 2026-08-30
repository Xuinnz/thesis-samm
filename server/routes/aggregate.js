'use strict';

// aggregate endpoint
// this endpoint is specifically for persistent data
// high lifespan targeting system heap
const { allocateBuffer } = require('./_alloc-utils');

// global variance, anything put here will not be cleaned by gc
const persistentStore = [];

// max so it does not consume all ram
const MAX_RETAINED_BYTES = 100 * 1024 * 1024;

// track running total incrementally instead of reduce()-ing the full
// array on every request — this call-site's own latency is part of
// what the study measures, so an O(n) scan per request (n growing
// with retained count) would add avoidable, unrelated overhead.
let totalRetainedBytes = 0;

// IMPORTANT: aggregate intentionally does NOT draw from the same wide
// Azure-derived payload distribution as process.js (up to ~824MB per
// object). Sharing that distribution meant a single large draw could
// exceed the entire MAX_RETAINED_BYTES budget on its own, forcing
// near-immediate eviction of everything else in the store on almost
// every request — which collapsed this call-site's observed lifespan
// down to the same range as the short-lived endpoints (confirmed
// empirically: mu_lifespan dropped from ~220,000ms to ~127ms once this
// interaction was hit). A System-heap candidate is meant to model
// small-but-numerous, long-lived server state (session cache entries,
// connection pool metadata) — not occasional multi-hundred-MB payloads.
// This narrow, independent range lets MAX_RETAINED_BYTES actually hold
// dozens-to-hundreds of objects concurrently, producing genuine
// sustained retention instead of near-constant eviction.
const AGGREGATE_MIN_BYTES = 64 * 1024;        // 64KB
const AGGREGATE_MAX_BYTES = 2 * 1024 * 1024;  // 2MB

/**
 * Resolves this endpoint's own payload size, deliberately ignoring
 * the k6-sampled size_mb field used by process.js/batch.js. If a
 * caller supplies size_mb anyway (e.g. an older k6 script, or manual
 * testing), it is clamped into this endpoint's own range rather than
 * honored as-is — the server enforces its own bounds regardless of
 * what the request asks for.
 */
function resolveAggregatePayloadBytes(req) {
    const sizeMb = Number(req.body && req.body.size_mb);
    if (Number.isFinite(sizeMb) && sizeMb > 0) {
        const requestedBytes = Math.floor(sizeMb * 1024 * 1024);
        return Math.min(Math.max(requestedBytes, AGGREGATE_MIN_BYTES), AGGREGATE_MAX_BYTES);
    }
    return Math.floor(
        AGGREGATE_MIN_BYTES + Math.random() * (AGGREGATE_MAX_BYTES - AGGREGATE_MIN_BYTES)
    );
}

function aggregateRoute(req, res) {
    const bytes = resolveAggregatePayloadBytes(req);
    const buffer = allocateBuffer(bytes, 'aggregate.js:aggregateRoute');

    // push the buffer to the global heap
    persistentStore.push({
        buffer,
        retainedAt: Date.now(),
        size: bytes,
    });
    totalRetainedBytes += bytes;

    // while, not if: a single incoming allocation could in principle
    // still push us over budget by more than one evicted entry can
    // recover in a single step, so keep evicting the oldest entry
    // until back under budget rather than assuming one eviction
    // suffices.
    while (totalRetainedBytes > MAX_RETAINED_BYTES && persistentStore.length > 0) {
        const evicted = persistentStore.shift();
        totalRetainedBytes -= evicted.size;
    }

    res.status(200).json({
        route: 'aggregate',
        bytes,
        retained_count: persistentStore.length,
        retained_bytes: totalRetainedBytes,
    });
}

module.exports = aggregateRoute;