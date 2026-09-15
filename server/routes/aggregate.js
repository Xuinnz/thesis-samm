// AGGREGATE ENDPOINT
// This will simulate escaping objects (objects that lifespan is more than it's request scope)
// It will also simulate High Size Variance and High Lifespan Variance (varying life, varying size)
// Candidate for System Heap

'use strict';

const { allocateBuffer, writeWholeBuffer } = require('./_alloc-utils');
const { requestRng } = require('./_rng');

// A global array acting as persistent cache.
// Buffer placed here will not be garbage collected until they are evicted.
const persistentStore = [];

// Tracks the running total bytes in the store.
let totalRetainedBytes = 0;

// This maximum allowed size for the persistent store (default 50MB)
const MAX_RETAINED_BYTES = (() => {
  const raw = process.env.SAMM_RETAINED_BYTES;
  if (raw === undefined || raw === '') return 50 * 1024 * 1024;
  const n = Number(raw);
  
  if (!Number.isFinite(n) || n <= 0) {
    throw new Error(`SAMM_RETAINED_BYTES must be a positive byte count; got ${JSON.stringify(raw)}`);
  }
  return n;
})();

// Restrict allocations to between 64KB and 2MB.
// This prevents a single massive request from wiping out the entire cache,
// ensuring the store holds many concurrent objects rather than constantly evicting.
const AGGREGATE_MIN_BYTES = 64 * 1024;        // 64KB
const AGGREGATE_MAX_BYTES = 2 * 1024 * 1024;  // 2MB

// Determines the allocation size for this request.
// It ignores external requests for massive sizes, strictly clamping them to the min/max bounds.
function resolveAggregatePayloadBytes(req) {
  const sizeMb = Number(req.body && req.body.size_mb);
  
  if (Number.isFinite(sizeMb) && sizeMb > 0) {
    const requestedBytes = Math.floor(sizeMb * 1024 * 1024);
    return Math.min(Math.max(requestedBytes, AGGREGATE_MIN_BYTES), AGGREGATE_MAX_BYTES);
  }
  
  // If no valid size is requested, generate a random size within our bounds
  return Math.floor(
    AGGREGATE_MIN_BYTES + requestRng(req)() * (AGGREGATE_MAX_BYTES - AGGREGATE_MIN_BYTES)
  );
}

// main aggregate function. allocates memory then write to memory. adds it to global cache
// cleans up old data if the cache grown too large
function aggregateRoute(req, res) {
    const bytes = resolveAggregatePayloadBytes(req);

    const buffer = allocateBuffer(bytes, 'aggregate.js:aggregateRoute', req);

    writeWholeBuffer(buffer);

    // push it into the global cache
    persistentStore.push({
        buffer,
        retainedAt: Date.now(),
        size: bytes,
    });
    
    // update the counter
    totalRetainedBytes += bytes;

    // if the current bytes exceeded max, we evict one by one until we have enough length.
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