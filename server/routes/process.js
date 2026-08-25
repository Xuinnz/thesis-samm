// process endpoint
// this enpoint is driven by the memory_payload_allocations
// generates high variance in both size and lifespan
// slab allocator target
'use strict';

const { resolvePayloadBytes, allocateBuffer, simulateProcessing} = require('./_alloc-utils');

function processRoute(req, res){
    //payload size is extracted from the payload 
    const bytes = resolvePayloadBytes(req, 5);

    const buffer = allocateBuffer(bytes, 'process.js:processRoute');

    // the higher the payload, the longer the process.
    // what makes this endpoint have a high variance and lifespan.
    const checksum = simulateProcessing(buffer);

    res.status(200).json({
        route: 'process',
        bytes,
        checksum,
    });
}

module.exports = processRoute;