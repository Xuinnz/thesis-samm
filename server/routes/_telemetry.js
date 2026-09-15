'use strict';

/**
 * Optional in-process telemetry: GC pauses and V8 heap fragmentation.
 *
 * OFF unless SAMM_TELEMETRY=true, and that default is deliberate. The GC
 * observer is itself an observer — it runs a callback on every garbage
 * collection, which under baseline memory pressure is frequent — so leaving it
 * on would contaminate the very latency and RSS numbers the study compares,
 * the same way the methodology forbids running the Shadow Profiler during a
 * benchmark. Enable it for a separate instrumented run and compare that run
 * against a clean one to see what the instrument itself cost.
 *
 * Why this exists: end-to-end p99 cannot resolve GC pauses in this workload.
 * hold_ms is log-normal with a 466ms median and 1390ms p95, so a 30-150ms
 * major-GC pause is a few percent of a ~2400ms p99 and sits well under its
 * run-to-run noise. Measuring GC directly turns the thesis's GC-pause claim
 * from unfalsifiable into testable.
 *
 * Shares the routes/ directory with _alloc-utils.js and _duration-sampler.js,
 * following the existing convention that underscore-prefixed modules there are
 * shared server infrastructure rather than endpoints.
 */

const v8 = require('v8');

const ENABLED = process.env.SAMM_TELEMETRY === 'true';
const HEAP_SAMPLE_INTERVAL_MS = Number(process.env.SAMM_HEAP_SAMPLE_MS) || 1000;

// Node's GC entry kinds, mapped to the names V8 uses for them.
const GC_KIND_NAMES = {
  1: 'minor',        // scavenge — cheap, frequent, young generation
  2: 'major',        // mark-sweep-compact — the stop-the-world pauses that matter
  4: 'incremental',  // incremental marking step
  8: 'weakcb',       // weak callback processing
};

const gc = {
  count: 0,
  totalPauseMs: 0,
  maxPauseMs: 0,
  byKind: {},
  // Every pause duration, so percentiles are exact rather than estimated.
  // ~100k entries over a 10-minute run is under 1MB, negligible against a
  // container that peaks in the hundreds of MB.
  pauses: [],
};

const heap = {
  samples: 0,
  peakTotalHeapBytes: 0,
  peakUsedHeapBytes: 0,
  peakFragmentationPct: 0,
  peakMallocedBytes: 0,
  heapSizeLimitBytes: 0,
  last: null,
};

let heapTimer = null;

function recordGcEntry(entry) {
  const kind = GC_KIND_NAMES[entry.detail && entry.detail.kind] || 'unknown';
  const ms = entry.duration;

  gc.count += 1;
  gc.totalPauseMs += ms;
  if (ms > gc.maxPauseMs) gc.maxPauseMs = ms;
  gc.pauses.push(ms);

  const bucket = gc.byKind[kind] || (gc.byKind[kind] = { count: 0, totalMs: 0, maxMs: 0 });
  bucket.count += 1;
  bucket.totalMs += ms;
  if (ms > bucket.maxMs) bucket.maxMs = ms;
}

function sampleHeap() {
  const s = v8.getHeapStatistics();

  // The "Swiss cheese" measure: heap V8 has committed but is not using. A
  // fragmented heap holds pages it cannot hand back and cannot fully reuse, so
  // this ratio rising while used_heap stays flat is fragmentation rather than
  // growth.
  const frag = s.total_heap_size > 0
    ? ((s.total_heap_size - s.used_heap_size) / s.total_heap_size) * 100
    : 0;

  heap.samples += 1;
  heap.heapSizeLimitBytes = s.heap_size_limit;
  if (s.total_heap_size > heap.peakTotalHeapBytes) heap.peakTotalHeapBytes = s.total_heap_size;
  if (s.used_heap_size > heap.peakUsedHeapBytes) heap.peakUsedHeapBytes = s.used_heap_size;
  if (frag > heap.peakFragmentationPct) heap.peakFragmentationPct = frag;
  if (s.malloced_memory > heap.peakMallocedBytes) heap.peakMallocedBytes = s.malloced_memory;

  heap.last = {
    totalHeapBytes: s.total_heap_size,
    usedHeapBytes: s.used_heap_size,
    fragmentationPct: Number(frag.toFixed(2)),
    externalBytes: s.external_memory !== undefined ? s.external_memory : null,
  };
}

function start() {
  if (!ENABLED) return false;

  const { PerformanceObserver } = require('perf_hooks');
  const observer = new PerformanceObserver((list) => {
    for (const entry of list.getEntries()) recordGcEntry(entry);
  });
  observer.observe({ entryTypes: ['gc'] });

  sampleHeap();
  heapTimer = setInterval(sampleHeap, HEAP_SAMPLE_INTERVAL_MS);
  heapTimer.unref();

  return true;
}

function percentile(sorted, p) {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.floor(sorted.length * p));
  return sorted[idx];
}

function snapshot() {
  if (!ENABLED) return { enabled: false };

  sampleHeap(); // one final reading, so the report reflects end-of-run state

  const sorted = gc.pauses.slice().sort((a, b) => a - b);
  const round = (n) => Number(n.toFixed(3));

  return {
    enabled: true,
    gc: {
      count: gc.count,
      totalPauseMs: round(gc.totalPauseMs),
      meanPauseMs: gc.count ? round(gc.totalPauseMs / gc.count) : 0,
      p50PauseMs: round(percentile(sorted, 0.5)),
      p95PauseMs: round(percentile(sorted, 0.95)),
      p99PauseMs: round(percentile(sorted, 0.99)),
      maxPauseMs: round(gc.maxPauseMs),
      byKind: gc.byKind,
    },
    heap: {
      samples: heap.samples,
      peakTotalHeapBytes: heap.peakTotalHeapBytes,
      peakUsedHeapBytes: heap.peakUsedHeapBytes,
      peakFragmentationPct: Number(heap.peakFragmentationPct.toFixed(2)),
      peakMallocedBytes: heap.peakMallocedBytes,
      heapSizeLimitBytes: heap.heapSizeLimitBytes,
      last: heap.last,
    },
  };
}

module.exports = { enabled: ENABLED, start, snapshot };
