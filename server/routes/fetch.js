// fetch endpoint
// this forces the v8 engine to keep the allocated memory alive while it waits for a simulated network response
// also have a jitter on the latency and size.
// medium lifespan, low variance.

'use strict';

const { allocateBuffer, simulateProcessing } = require('./_alloc-utils');

//Base size of 64KB with +/- 8KB jitter
const FETCH_BASE_BYTES = 64 * 1024;
const FETCH_JITTER_BYTES = 8 * 1024;

function randomJitterBytes(){
    return Math.floor((Math.random() * 2 - 1) * FETCH_JITTER_BYTES);
}

async function fetchRoute(req, res) {
    const bytes = FETCH_BASE_BYTES + randomJitterBytes();

    const buffer = allocateBuffer(bytes, 'fetch.js:fetchRoute');
    const holdMs = Number(req.body && req.body.hold_ms) || 10;

    await new Promise((resolve) => setTimeout(resolve, holdMs));

    const checksum = simulateProcessing(buffer);

    res.status(200).json({
        route: 'fetch',
        bytes,
        hold_ms: holdMs,    
        checksum,
    });
}

module.exports = fetchRoute;