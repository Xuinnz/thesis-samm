/**
 * SAMM k6 load generator — burst-traffic scenario driven entirely by
 * Phase 1 preprocessing outputs. No traffic shape, timing, or payload
 * size numbers are hardcoded in this file; everything numeric is
 * either read from the CSV/JSON artifacts produced by
 * preprocessing/phase1-azure-simulation, or supplied via __ENV so the
 * same script runs against baseline-v8 and samm-enabled without
 * modification.
 *
 * Required inputs (paths overridable via __ENV — see the table below):
 *   - markov_transition_matrix.csv   (Script 2.1 output)
 *   - traffic_state_series.csv       (Script 2.1 output)
 *   - jitter_parameters.json         (Script 2.2 output)
 *   - memory_payload_allocations.csv (Script 3.1 output)
 *
 * Environment variables (all optional, defaults shown):  
 *   BASE_URL                  http://localhost:3000
 *   MARKOV_MATRIX_PATH        ../../datasets/azure-trace-2019/intermediate/traffic-models/markov_transition_matrix.csv
 *   TRAFFIC_SERIES_PATH       ../../datasets/azure-trace-2019/intermediate/traffic-models/traffic_state_series.csv
 *   JITTER_PARAMS_PATH        ../../datasets/azure-trace-2019/intermediate/traffic-models/jitter_parameters.json
 *   PAYLOAD_CSV_PATH          ../../datasets/azure-trace-2019/processed/memory-models/memory_payload_allocations.csv
 *   MIN_RPS                   5        floor of the scaled RPS range
 *   MAX_RPS                   200      ceiling of the scaled RPS range
 *   SIMULATION_MINUTES        1440     length of the simulated Markov walk (1440 = one day)
 *   INITIAL_STATE             Idle     starting state for the walk
 *   SCHEDULE_SEED              (unset) integer seed for reproducible runs; omit for a fresh random walk each run
 *   STAGE_MERGE_TOLERANCE_RPS 0.5      merges consecutive minutes within this RPS delta into one k6 stage
 *   PRE_ALLOCATED_VUS         50
 *   MAX_VUS                   300
 *
 * Run example (from load-generator/k6-scenarios/):
 *   k6 run samm-load-test.js
 *   k6 run -e BASE_URL=http://localhost:3001 -e MAX_RPS=400 samm-load-test.js
 */

/**
 * The ramping-arrival-rate executor uses an "Open Model." It ignores how fast the server
 * responds. If the Markov Chain says the target is 200 Requests Per Second, k6 will forcefully
 * inject exactly 200 requests into the server every single second, even if the server is suffocating.
 * 
 * Because samm is designed to prevent Stop-The-World garbage collection pauses, the Open
 * Model is absolutely critical. If V8 pauses for 300ms, k6 will queue up dozens of new requests
 * and slam them into the server the millisecond V8 wakes up, maximizing memory pressure.
 */

import http from 'k6/http';
import { Trend } from 'k6/metrics';
import { sleep } from 'k6';
import exec from 'k6/execution';
import { SharedArray } from 'k6/data'; // <-- The memory savior

const {
  parseTransitionMatrix,
  deriveStateIntensityProfile,
  scaleToRpsRange,
  simulateSchedule,
  buildK6Stages,
  makeRng,
} = require('../traffic-models/markov-chain.js');

const { parseJitterParams, sampleHoldMs } = require('../traffic-models/jitter.js');

const { parsePayloadCsv, buildPayloadSampler } = require('../traffic-models/payload-sampler.js');

// ---------------------------------------------------------------------
// Configuration — every path and scale parameter is __ENV-overridable.
// Defaults reflect where Scripts 2.1 / 2.2 / 3.1 write their output in
// this repository's directory layout.
// ---------------------------------------------------------------------

const BASE_URL = __ENV.BASE_URL || 'http://localhost:3000';

const MARKOV_MATRIX_PATH =
  __ENV.MARKOV_MATRIX_PATH ||
  '../../datasets/azure-trace-2019/processed/traffic-models/markov_transition_matrix.csv';

const TRAFFIC_SERIES_PATH =
  __ENV.TRAFFIC_SERIES_PATH ||
  '../../datasets/azure-trace-2019/processed/traffic-models/traffic_state_series.csv';

const JITTER_PARAMS_PATH =
  __ENV.JITTER_PARAMS_PATH ||
  '../../datasets/azure-trace-2019/processed/traffic-models/jitter_parameters.json';

const PAYLOAD_CSV_PATH =
  __ENV.PAYLOAD_CSV_PATH ||
  '../../datasets/azure-trace-2019/processed/memory-models/memory_payload_allocations.csv';

const MIN_RPS = Number(__ENV.MIN_RPS) || 5;
const MAX_RPS = Number(__ENV.MAX_RPS) || 200;
const SIMULATION_MINUTES = Number(__ENV.SIMULATION_MINUTES) || 1440;
const INITIAL_STATE = __ENV.INITIAL_STATE || 'Idle';
const SCHEDULE_SEED = __ENV.SCHEDULE_SEED !== undefined ? Number(__ENV.SCHEDULE_SEED) : undefined;
const STAGE_MERGE_TOLERANCE_RPS = Number(__ENV.STAGE_MERGE_TOLERANCE_RPS) || 0.5;
const PRE_ALLOCATED_VUS = Number(__ENV.PRE_ALLOCATED_VUS) || 50;
const MAX_VUS = Number(__ENV.MAX_VUS) || 300;

// Relative weights for which endpoint archetype a given iteration hits.
// Overridable as a JSON string via __ENV.ENDPOINT_WEIGHTS, e.g.:
//   -e ENDPOINT_WEIGHTS='{"cache":0.5,"fetch":0.2,"process":0.2,"aggregate":0.05,"batch":0.05}'
// Chosen so each allocation POLICY carries a comparable share of live memory,
// rather than one quadrant dominating the result. Live bytes are lambda x W x
// size (Little's Law), so weight is the only free variable once size and hold
// are fixed by the quadrant each endpoint represents:
//
//   fetch   0.25 -> 95 rps x 0.58s x 4MB   ~= 220 MB   (Slab)
//   process 0.25 -> 95 rps x 0.80s x ~4MB  ~= 304 MB   (Bump)
//   cache / batch      no hold, so ~0 MB live -- they test allocation RATE
//   aggregate          retained, so its 50MB is independent of weight
//
// cache drops 0.40 -> 0.35 to fund process, then 0.35 -> 0.25 to fund ingest --
// cache holds ~0 bytes live, so taking share from it adds ingest's load without
// moving the memory the other quadrants contribute.
//
//   ingest  0.10 -> 38 rps x 0.58s x ~0.53MB  ~= 12 MB   (the hard quadrant)
const DEFAULT_ENDPOINT_WEIGHTS = {
  cache: 0.25,
  fetch: 0.25,
  process: 0.25,
  ingest: 0.10,
  aggregate: 0.05,
  batch: 0.10,
};
const ENDPOINT_WEIGHTS = __ENV.ENDPOINT_WEIGHTS
  ? JSON.parse(__ENV.ENDPOINT_WEIGHTS)
  : DEFAULT_ENDPOINT_WEIGHTS;

// ---------------------------------------------------------------------
// Init context — runs once before any VU/iteration starts. All file
// reads must happen here; k6 does not permit open() inside the
// exported default function.
// ---------------------------------------------------------------------

const matrix = parseTransitionMatrix(open(MARKOV_MATRIX_PATH));
const intensityProfile = deriveStateIntensityProfile(open(TRAFFIC_SERIES_PATH));
const rpsProfile = scaleToRpsRange(intensityProfile, MIN_RPS, MAX_RPS);

const schedule = simulateSchedule(
  matrix,
  rpsProfile,
  SIMULATION_MINUTES,
  INITIAL_STATE,
  SCHEDULE_SEED
);
const stages = buildK6Stages(schedule, STAGE_MERGE_TOLERANCE_RPS);

const { mu, sigma } = parseJitterParams(open(JITTER_PARAMS_PATH));

// Multiplier on hold time, applied as a shift of mu.

// For a log-normal, adding ln(k) to mu multiplies every draw by k while leaving
// sigma -- the SHAPE of the Azure-fitted distribution -- exactly as fitted. It
// is the same class of transform as the payload rescale on the server side.
//
// WHY THIS IS THE MEMORY KNOB
//
// Live bytes = arrival rate x lifetime x size (Little's Law), while CPU cost is
// arrival rate x faults. Hold time appears in the first and not the second: a
// held buffer is a timer, not work. So this raises memory pressure at zero CPU
// cost, which payload size cannot do and which a larger retained cache can only
// do by adding a constant BOTH conditions must hold -- inflating the total and
// shrinking every percentage difference being measured.
//
// Raising it raises concurrency by the same factor (L = lambda x W), so MAX_VUS
// must rise with it or the arrival rate cannot be sustained.
const HOLD_SCALE = Number(__ENV.HOLD_SCALE) || 1;
const muHold = mu + Math.log(HOLD_SCALE);

// ingest holds on the BASE Azure distribution at k = 1, not fetch's x4.
//
// HOLD_SCALE is 4/k across the load table, so HOLD_SCALE/4 is exactly 1/k: at
// every load point ingest's hold shrinks by the same factor as arrival rate
// grows, keeping its lambda x W -- and its live bytes -- constant, which is the
// invariant the whole load sweep depends on.
const INGEST_SCALE = HOLD_SCALE / 4;
const muIngest = mu + Math.log(INGEST_SCALE);


// Put BOTH the open() call and the heavy parsing strictly inside the SharedArray.
// k6 guarantees this callback fires exactly once. The raw 80MB string is born, 
// parsed, and destroyed entirely within this scope. VUs never see it.
const sharedRows = new SharedArray('azure rows', function () {
  const rawCsv = open(PAYLOAD_CSV_PATH);
  return parsePayloadCsv(rawCsv).rows;
});

// 2. Derive the metadata dynamically from the keys of the very first shared row!
// This implements your exact idea: no raw string needed in the global scope.
const sampleRow = sharedRows[0];
const headers = Object.keys(sampleRow);

const percentileColumns = [];
for (const header of headers) {
  const match = header.match(/^payload_.*_pct(\d+)_mb$/);
  if (match) {
    percentileColumns.push({ column: header, pct: Number(match[1]) });
  }
}
percentileColumns.sort((a, b) => a.pct - b.pct);
const hasSampleCount = headers.includes('SampleCount');

// 3. Reconstruct the object for the sampler engine
const samplePayloadMb = buildPayloadSampler({
  rows: sharedRows,
  percentileColumns: percentileColumns,
  hasSampleCount: hasSampleCount
});

// =====================================================================

// Cumulative endpoint weight table, built once.
const endpointNames = Object.keys(ENDPOINT_WEIGHTS);
const endpointCumulative = [];
{
  let running = 0;
  for (const name of endpointNames) {
    running += ENDPOINT_WEIGHTS[name];
    endpointCumulative.push({ name, cumulative: running });
  }
}

// One deterministic RNG per ITERATION INDEX.
//
// Keyed on the global iteration counter, not on __VU. Under an open model k6
// hands each scheduled iteration to whichever VU happens to be free, so the
// iteration-to-VU mapping changes between runs; seeding per VU would leave the
// request stream non-reproducible. Keyed on the iteration index, iteration N
// draws the same endpoint, payload and hold every time, whichever VU runs it.

// It makes the allocator comparison PAIRED: give both conditions the same seed
// and they serve a byte-identical request stream, so workload variance cancels
// out of the difference instead of inflating it. 
function seedFor(rng) { return Math.floor(rng() * 2147483647); }

function iterationRng() {
  const idx = exec.scenario.iterationInTest;
  if (SCHEDULE_SEED === undefined) return Math.random;
  return makeRng((SCHEDULE_SEED ^ Math.imul(idx + 1, 0x9e3779b1)) >>> 0);
}

function pickEndpoint(rng) {
  const r = (rng || Math.random)() * endpointCumulative[endpointCumulative.length - 1].cumulative;
  for (const entry of endpointCumulative) {
    if (r <= entry.cumulative) return entry.name;
  }
  return endpointCumulative[endpointCumulative.length - 1].name;
}

// ---------------------------------------------------------------------
// k6 test options — arrival-rate executor driven by the simulated
// Markov-chain schedule. startRate is the first stage's target so
// there is no artificial ramp-from-zero at t=0.
// ---------------------------------------------------------------------

export const options = {
  scenarios: {
    samm_burst_traffic: {
      executor: 'ramping-arrival-rate',
      startRate: stages.length > 0 ? stages[0].target : MIN_RPS,
      timeUnit: '1s',
      preAllocatedVUs: PRE_ALLOCATED_VUS,
      maxVUs: MAX_VUS,
      stages,
    },
  },
};

// ---------------------------------------------------------------------
// Per-iteration request logic
// ---------------------------------------------------------------------

// 
/**
 * Since we have holdMs, that directly affects the latency, we use this processing time
 * as a new metric. We subtract the http_req_duration by hold_ms. that way, we can get the
 * actual processing time, without the holdMs making our data wrong. This measures the 
 * actual latency of the allocator and not the holdMs anymore
 */

const processingTime = new Trend('processing_time', true);

function recordProcessing(res, holdMs) {
  processingTime.add(Math.max(0, res.timings.duration - (holdMs || 0)));
  return res;
}


function doCache(rng) {
  return recordProcessing(http.post(`${BASE_URL}/api/cache`, null, {
    headers: { 'Content-Type': 'application/json' },
  }), 0);
}

function doFetch(rng) {
  const holdMs = sampleHoldMs(muHold, sigma, rng);
  const payload = JSON.stringify({ hold_ms: holdMs });
  return recordProcessing(http.post(`${BASE_URL}/api/fetch`, payload, {
    headers: { 'Content-Type': 'application/json' },
  }), holdMs);
}

// process holds for a FIXED duration, not an Azure-sampled one.

// A small jitter is kept because a perfectly constant downstream latency is not realistic
const PROCESS_HOLD_MS = Number(__ENV.PROCESS_HOLD_MS) || 600;

// Jitter as a FRACTION of the hold, not an absolute number of milliseconds.
const PROCESS_HOLD_JITTER_FRAC = Number(__ENV.PROCESS_HOLD_JITTER_FRAC || 0.0333);
const PROCESS_HOLD_JITTER_MS = __ENV.PROCESS_HOLD_JITTER_MS !== undefined
  ? Number(__ENV.PROCESS_HOLD_JITTER_MS)
  : PROCESS_HOLD_MS * PROCESS_HOLD_JITTER_FRAC;

function doProcess(rng) {
  const sizeMb = samplePayloadMb(rng);
  const holdMs = PROCESS_HOLD_MS + (rng() * 2 - 1) * PROCESS_HOLD_JITTER_MS;
  const payload = JSON.stringify({ size_mb: sizeMb, hold_ms: holdMs, rng_seed: seedFor(rng) });
  return recordProcessing(http.post(`${BASE_URL}/api/process`, payload, {
    headers: { 'Content-Type': 'application/json' },
  }), holdMs);
}

function doAggregate(rng) {
  const sizeMb = samplePayloadMb(rng);
  const payload = JSON.stringify({ size_mb: sizeMb, rng_seed: seedFor(rng) });
  return recordProcessing(http.post(`${BASE_URL}/api/aggregate`, payload, {
    headers: { 'Content-Type': 'application/json' },
  }), 0);
}

function doIngest(rng) {
  // Draw order is fixed -- hold first, then the server's seed -- so iteration N
  // produces identical work on every run.
  const holdMs = sampleHoldMs(muIngest, sigma, rng);
  const payload = JSON.stringify({ hold_ms: holdMs, rng_seed: seedFor(rng) });
  return recordProcessing(http.post(`${BASE_URL}/api/ingest`, payload, {
    headers: { 'Content-Type': 'application/json' },
  }), holdMs);
}

function doBatch(rng) {
  // Batch item count scaled loosely off the sampled payload magnitude
  // so batch bursts also inherit realistic size variance rather than
  // a fixed item count on every call.
  const itemCount = Math.max(10, Math.min(2000, Math.round(samplePayloadMb(rng) * 2)));
  const payload = JSON.stringify({ item_count: itemCount, rng_seed: seedFor(rng) });
  return recordProcessing(http.post(`${BASE_URL}/api/batch`, payload, {
    headers: { 'Content-Type': 'application/json' },
  }), 0);
}

const ENDPOINT_HANDLERS = {
  cache: doCache,
  fetch: doFetch,
  process: doProcess,
  aggregate: doAggregate,
  batch: doBatch,
  ingest: doIngest,
};

export default function samLoadIteration() {
  const rng = iterationRng();
  const endpoint = pickEndpoint(rng);
  const handler = ENDPOINT_HANDLERS[endpoint];
  handler(rng);
}