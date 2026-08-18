// cache endpoint
// a fast, synchronous cache lookup
// explicitly designed to test the bump pointer arena
// low variance, low lifespan


'use strict';

const { allocateBuffer, simulateProcessing } = require('./_alloc-utils');

// no randomness, no variance, all same size.
const CACHE_ENTRY_BYTES = 1024 * 4;

function cacheRoute(req, res) {
    // allocate 4kb
    const buffer = allocateBuffer(CACHE_ENTRY_BYTES);

    // simulate process to wire up the physical ram
    const checksum = simulateProcessing(buffer);

    //object dies immediately
    res.status(200).json({
        route: 'cache',
        bytes: CACHE_ENTRY_BYTES,
        checksum,
    });

    // after this function block ends, buffer is out of scope
    // now instant garbage
}

module.exports = cacheRoute;
