//batch route
// tests density and throughput
// simulates a server unpacking an array of 200 JSON objects all at once

'use strict';

const { allocateBuffer, simulateProcessing } = require('./_alloc-utils');

// simulating a batch transformation
// 200 items, each between 1KB and 32KB
const DEFAULT_BATCH_ITEMS = 200;
const ITEM_MIN_BYTES = 1 * 1024;
const ITEM_MAX_BYTES = 32 * 1024;

function randomItemBytes(){
    return ITEM_MIN_BYTES + Math.floor(Math.random() * (ITEM_MAX_BYTES - ITEM_MIN_BYTES));
}

// burst generator endpoint
// produce many concurrect short lived allocations within a single event loop
function batchRoute(req, res) {
    const itemCount = Number(req.body && req.body.item_count) || DEFAULT_BATCH_ITEMS;
    const safeCount = Math.min(Math.max(itemCount, 1), 2000);

    let totalBytes = 0;
    let checksumAllumulator = 0;

    // since for loop is synchronous, v8 must finish the entire loop before it can pause
    // to run GC or answer another req 
    for (let i = 0; i < safeCount; i += 1){
        const bytes = randomItemBytes();

        const buffer = allocateBuffer(bytes);
        checksumAllumulator = (checksumAllumulator + simulateProcessing(buffer));

        totalBytes += bytes;
    }

    res.status(200).json({
        route: 'batch',
        item_count: safeCount,
        total_bytes: totalBytes,
        checkSum: checksumAllumulator,
    });
}

module.exports = batchRoute;