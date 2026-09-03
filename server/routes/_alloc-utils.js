'use strict';

const profiler = require('../../profiler')

// post functions does not actually contain real bytes. 
// it only contains "size_mb: 45", a hard coded one.
// this function parses it and translates it into raw bytes for V8
function resolvePayloadBytes(req, defaultMb = 1){
  const sizeMb = Number(req.body && req.body.size_mb);
  const safeMb = Number.isFinite(sizeMb) && sizeMb > 0 ? sizeMb : defaultMb;

  return Math.floor(safeMb * 1024 * 1024);
}

// we are using allocUnsafe for faster allocations.
// allocSafe automatically fills the buffer with 0 to delete the bytes but it takes time.

// when callsiteid is provided and shadow profiler is enabled, the returned buffer is registered
// for lifespan tracking under that callsiteid
function allocateBuffer(bytes, callSiteId) {
  const buffer = Buffer.allocUnsafe(Math.max(bytes, 1));

  if (callSiteId){
    profiler.track(buffer, callSiteId, buffer.length);
  }
  
  return buffer;
}

//
const FIXED_TOUCH_COUNT = 32;

/**
 * we simulate a process to make sure that the cpu actually reserves the memory
 * This has a fixed 32 steps, meaning a 32MB and 4KB payload will cost the same cpu
 * This is to make sure that we remove the cpu pressure while still maintaining the memory pressure
 * 
 * NOTE: In prev runs, this has fixed increment of 4096 (to trigger page fault), but it only cause cpu pressure
 * it was 99% CPU while still having 200MB memory. which means the bottle neck was the CPU and not the memory
 * I fixed it by adding a FIXED_TOUCH_COUNT, making sure that every process simulated will cost the same CPU cycle
 * and actually pressure the memory without dragging cpu.
 */
function simulateProcessing(buffer){
  const len = buffer.length;
  if (len === 0) return 0;

  let checksum = 0;

  const step = Math.max(1, Math.floor(len / FIXED_TOUCH_COUNT));

  for (let i = 0; i < len; i += step){
    //bitwise and keeps the checksum from overflowing into a bigInt
    checksum = (checksum + buffer[i]) & 0xff;
  }
  return checksum;
}

module.exports = {
  resolvePayloadBytes,
  allocateBuffer,
  simulateProcessing,
};