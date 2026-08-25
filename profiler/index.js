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
const OUTPUT_PATH =
  process.env.SHADOW_PROFILER_OUTPUT ||
  path.join(__dirname, '..', 'datasets', 'shadow-telemetry', 'raw', 'training_trace.csv');

let native = null;
let shutdownRegistered = false;
let statsTimer = null;

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

function getStats() {
  if (!native) return { capacity: 0, inUse: 0, free: 0, totalTracked: 0, totalWritten: 0, totalCensored: 0 };
  return native.getStats();
}

/**
 * Starts the background writer thread. Call once at server startup,
 * before traffic begins, so finalizers firing early in the run have
 * somewhere to write to.
 */
function start() {
  if (!native) return;

  const started = native.start(OUTPUT_PATH);
  if (!started) {
    console.log('[shadow-profiler] writer thread already running, skipping start()');
    return;
  }

  console.log(`[shadow-profiler] writer thread started. output=${OUTPUT_PATH}`);

  // Periodic stats logging (not writing — the background thread owns
  // all writes now). Purely informational, safe to skip if unwanted.
  statsTimer = setInterval(() => {
    const stats = getStats();
    console.log(
      `[shadow-profiler] inUse=${stats.inUse}/${stats.capacity} ` +
      `tracked=${stats.totalTracked} written=${stats.totalWritten} censored=${stats.totalCensored}`
    );
  }, Number(process.env.SHADOW_PROFILER_STATS_INTERVAL_MS) || 10000);
  statsTimer.unref();

  if (!shutdownRegistered) {
    shutdownRegistered = true;
    const finalizeAndExit = (signal) => {
      console.log(`[shadow-profiler] ${signal} received, stopping writer thread...`);
      if (statsTimer) clearInterval(statsTimer);
      const result = native.stop();
      console.log(
        `[shadow-profiler] stopped: ${result.written} finalized, ` +
        `${result.censored} right-censored records written to ${OUTPUT_PATH}`
      );
    };
    process.on('SIGTERM', () => finalizeAndExit('SIGTERM'));
    process.on('SIGINT', () => finalizeAndExit('SIGINT'));
    process.on('exit', () => finalizeAndExit('exit'));
  }
}

/**
 * Explicit stop, for callers that want the final counts synchronously
 * (e.g. a characterization driver script) rather than relying on the
 * process-exit hook.
 */
function stop() {
  if (!native) return { written: 0, censored: 0 };
  if (statsTimer) clearInterval(statsTimer);
  return native.stop();
}

module.exports = {
  enabled: ENABLED,
  track,
  start,
  stop,
  getStats,
  OUTPUT_PATH,
};