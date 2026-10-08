/**
 * EXPERIMENT 1 -- throughput at saturation (internal validity).
 *
 * Closed loop (k6 constant-vus): SATURATION_VUS virtual users each send their
 * next request the moment the previous one returns. With enough of them the
 * server always has work waiting, so completions per second in the steady
 * window is its maximum throughput -- for that allocator config, on this
 * hardware, with this request mix.
 *
 * Why closed loop and not a fixed arrival rate: an open-loop rate above every
 * config's capacity makes the slower configs' backlog grow by hundreds of
 * requests per second, which no maxVUs can hold for minutes, so they would
 * drop. A closed loop cannot drop -- there is no schedule to fall behind --
 * and the queue stays bounded at SATURATION_VUS. dropped_iterations is still
 * reported, and must read 0. Latency is not measured here (a closed loop
 * understates it); latency-baseline.js does that, open loop.
 *
 * The run splits into WARMUP / MEASURE / COOLDOWN seconds. Every iteration is
 * counted under the phase it COMPLETED in, so only work finished inside the
 * steady MEASURE window counts toward the result.
 *
 * Env:
 *   SATURATION_VUS      required, no default: calibrate it (calibrate-saturation.js)
 *   WARMUP_SECONDS      default 60
 *   MEASURE_SECONDS     default 180
 *   COOLDOWN_SECONDS    default 30
 *   BASE_URL, SEED, HOLD_SCALE, PROCESS_HOLD_MS, ENDPOINT_WEIGHTS, ...  see lib/workload.js
 *   CONFIG_LABEL        written into the summary (glibc / jemalloc / samm ...)
 *   SUMMARY_PATH        where handleSummary writes its JSON
 */

import { Counter } from 'k6/metrics';
import { runOneRequest, WORKLOAD } from './lib/workload.js';
import { envNumber, elapsedMs, phaseAt, metricCount, metricValues, summaryOutputs } from './lib/run-shape.js';

const VUS = envNumber('SATURATION_VUS');
const WARMUP_S = envNumber('WARMUP_SECONDS', 60);
const MEASURE_S = envNumber('MEASURE_SECONDS', 180);
const COOLDOWN_S = envNumber('COOLDOWN_SECONDS', 30);
if (VUS < 1 || !Number.isInteger(VUS)) throw new Error(`SATURATION_VUS must be a positive integer, got ${VUS}`);
if (MEASURE_S <= 0) throw new Error('MEASURE_SECONDS must be > 0');

const WARMUP_MS = WARMUP_S * 1000;
const MEASURE_MS = MEASURE_S * 1000;
const PHASES = ['warmup', 'measure', 'cooldown'];

const completed = new Counter('completed_iterations');

// Declaring a threshold on a tagged submetric is what makes k6 put that
// submetric's count into the summary handed to handleSummary.
const thresholds = { dropped_iterations: ['count>=0'] };
for (const phase of PHASES) {
  for (const ok of ['true', 'false']) thresholds[`completed_iterations{phase:${phase},ok:${ok}}`] = ['count>=0'];
}

export const options = {
  scenarios: {
    saturation: {
      executor: 'constant-vus',
      vus: VUS,
      duration: `${WARMUP_S + MEASURE_S + COOLDOWN_S}s`,
      // Whatever is in flight when cooldown ends is cut: cooldown exists so
      // that this tail never touches the measure window.
      gracefulStop: '0s',
    },
  },
  thresholds,
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max', 'count'],
};

export default function () {
  // Requests are tagged with the phase they were SENT in; the completion
  // counter with the phase they FINISHED in, which is what throughput counts.
  const { res } = runOneRequest({ phase: phaseAt(elapsedMs(), WARMUP_MS, MEASURE_MS) });
  const done = elapsedMs();
  completed.add(1, {
    phase: phaseAt(done, WARMUP_MS, MEASURE_MS),
    ok: String(res.status >= 200 && res.status < 400),
    t_s: String(Math.floor(done / 1000)),   // second of the run, for the per-second series
  });
}

export function handleSummary(data) {
  const byPhase = {};
  for (const phase of PHASES) {
    byPhase[phase] = {
      ok: metricCount(data, `completed_iterations{phase:${phase},ok:true}`),
      failed: metricCount(data, `completed_iterations{phase:${phase},ok:false}`),
    };
  }
  const dropped = metricCount(data, 'dropped_iterations');
  const throughput = byPhase.measure.ok / MEASURE_S;

  const report = {
    experiment: 'throughput-saturation',
    config: __ENV.CONFIG_LABEL || null,
    executor: 'constant-vus (closed loop)',
    vus: VUS,
    phases_s: { warmup: WARMUP_S, measure: MEASURE_S, cooldown: COOLDOWN_S },
    workload: WORKLOAD,
    completed_by_phase: byPhase,
    steady_throughput_rps: throughput,
    failed_in_measure: byPhase.measure.failed,
    dropped_iterations: dropped,
    test_run_duration_ms: data.state.testRunDurationMs,
    http_req_duration_ms: metricValues(data, 'http_req_duration'),
  };

  const lines = [
    `throughput-saturation  config=${report.config || '-'}  VUs=${VUS}  phases ${WARMUP_S}/${MEASURE_S}/${COOLDOWN_S} s`,
    `  steady throughput (MEASURE only): ${throughput.toFixed(1)} completed iterations/s`,
    `  completed: warmup ${byPhase.warmup.ok}, measure ${byPhase.measure.ok}, cooldown ${byPhase.cooldown.ok}`,
    `  failed in measure: ${byPhase.measure.failed}${byPhase.measure.failed ? '   <-- INVALID: errors inflate or deflate throughput' : ''}`,
    `  dropped_iterations: ${dropped}${dropped ? '   <-- INVALID: a closed loop should never drop' : ' (closed loop: cannot drop)'}`,
  ];
  return summaryOutputs('throughput-summary.json', report, lines);
}
