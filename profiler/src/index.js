'use strict';

/**
 * Shadow Profiler — JS-facing wrapper.
 *
 * Wraps the native addon (build/Release/shadow_profiler.node) with:
 *   - an on/off switch driven by SHADOW_PROFILER_ENABLED, so the
 *     exact same server code path can run either instrumented
 *     (characterization) or clean (benchmark), per the methodology's
 *     requirement that the profiler be "active exclusively during
 *     the training data collection phase and disabled during all
 *     benchmark runs to prevent observer effect contamination."
 *   - a periodic flush timer so training_trace.csv grows
 *     incrementally during a long characterization run instead of
 *     only at the very end.
 *   - a shutdown hook that performs the final flush, writing
 *     right-censored (never-finalized) records before the process
 *     exits.
 */

const path = require('path');

const ENABLED = process.env.SHADOW_PROFILER_ENABLED === 'true';
const FLUSH_INTERVAL_MS = Number(process.env.SHADOW_PROFILER_FLUSH_MS) || 5000;
const OUTPUT_PATH =
  process.env.SHADOW_PROFILER_OUTPUT ||
  path.join(__dirname, '..', 'datasets', 'shadow-telemetry', 'raw', 'training_trace.csv');

let native = null;
let flushTimer = null;
let shutdownRegistered = false;

if (ENABLED) {
  // eslint-disable-next-line global-require
  native = require('./build/Release/shadow_profiler.node');
}

/**
 * Registers a JS object for lifespan tracking. No-op (and cheap) when
 * the profiler is disabled, so call sites do not need their own
 * enabled/disabled branching.
 *
 * @param {object} obj        The object whose GC lifespan is tracked.
 * @param {string} callSiteId Stable identifier for the call site,
 *                             e.g. "process.js:allocateBuffer".
 * @param {number} sizeBytes  Allocation size in bytes at creation time.
 */
function track(obj, callSiteId, sizeBytes) {
  if (!native) return;
  native.track(obj, callSiteId, sizeBytes);
}

function flush() {
  if (!native) return { written: 0 };
  return native.flush(OUTPUT_PATH);
}

function flushFinal() {
  if (!native) return { written: 0, censored: 0 };
  return native.flushFinal(OUTPUT_PATH);
}

function getStats() {
  if (!native) return { capacity: 0, allocated: 0, finalized: 0, pending: 0 };
  return native.getStats();
}

function start() {
  if (!native || flushTimer) return;

  flushTimer = setInterval(() => {
    const result = flush();
    if (result.written > 0) {
      console.log(`[shadow-profiler] flushed ${result.written} finalized records`);
    }
  }, FLUSH_INTERVAL_MS);
  flushTimer.unref(); // does not keep the process alive on its own

  if (!shutdownRegistered) {
    shutdownRegistered = true;
    const finalizeAndExit = (signal) => {
      console.log(`[shadow-profiler] ${signal} received, performing final flush...`);
      if (flushTimer) clearInterval(flushTimer);
      const result = flushFinal();
      console.log(
        `[shadow-profiler] final flush complete: ${result.written} finalized, ` +
          `${result.censored} right-censored records written to ${OUTPUT_PATH}`
      );
    };
    process.on('SIGTERM', () => finalizeAndExit('SIGTERM'));
    process.on('SIGINT', () => finalizeAndExit('SIGINT'));
    process.on('exit', () => finalizeAndExit('exit'));
  }

  console.log(`[shadow-profiler] started. output=${OUTPUT_PATH} flush_interval=${FLUSH_INTERVAL_MS}ms`);
}

module.exports = {
  enabled: ENABLED,
  track,
  flush,
  flushFinal,
  getStats,
  start,
  OUTPUT_PATH,
};