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
import { sleep } from 'k6';

const {
  parseTransitionMatrix,
  deriveStateIntensityProfile,
  scaleToRpsRange,
  simulateSchedule,
  buildK6Stages,
  makeRng,
} = require('../traffic-models/markov-chain.js');

const { parseJitterParams, sampleThinkTimeMs } = require('../traffic-models/jitter.js');

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
const DEFAULT_ENDPOINT_WEIGHTS = {
  cache: 0.4,
  fetch: 0.25,
  process: 0.2,
  aggregate: 0.05,
  batch: 0.1,
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

const parsedPayload = parsePayloadCsv(open(PAYLOAD_CSV_PATH));
const samplePayloadMb = buildPayloadSampler(parsedPayload);

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

function pickEndpoint() {
  const r = Math.random() * endpointCumulative[endpointCumulative.length - 1].cumulative;
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

function doCache() {
  return http.post(`${BASE_URL}/api/cache`, null, {
    headers: { 'Content-Type': 'application/json' },
  });
}

function doFetch() {
  return http.get(`${BASE_URL}/api/fetch`);
}

function doProcess() {
  const sizeMb = samplePayloadMb();
  const payload = JSON.stringify({ size_mb: sizeMb });
  return http.post(`${BASE_URL}/api/process`, payload, {
    headers: { 'Content-Type': 'application/json' },
  });
}

function doAggregate() {
  const sizeMb = samplePayloadMb();
  const payload = JSON.stringify({ size_mb: sizeMb });
  return http.post(`${BASE_URL}/api/aggregate`, payload, {
    headers: { 'Content-Type': 'application/json' },
  });
}

function doBatch() {
  // Batch item count scaled loosely off the sampled payload magnitude
  // so batch bursts also inherit realistic size variance rather than
  // a fixed item count on every call.
  const itemCount = Math.max(10, Math.min(2000, Math.round(samplePayloadMb() * 2)));
  const payload = JSON.stringify({ item_count: itemCount });
  return http.post(`${BASE_URL}/api/batch`, payload, {
    headers: { 'Content-Type': 'application/json' },
  });
}

const ENDPOINT_HANDLERS = {
  cache: doCache,
  fetch: doFetch,
  process: doProcess,
  aggregate: doAggregate,
  batch: doBatch,
};

export default function samLoadIteration() {
  const endpoint = pickEndpoint();
  const handler = ENDPOINT_HANDLERS[endpoint];
  handler();

  const thinkMs = sampleThinkTimeMs(mu, sigma);
  sleep(thinkMs / 1000); // k6 sleep() takes seconds
}