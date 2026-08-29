// aggregate endpoint
// this endpoint is specifically for persistent data
// high lifespan targeting system heap
'use strict';

const { resolvePayloadBytes, allocateBuffer } = require('./_alloc-utils');

// global variance, anything put here will not be cleaned by gc
const persistentStore = [];

// max so it does not consume all ram
const MAX_RETAINED_ENTRIES = 50;

function aggregateRoute(req, res) {
    const bytes = resolvePayloadBytes(req, 1);
    const buffer = allocateBuffer(bytes, 'aggregate.js:aggregateRoute');

    // push the buffer to the global heap
    persistentStore.push({
        buffer,
        retainedAt: Date.now(),
    });

    // if we hit 500 items, pop off the oldest one.
    // only then will that heap be eligible for gc
    if (persistentStore.length > MAX_RETAINED_ENTRIES){
        persistentStore.shift();
    }

    res.status(200).json({
        route: 'aggregate',
        bytes,
        retained_count: persistentStore.length,
    });
}

module.exports = aggregateRoute;
