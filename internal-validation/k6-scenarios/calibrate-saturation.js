/**
 * CALIBRATION for Experiment 1 -- how many VUs saturate each config?
 *
 * A short closed-loop sweep: one constant-vus step per value in CAL_VUS, run
 * back to back against one config. Below saturation, adding VUs adds
 * throughput. At saturation it stops: extra VUs only wait in the server's
 * queue, so throughput flattens while processing_time (which includes that
 * wait) climbs. analysis/calibration_report.py finds that knee per config and
 * recommends SATURATION_VUS -- comfortably above the highest knee of the three.
 *
 * The plateau throughput of each config is also its capacity in requests per
 * second, which is where latency-baseline.js's rate sweep should stop.
 *
 * Each step: CAL_STEP_WARMUP_SECONDS (discarded) + the rest of
 * CAL_STEP_SECONDS (measured), then CAL_GAP_SECONDS for in-flight requests to
 * drain before the next step starts.
 *
 * Env:
 *   CAL_VUS                   required, e.g. "50,100,150,200,300,400,500"
 *   CAL_STEP_SECONDS          default 45
 *   CAL_STEP_WARMUP_SECONDS   default 15
 *   CAL_GAP_SECONDS           default 10
 *   plus the workload and output variables of throughput-saturation.js
 */

import exec from 'k6/execution';
import { Counter } from 'k6/metrics';
import { runOneRequest, WORKLOAD } from './lib/workload.js';
import {
  envNumber, envList, elapsedMs, sequentialSteps, metricCount, metricValues, summaryOutputs,
} from './lib/run-shape.js';

const VUS_STEPS = envList('CAL_VUS');
if (!VUS_STEPS) throw new Error('CAL_VUS is required, e.g. CAL_VUS=50,100,150,200,300,400,500');
if (VUS_STEPS.some((v) => !Number.isInteger(v))) throw new Error('CAL_VUS values must be integers');
const STEP_S = envNumber('CAL_STEP_SECONDS', 45);
const STEP_WARMUP_S = envNumber('CAL_STEP_WARMUP_SECONDS', 15);
const GAP_S = envNumber('CAL_GAP_SECONDS', 10);
const MEASURE_S = STEP_S - STEP_WARMUP_S;
if (MEASURE_S <= 0) throw new Error('CAL_STEP_SECONDS must be longer than CAL_STEP_WARMUP_SECONDS');

const { scenarios, steps, totalSeconds } = sequentialSteps({
  values: VUS_STEPS,
  prefix: 'vus',
  stepSeconds: STEP_S,
  gapSeconds: GAP_S,
  build: (vus) => ({ executor: 'constant-vus', vus, duration: `${STEP_S}s` }),
});

const completed = new Counter('completed_iterations');

const thresholds = {};
for (const v of VUS_STEPS) {
  for (const ok of ['true', 'false']) thresholds[`completed_iterations{step:${v},phase:measure,ok:${ok}}`] = ['count>=0'];
  thresholds[`processing_time{step:${v},phase:measure}`] = ['max>=0'];
}

export const options = {
  scenarios,
  thresholds,
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max', 'count'],
};

function stepPhase(inStepMs) {
  if (inStepMs < STEP_WARMUP_S * 1000) return 'warmup';
  if (inStepMs < STEP_S * 1000) return 'measure';
  return 'tail';   // finished during the gap, after the step ended
}

export default function () {
  const step = steps[exec.scenario.name];
  const { res } = runOneRequest({ phase: stepPhase(elapsedMs() - step.startMs) });
  const doneIn = elapsedMs() - step.startMs;
  completed.add(1, {
    phase: stepPhase(doneIn),
    ok: String(res.status >= 200 && res.status < 400),
    t_s: String(Math.floor(doneIn / 1000)),
  });
}

export function handleSummary(data) {
  const rows = VUS_STEPS.map((v) => {
    const ok = metricCount(data, `completed_iterations{step:${v},phase:measure,ok:true}`);
    const failed = metricCount(data, `completed_iterations{step:${v},phase:measure,ok:false}`);
    const p = metricValues(data, `processing_time{step:${v},phase:measure}`) || {};
    return {
      vus: v,
      measure_seconds: MEASURE_S,
      completed_ok: ok,
      failed,
      throughput_rps: ok / MEASURE_S,
      processing_ms: { med: p.med, p90: p['p(90)'], p95: p['p(95)'], p99: p['p(99)'], max: p.max, count: p.count },
    };
  });

  const report = {
    experiment: 'calibrate-saturation',
    config: __ENV.CONFIG_LABEL || null,
    executor: 'constant-vus steps (closed loop)',
    step_seconds: STEP_S, step_warmup_seconds: STEP_WARMUP_S, gap_seconds: GAP_S, total_seconds: totalSeconds,
    workload: WORKLOAD,
    steps: rows,
    dropped_iterations: metricCount(data, 'dropped_iterations'),
  };

  const lines = [`calibrate-saturation  config=${report.config || '-'}  (measure ${MEASURE_S} s per step)`,
    '     VUs   throughput/s   failed   processing p50 / p95 (ms)'];
  for (const r of rows) {
    lines.push(`  ${String(r.vus).padStart(6)}   ${r.throughput_rps.toFixed(1).padStart(12)}   ${String(r.failed).padStart(6)}   `
      + `${(r.processing_ms.med ?? NaN).toFixed(1)} / ${(r.processing_ms.p95 ?? NaN).toFixed(1)}`);
  }
  return summaryOutputs('calibration-summary.json', report, lines);
}
