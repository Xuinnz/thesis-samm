/**
 * Timing, phases and summary output shared by the internal-validation scenarios.
 *
 * Elapsed time comes from exec.instance.currentTestRunDuration, which k6 takes
 * from a monotonic clock. Wall-clock time is avoided on purpose: on WSL2 the
 * system clock can step forward by seconds during a run.
 */

import exec from 'k6/execution';

export function envNumber(name, fallback) {
  const raw = __ENV[name];
  if (raw === undefined || raw === '') {
    if (fallback === undefined) throw new Error(`${name} is required (no default on purpose -- see internal-validation/README.md)`);
    return fallback;
  }
  const value = Number(raw);
  if (!Number.isFinite(value) || value < 0) throw new Error(`${name} must be a non-negative number, got "${raw}"`);
  return value;
}

export function envList(name) {
  const raw = __ENV[name];
  if (raw === undefined || raw.trim() === '') return null;
  const values = raw.split(',').map((s) => Number(s.trim()));
  if (values.some((v) => !Number.isFinite(v) || v <= 0)) {
    throw new Error(`${name} must be a comma-separated list of positive numbers, got "${raw}"`);
  }
  return values;
}

/** Milliseconds since the test started (monotonic). */
export function elapsedMs() {
  return exec.instance.currentTestRunDuration;
}

/** Which phase a moment falls in, given warmup and measure lengths in ms. */
export function phaseAt(ms, warmupMs, measureMs) {
  if (ms < warmupMs) return 'warmup';
  if (ms < warmupMs + measureMs) return 'measure';
  return 'cooldown';
}

/**
 * One scenario per value, run back to back. Each step lasts stepSeconds and is
 * followed by a gap of gapSeconds, which is also its gracefulStop: in-flight
 * requests finish in the gap instead of spilling into the next step.
 *
 * build(value) returns the executor-specific fields. Returns the scenarios and,
 * per scenario name, the step's value and start time (ms since test start).
 */
export function sequentialSteps({ values, prefix, stepSeconds, gapSeconds, build }) {
  const scenarios = {};
  const steps = {};
  let start = 0;
  for (const value of values) {
    const name = `${prefix}_${String(value).replace('.', '_')}`;
    scenarios[name] = Object.assign({
      startTime: `${start}s`,
      gracefulStop: `${gapSeconds}s`,
      tags: { step: String(value) },
    }, build(value));
    steps[name] = { value, startMs: start * 1000 };
    start += stepSeconds + gapSeconds;
  }
  return { scenarios, steps, totalSeconds: start };
}

/**
 * Percentiles for summaryTrendStats: every 0.5 % from 0.5 to 99.5, plus the
 * far tail. With these, the summary carries the whole quantile function of a
 * Trend, not just p90/p95.
 */
export function quantileStats() {
  const stats = ['min', 'avg', 'med', 'max', 'count'];
  for (let p = 0.5; p < 100; p += 0.5) stats.push(`p(${Number(p.toFixed(1))})`);
  stats.push('p(99.9)', 'p(99.95)', 'p(99.99)');
  return stats;
}

export function metricValues(data, name) {
  const m = data.metrics[name];
  return m ? m.values : null;
}

export function metricCount(data, name) {
  const v = metricValues(data, name);
  return v && typeof v.count === 'number' ? v.count : 0;
}

/** Turns a summary Trend's values into { quantiles: {p: ms}, min, max, ... }. */
export function quantileTable(values) {
  if (!values) return null;
  const quantiles = {};
  for (const [key, v] of Object.entries(values)) {
    const m = key.match(/^p\(([\d.]+)\)$/);
    if (m) quantiles[m[1]] = v;
  }
  return { count: values.count || 0, min: values.min, avg: values.avg, med: values.med, max: values.max, quantiles };
}

/** handleSummary return value: the JSON file plus a short report on stdout. */
export function summaryOutputs(defaultPath, report, lines) {
  const path = __ENV.SUMMARY_PATH || defaultPath;
  return {
    [path]: JSON.stringify(report, null, 2),
    stdout: `\n${lines.join('\n')}\n  summary written to ${path}\n\n`,
  };
}
