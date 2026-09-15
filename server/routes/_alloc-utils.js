'use strict';

const profiler = require('../../profiler');

// Load the custom SAMM allocator only if explicitly enabled.
// This ensures the baseline benchmark remains completely unaffected.
const samm = process.env.SAMM_ALLOCATOR_ENABLED === 'true'
  ? require('../../zig-allocator')
  : null;

  // Extract the requested megabytes from the request body
  // converts it into bytes
  // default to 1MB if the input is missing or invalid
  function resolvePayloadBytes(req, defaultMb = 1){
    const sizeMb = Number(req.body && req.body.size_mb);
    const safeMb = Number.isFinite(sizeMb) && sizeMb > 0 ? sizeMb : defaultMb;
    
    return Math.floor(safeMb * 1024 * 1024);
  }


  // the Allocator, if SAMM is enabled, then it uses samm
  // if not, it use allocUnsafe, an allocator by V8 that does not fill it up with zeroes before using
  function allocateBuffer(bytes, callSiteId, req){
    const size = Math.max(bytes, 1);

    let buffer = null;
    // if SAMM is enabled, use samm
    if (samm !== null && callSiteId){
      buffer = samm.allocate(callSiteId, size, req && req.sammRegion);
    }

    // if SAMM is disabled, use 
    if (buffer === null) {
      buffer = Buffer.allocUnsafe(size);
    }
    
    // track allocation if profiler is enabled
    if (callSiteId){
      profiler.track(buffer, callSiteId, buffer.length, req && req.profilerScope);
    }

    return buffer;
  }

  const PAGE_BYTES = 4096;

  // Optional cap for testing/instrumentation.
  // Restricts the maximum number of bytes that can be forcefully written.
  const TOUCH_CAP_BYTES = (() => {
    const raw = process.env.SAMM_MAX_TOUCH_BYTES;
    if (raw === undefined || raw === '') return Infinity;
    const n = Number(raw);
    if (!Number.isFinite(n) || n < 0) {
      throw new Error(`SAMM_MAX_TOUCH_BYTES must be a non-negative byte count; got ${JSON.stringify(raw)}`);
    }
    return n === 0 ? Infinity : n;
  })();

  // Forces memory pages into physical RAM by writing to them.
  // Reading the byte back into a checksum keeps the compiler from optimizing the loop away
  function writePages(buffer, upto){
    const limit = Math.min(buffer.length, upto, TOUCH_CAP_BYTES);
    let checksum = 0;
    for (let i = 0; i < limit; i += PAGE_BYTES) {
      buffer[i] = i & 0xff;
      checksum = (checksum + buffer[i]) & 0xff;
    }
    return checksum;
  }

  // Simulates a route fully populating it's buffer
  function writeWholeBuffer(buffer){
    return writePages(buffer, buffer.length);
  }

  // Simulates a route only inspecting the beginning of a buffer.
  function writePrefix(buffer, bytes){
    return writePages(buffer, bytes);
  }

  // Middleware that ties memory and profiling lifecycles to the HTTP request
  // This records the request lifespan. Also used to clean up memory regions of SAMM if the callsite is request-scope

  function regionMiddleware(req, res, next){
    req.profilerScope = profiler.beginScope();

    if (samm !== null){
      const id = samm.openRegion();
      if (id >= 0) {
        req.sammRegion = id;
        let closed = false;

        const close = () => {
          if (closed) return;
          closed = true;
          samm.closeRegion(id);
        };

        res.on('finish', close);
        res.on('close', close);
      }
    }

    let scopeEnded = false;
    const endScope = () => {
      if (scopeEnded) return;
      scopeEnded = true;
      profiler.endScope(req.profilerScope);
    };

    res.on('finish', endScope);
    res.on('close', endScope);

    next();
  }

module.exports = {
  resolvePayloadBytes,
  allocateBuffer,
  writeWholeBuffer,
  writePrefix,
  regionMiddleware,
};

