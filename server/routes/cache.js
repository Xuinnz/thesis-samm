// CACHE ENDPOINT
// a fast, synchronous cache lookup
// fixed life, fixed size
// candidate for bump allocator


'use strict';

const { allocateBuffer, writeWholeBuffer } = require('./_alloc-utils');

// no randomness, no variance, all same size.
const CACHE_ENTRY_BYTES = 1024 * 4;

function cacheRoute(req, res) {
    // allocate 4kb
    const buffer = allocateBuffer(CACHE_ENTRY_BYTES, 'cache.js:cacheRoute', req);

    // simulate process to wire up the physical ram
    // A cache entry is written in full when it is created.
    const checksum = writeWholeBuffer(buffer);

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
