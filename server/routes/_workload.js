'use strict';

/**
 * Workload fingerprint: every knob that changes WHAT gets allocated.
 *
 * WHY THIS EXISTS
 *
 * The routing table is compiled from a characterization run, so it is only
 * valid for the workload that run observed. Nothing enforced that. Twice now a
 * setting reached the benchmark but not the characterization -- compose
 * forwards only the variables it declares, while k6 inherits the whole system
 * environment -- and the model was fit against a workload that did not exist.
 * The most recent instance: characterization ran 32MB payloads while the
 * benchmark ran 16MB, so every quota was sized for twice the demand it would
 * serve. Nothing detected it; it surfaced only when the container was
 * OOM-killed and the trace turned out to describe an impossible peak.
 *
 * A mismatch here is never a warning. A table fit to the wrong workload
 * produces numbers that look like allocator behaviour and are not, which is
 * worse than a server that refuses to start.
 *
 * Only allocation-shaping inputs belong in the fingerprint. Traffic RATE
 * (RPS, VUs) is deliberately excluded: the arena is sized from concurrency the
 * characterization observed, and a benchmark at a different rate is a
 * generalization test rather than a contract violation. HOLD_SCALE IS
 * included, even though the server never reads it, because lifetime sets how
 * long each object occupies its slot and therefore the concurrency every quota
 * is derived from.
 */

const crypto = require('crypto');
const fs = require('fs');

// The container's own memory limit, read from the cgroup rather than assumed.
// The routing table's quotas are derived from this as directly as from any
// allocation parameter, so it belongs in the fingerprint: a table compiled for
// 1024MB is simply wrong inside a 600MB container, and nothing else notices.
function containerLimitBytes() {
  for (const p of ['/sys/fs/cgroup/memory.max', '/sys/fs/cgroup/memory/memory.limit_in_bytes']) {
    try {
      const raw = fs.readFileSync(p, 'utf8').trim();
      if (raw && raw !== 'max') return raw;
    } catch { /* not this cgroup layout */ }
  }
  return 'unknown';
}

function envOr(name, fallback) {
  const raw = process.env[name];
  return raw === undefined || raw === '' ? fallback : raw;
}

function workloadParameters() {
  return {
    container_limit_bytes: containerLimitBytes(),
    process_max_bytes: String(envOr('PROCESS_MAX_BYTES', 32 * 1024 * 1024)),
    retained_bytes: String(envOr('SAMM_RETAINED_BYTES', 50 * 1024 * 1024)),
    max_touch_bytes: String(envOr('SAMM_MAX_TOUCH_BYTES', 'semantic')),
    hold_scale: String(envOr('HOLD_SCALE', '1')),
    // Route-level constants. They are not environment-driven today, but an
    // edit to any of them invalidates a compiled table just as surely as an
    // env var does, and this is the only thing that would notice.
    // k6-side, not read by the server. Present because lambda x W x size is
    // what every quota is derived from, so a change to any of them invalidates
    // the compiled table exactly as a server-side change would.
    process_hold_ms: String(envOr('PROCESS_HOLD_MS', '600')),
    endpoint_weights: String(envOr('ENDPOINT_WEIGHTS',
      'cache:0.35,fetch:0.25,process:0.25,aggregate:0.05,batch:0.10')),
    fetch_bytes: String(envOr('FETCH_BYTES', 1 * 1024 * 1024)),
    cache_bytes: String(4 * 1024),
    batch_items: String(200),
    batch_item_range: '1024-32768',
    aggregate_range: '65536-2097152',
  };
}

function workloadFingerprint() {
  const params = workloadParameters();
  const canonical = Object.keys(params).sort()
    .map((k) => `${k}=${params[k]}`).join('\n');
  const hash = crypto.createHash('sha256').update(canonical).digest('hex').slice(0, 16);
  return { fingerprint: hash, parameters: params };
}

module.exports = { workloadFingerprint, workloadParameters };
