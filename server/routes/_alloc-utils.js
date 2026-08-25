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

// we simulate a process to trigger a page fault
// this will make sure that the heap we requested will actually get the physical ram we requested
// not just the virtual ram
function simulateProcessing(buffer){
  let checksum = 0

  //stride of 4096 to trigger a page fault every 4kb
  const stride = 4096;
  for (let i = 0; i < buffer.length; i += stride){
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