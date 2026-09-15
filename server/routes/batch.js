// BATCH ENDPOINT
// Simulates multiple concurrent, short-lived allocations
// varying size, fixed life
// candidate for bump allocator
'use strict';

const { allocateBuffer, writeWholeBuffer } = require('./_alloc-utils');
const { requestRng } = require('./_rng');

// defines the shape of the simulated batch workload.
// 200 items per request, each sized randomly between 1KB and 32KB.
const DEFAULT_BATCH_ITEMS = 200;
const ITEM_MIN_BYTES = 1 * 1024;
const ITEM_MAX_BYTES = 32 * 1024;

function randomItemBytes(rng){
    return ITEM_MIN_BYTES + Math.floor(rng() * (ITEM_MAX_BYTES - ITEM_MIN_BYTES));
}

// Burst generator endpoint
// Produces many concurrent, short-lived allocations in one event loop tick
function batchRoute(req, res){
    const itemCount = Number(req.body && req.body.item_count) || DEFAULT_BATCH_ITEMS;
    const safeCount = Math.min(Math.max(itemCount, 1), 2000);

    const rng = requestRng(req);
    let totalBytes = 0;
    let checksumAccumulator = 0;

    // synchronous loop blocks the event loop
    // V8 must finish allocating every item before it can pause to run GC
    for (let i = 0; i < safeCount; i += 1){
        const bytes = randomItemBytes(rng);
        
        // allocate memory for this individual item
        const buffer = allocateBuffer(bytes, 'batch.js:batchRoute', req);

        // simulate fully processing the item
        checksumAccumulator = (checksumAccumulator + writeWholeBuffer(buffer));

        totalBytes += bytes;
    }

    res.status(200).json({
        route: 'batch',
        item_count: safeCount,
        total_bytes: totalBytes,
        checksum: checksumAccumulator, // Fixed casing (was checkSum)
    });
}

module.exports = batchRoute;