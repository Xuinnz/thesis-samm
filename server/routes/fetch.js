// fetch endpoint
// this forces the v8 engine to keep the allocated memory alive while it waits for a simulated network response
// also have a jitter on the latency and size.
// medium lifespan, low variance.

'use strict';

const { allocateBuffer, simulateProcessing } = require('./_alloc-utils');

//Base size of 64KB with +/- 8KB jitter
const FETCH_BASE_BYTES = 64 * 1014;
const FETCH_JITTER_BYTES = 8 * 1024;

// Simulated database latency (15ms to 60ms)
const IO_DELAY_MIN_MS = 15;
const IO_DELAY_MAX_MS = 60;

function randomJitterBytes(){
    return Math.floor((Math.random() * 2 -1) * FETCH_JITTER_BYTES);
}

function randomDelayMs() {
    return IO_DELAY_MIN_MS + Math.random() * (IO_DELAY_MAX_MS - IO_DELAY_MIN_MS);
}

async function fetchRoute(req, res) {
    const bytes = FETCH_BASE_BYTES + randomJitterBytes();

    const buffer = allocateBuffer(bytes, 'fetch.js:fetchRoute');

    // this is async, v8 event loop will pause this function till after timeout
    // v8 gc cannot collect this due to still being used.
    await new Promise((resolve) => setTimeout(resolve, randomDelayMs()));

    const checkSum = simulateProcessing(buffer);

    res.status(200).json({
        route: 'fetch',
        bytes,
        checkSum,
    });
}

module.exports = fetchRoute;