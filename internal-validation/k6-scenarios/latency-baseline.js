/**
 * EXPERIMENT 2 -- latency below saturation (internal validity).
 *
 * Open loop (k6 constant-arrival-rate) at rates every config can sustain, so
 * nothing queues and what is measured is the allocator's own cost per request.
 * processing_time is http_req_duration minus the artificial hold, exactly as
 * samm-load-test.js computes it (duplicated in lib/workload.js).
 *
 * LATENCY_RPS_SWEEP runs several rates back to back, one step each. Below
 * saturation the distribution should stay flat as the rate rises; the first
 * step where it shifts is where queueing starts. analysis/latency_report.py
 * runs that check.
 *
 * FULL DISTRIBUTION, two ways:
 *   1. Raw per-request values. k6 does not give handleSummary() the individual
 *      samples -- only aggregates -- so the raw values come from k6's own
 *      sample stream: run with  --out csv=raw.csv.gz  (run.sh always does).
 *      Every processing_time sample carries step, phase, endpoint and t_s
 *      (second within the step) tags.
 *   2. handleSummary() writes, per step, the whole quantile function of
 *      processing_time (every 0.5 % plus the far tail), so the distribution
 *      can be plotted even without the raw file.
 *
 * Env:
 *   LATENCY_RPS_SWEEP            e.g. "10,20,40,80"   (or LATENCY_RPS for a single rate)
 *   LATENCY_STEP_SECONDS         default 60
 *   LATENCY_STEP_WARMUP_SECONDS  default 10  (start of each step, discarded)
 *   LATENCY_GAP_SECONDS          default 15  (between steps, lets held requests drain)
 *   LATENCY_VU_HEADROOM          default 4   (VUs = rate x mean hold x headroom + 20)
 *   LATENCY_MAX_VUS              optional fixed VU count per step, overrides the above
 *   plus the workload and output variables of throughput-saturation.js
 */

import exec from 'k6/execution';
import { Counter } from 'k6/metrics';
import { runOneRequest, meanHoldMs, WORKLOAD } from './lib/workload.js';
import {
  envNumber, envList, elapsedMs, sequentialSteps, quantileStats, quantileTable,
  metricCount, metricValues, summaryOutputs,
} from './lib/run-shape.js';

const RATES = envList('LATENCY_RPS_SWEEP') || (() => {
  if (!__ENV.LATENCY_RPS) throw new Error('set LATENCY_RPS_SWEEP (e.g. "10,20,40,80") or LATENCY_RPS');
  return [envNumber('LATENCY_RPS')];
})();
const STEP_S = envNumber('LATENCY_STEP_SECONDS', 60);
const STEP_WARMUP_S = envNumber('LATENCY_STEP_WARMUP_SECONDS', 10);
const GAP_S = envNumber('LATENCY_GAP_SECONDS', 15);
const VU_HEADROOM = envNumber('LATENCY_VU_HEADROOM', 4);
const FIXED_VUS = __ENV.LATENCY_MAX_VUS ? envNumber('LATENCY_MAX_VUS') : null;
const MEASURE_S = STEP_S - STEP_WARMUP_S;
if (MEASURE_S <= 0) throw new Error('LATENCY_STEP_SECONDS must be longer than LATENCY_STEP_WARMUP_SECONDS');

// Little's law: a rate needs rate x hold requests in flight. VUs are sized from
// the hold model the workload actually uses, with headroom for the log-normal
// tail. All of them are allocated before the test starts, so no VU is
// initialized mid-step (that would perturb the load generator).
const MEAN_HOLD_S = meanHoldMs() / 1000;
const vusFor = (rate) => FIXED_VUS || Math.ceil(rate * MEAN_HOLD_S * VU_HEADROOM) + 20;

const { scenarios, steps, totalSeconds } = sequentialSteps({
  values: RATES,
  prefix: 'rate',
  stepSeconds: STEP_S,
  gapSeconds: GAP_S,
  build: (rate) => ({
    executor: 'constant-arrival-rate',
    rate,
    timeUnit: '1s',
    duration: `${STEP_S}s`,
    preAllocatedVUs: vusFor(rate),
    maxVUs: vusFor(rate),
  }),
});

const completed = new Counter('completed_requests');

const thresholds = {};
for (const [name, step] of Object.entries(steps)) {
  thresholds[`processing_time{step:${step.value},phase:measure}`] = ['max>=0'];
  for (const ok of ['true', 'false']) thresholds[`completed_requests{step:${step.value},phase:measure,ok:${ok}}`] = ['count>=0'];
  thresholds[`processing_clamped{step:${step.value},phase:measure}`] = ['count>=0'];
  thresholds[`dropped_iterations{scenario:${name}}`] = ['count>=0'];
}

export const options = {
  scenarios,
  thresholds,
  summaryTrendStats: quantileStats(),
};

export default function () {
  const step = steps[exec.scenario.name];
  const sentIn = elapsedMs() - step.startMs;
  // Phase by SEND time: a request belongs to the window it was sent in, even
  // if its response lands a moment after the step ends.
  const phase = sentIn < STEP_WARMUP_S * 1000 ? 'warmup' : 'measure';
  const { res } = runOneRequest({ phase, t_s: String(Math.floor(sentIn / 1000)) });
  completed.add(1, { phase, ok: String(res.status >= 200 && res.status < 400) });
}

export function handleSummary(data) {
  const rows = Object.entries(steps).map(([name, step]) => {
    const ok = metricCount(data, `completed_requests{step:${step.value},phase:measure,ok:true}`);
    const failed = metricCount(data, `completed_requests{step:${step.value},phase:measure,ok:false}`);
    return {
      offered_rps: step.value,
      scenario: name,
      measure_seconds: MEASURE_S,
      vus: vusFor(step.value),
      completed_ok: ok,
      failed,
      achieved_rps: (ok + failed) / MEASURE_S,
      dropped_iterations: metricCount(data, `dropped_iterations{scenario:${name}}`),
      // durations shorter than the hold the server waited, clamped to 0 (see lib/workload.js)
      clamped: metricCount(data, `processing_clamped{step:${step.value},phase:measure}`),
      processing_ms: quantileTable(metricValues(data, `processing_time{step:${step.value},phase:measure}`)),
    };
  });

  const report = {
    experiment: 'latency-baseline',
    config: __ENV.CONFIG_LABEL || null,
    executor: 'constant-arrival-rate steps (open loop)',
    step_seconds: STEP_S, step_warmup_seconds: STEP_WARMUP_S, gap_seconds: GAP_S, total_seconds: totalSeconds,
    workload: WORKLOAD,
    raw_samples: 'k6 --out csv (processing_time rows, tags step/phase/endpoint/t_s)',
    steps: rows,
  };

  const lines = [`latency-baseline  config=${report.config || '-'}  (measure ${MEASURE_S} s per step)`,
    '   offered/s  achieved/s  dropped  failed  clamped   processing p50 / p95 / p99 (ms)'];
  for (const r of rows) {
    const q = (r.processing_ms && r.processing_ms.quantiles) || {};
    const fmt = (v) => (typeof v === 'number' ? v.toFixed(1) : '-');
    lines.push(`  ${String(r.offered_rps).padStart(9)}  ${r.achieved_rps.toFixed(1).padStart(10)}  ${String(r.dropped_iterations).padStart(7)}  `
      + `${String(r.failed).padStart(6)}  ${String(r.clamped).padStart(7)}   ${fmt(q['50'])} / ${fmt(q['95'])} / ${fmt(q['99'])}`
      + (r.dropped_iterations ? '   <-- dropped: the generator fell behind, this step is NOT below saturation' : ''));
  }
  return summaryOutputs('latency-summary.json', report, lines);
}
