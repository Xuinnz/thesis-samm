#!/usr/bin/env node
'use strict';

/**
 * Host-side metrics collector for the live demo.
 *
 * Runs OUTSIDE Docker and gathers everything from sources that cannot perturb
 * the container under measurement:
 *
 *   cgroup files on the host   RSS, CPU, throttling, page faults, OOM kills
 *   k6 REST API :6565          throughput, latency, dropped, failed
 *   /samm/stats (optional)     allocator internals -- the only source inside
 *
 * Thirteen of the fourteen metric groups in a benchmark result already come
 * from outside the container, so almost nothing here needs the server's help.
 * A cgroup read from the host costs the container exactly zero: it is a
 * different process reading a different file, and the container cannot observe
 * it. k6 is already running and already exposes its metrics.
 *
 * WHY NOT AN ENDPOINT ON THE NODE SERVER
 *
 * An earlier instrument in this project -- a PerformanceObserver on GC -- was
 * present in BOTH conditions and still skewed the comparison, because it
 * delayed the event-loop turns that run SAMM's region closes and only SAMM has
 * regions. Measured: 17,669 capacity fallbacks with it on, 1,703 with it off.
 * Symmetric presence is not the same as symmetric effect. Anything that runs
 * inside the measured process is suspect; anything on the host is not.
 *
 * Emits Server-Sent Events. SSE rather than WebSockets because the traffic is
 * one-directional, it is plain HTTP, it reconnects by itself, and a recorded
 * stream replays through exactly the same code path as a live one.
 *
 * Usage:
 *   node collector.js --container samm-demo --label SAMM
 *   node collector.js --replay recordings/2026-09-18T10-00.jsonl
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

// ---------------------------------------------------------------- arguments
function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}
const CONTAINER = arg('container', 'samm-demo');
const LABEL = arg('label', CONTAINER);
const PORT = Number(arg('port', 9100));
const K6_API = arg('k6', 'http://127.0.0.1:6565');
const SERVER = arg('server', 'http://127.0.0.1:3000');
const INTERVAL_MS = Number(arg('interval', 1000));
const REPLAY = arg('replay', null);
// Sent in every hello. A page left open across a collector restart (a new
// replay, say) reconnects on its own; this is how it knows to start clean.
const SESSION = Date.now();
const RECORD_DIR = path.join(__dirname, 'recordings');
const UI_DIR = path.join(__dirname, 'ui');
const { readTable } = require('./table');
const k6dash = require('./k6dash');
const { performance } = require('perf_hooks');
const REPO = path.resolve(__dirname, '..');

// Initial mode. POST /mode switches it at run time.
let MODE = arg('mode', 'samm');          // 'samm' | 'baseline'

// Pre-fault SAMM's floors at container start (SAMM_WARMUP). Off by default, as
// in every benchmark: warming commits the full characterized floor before the
// first request, so RSS reports the reservation rather than the demand. The
// dashboard can flip it for a demo; runs made with it on are labelled as such.
let WARMUP = arg('warmup', 'false') === 'true';

// Rolling latency comes from k6's own dashboard, one window at a time.
const WINDOW_S = Number(arg('window', 5));
const K6_DASH_PORT = Number(arg('k6-dashboard-port', 5665));
const K6_ADDRESS = K6_API.replace(/^https?:\/\//, '');

// Load points, identical to run_comparison.sh / run_replicates.sh: arrival rate
// scales by k and every hold by 1/k, so live bytes stay constant and only CPU
// pressure rises.
const { LOAD } = require('./loads');
const RUN_DEFAULTS = { k: arg('k', '2.5'), seed: Number(arg('seed', 2025)), minutes: Number(arg('minutes', 3)) };
const JEMALLOC_SO = '/usr/lib/x86_64-linux-gnu/libjemalloc.so.2';

// ------------------------------------------------------------------- cgroup
// Resolved once per container start. The path disappears when the container
// dies, which is itself the signal that it died -- the same mechanism the
// benchmark harness uses to tell "slow" from "gone".
let cgroupDir = null;
let cgroupFor = null;

function findCgroup(name) {
  if (cgroupFor === name && cgroupDir && fs.existsSync(path.join(cgroupDir, 'memory.current'))) {
    return cgroupDir;
  }
  let id;
  try {
    // stdio ignored for stderr: "no such object" is the normal answer while the
    // container is down or switching, and it is polled every second.
    id = execFileSync('docker', ['inspect', '-f', '{{.Id}}', name],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch { cgroupDir = null; cgroupFor = name; return null; }
  const candidates = [
    `/sys/fs/cgroup/system.slice/docker-${id}.scope`,
    `/sys/fs/cgroup/docker/${id}`,
    `/sys/fs/cgroup/${id}`,
  ];
  cgroupDir = candidates.find((p) => { try { return fs.existsSync(path.join(p, 'memory.current')); } catch { return false; } }) || null;
  cgroupFor = name;
  return cgroupDir;
}

function readNum(dir, file) {
  try { return Number(fs.readFileSync(path.join(dir, file), 'utf8').trim()); } catch { return null; }
}
function readKeyed(dir, file, key) {
  try {
    for (const line of fs.readFileSync(path.join(dir, file), 'utf8').split('\n')) {
      const [k, v] = line.split(' ');
      if (k === key) return Number(v);
    }
  } catch { /* gone */ }
  return null;
}

// ---------------------------------------------------------------------- k6
function getJson(url, timeoutMs = 400) {
  return new Promise((resolve) => {
    const req = http.get(url, { timeout: timeoutMs }, (res) => {
      if (res.statusCode !== 200) { res.resume(); return resolve(null); }
      let body = '';
      res.on('data', (d) => { body += d; });
      res.on('end', () => { try { resolve(JSON.parse(body)); } catch { resolve(null); } });
    });
    req.on('error', () => resolve(null));
    req.on('timeout', () => { req.destroy(); resolve(null); });
  });
}

function k6Metric(payload, id) {
  if (!payload || !Array.isArray(payload.data)) return null;
  const m = payload.data.find((x) => x.id === id);
  return m && m.attributes ? m.attributes.sample : null;
}

// -------------------------------------------------------------- state/deltas
// Rates are taken over MONOTONIC time. This machine's wall clock is stepped
// forward ~3.4 s every 32 s (WSL2 time sync), and dividing one real second of
// counter growth by a four-second wall-clock gap drew a fake 70% dip in
// throughput and CPU every half minute -- in lockstep on both machines, which
// made it look like part of the workload.
const prev = { mono: null, cpuUsec: null, faults: null, reqs: null };

// The newest k6 dashboard window, while a run is in progress.
let rolling = null;

function rate(curr, last, seconds) {
  if (curr === null || last === null || seconds <= 0) return null;
  const d = curr - last;
  return d < 0 ? null : d / seconds;   // negative means the cgroup was replaced
}

async function sample() {
  const now = Date.now();
  const mono = performance.now();
  const dt = prev.mono === null ? 0 : (mono - prev.mono) / 1000;
  const dir = findCgroup(CONTAINER);

  const out = {
    // t is wall clock, for humans and file names. tm is monotonic ms, and it
    // is what every rate and chart axis must use.
    t: now,
    tm: +mono.toFixed(1),
    label: LABEL,
    container: CONTAINER,
    up: Boolean(dir),
    rss_mb: null, peak_rss_mb: null, limit_mb: null,
    cpu_pct: null, throttled_periods: null, oom_kills: null,
    faults_per_sec: null, faults_total: null,
    rps: null, requests: null, e2e_p95: null, e2e_med: null, alloc_p95: null, alloc_med: null,
    dropped: null, failed_pct: null, vus: null,
    allocator: null,
  };

  if (dir) {
    const cur = readNum(dir, 'memory.current');
    const peak = readNum(dir, 'memory.peak');
    const lim = readNum(dir, 'memory.max');
    out.rss_mb = cur === null ? null : +(cur / 1048576).toFixed(1);
    out.peak_rss_mb = peak === null ? null : +(peak / 1048576).toFixed(1);
    out.limit_mb = lim === null || !Number.isFinite(lim) ? null : +(lim / 1048576).toFixed(0);
    out.oom_kills = readKeyed(dir, 'memory.events', 'oom_kill');
    out.throttled_periods = readKeyed(dir, 'cpu.stat', 'nr_throttled');

    const cpuUsec = readKeyed(dir, 'cpu.stat', 'usage_usec');
    const faults = readKeyed(dir, 'memory.stat', 'pgfault');
    const cpuRate = rate(cpuUsec, prev.cpuUsec, dt);      // usec of CPU per second
    out.cpu_pct = cpuRate === null ? null : +(cpuRate / 10000).toFixed(1);  // /1e6 *100
    out.faults_per_sec = Math.round(rate(faults, prev.faults, dt) ?? 0) || null;
    out.faults_total = faults;
    prev.cpuUsec = cpuUsec;
    prev.faults = faults;
  } else {
    prev.cpuUsec = null; prev.faults = null;
  }

  const k6 = await getJson(`${K6_API}/v1/metrics`);
  if (k6) {
    const reqs = k6Metric(k6, 'http_reqs');
    const dur = k6Metric(k6, 'http_req_duration');
    const proc = k6Metric(k6, 'processing_time');
    const drop = k6Metric(k6, 'dropped_iterations');
    const fail = k6Metric(k6, 'http_req_failed');
    const vus = k6Metric(k6, 'vus');
    // http_reqs carries a running "rate", but it is cumulative over the whole
    // test. Differencing the count gives the rate over the last interval, which
    // is what a live graph should show.
    const count = reqs ? reqs.count : null;
    // Cumulative, so the page can report dropped iterations as a share of the
    // whole run so far -- the same ratio the run summary reports at the end.
    out.requests = count;
    out.rps = Math.round(rate(count, prev.reqs, dt) ?? (reqs ? reqs.rate : 0)) || null;
    prev.reqs = count;
    // NOTE p95, not p99. k6's REST API formats trends as a fixed set
    // (avg/min/med/max/p(90)/p(95)); p99 is only available from the end-of-test
    // summary. Showing a live "p99" that differs from the reported one invites
    // exactly the question you do not want.
    if (dur) { out.e2e_p95 = +(dur['p(95)'] ?? 0).toFixed(1); out.e2e_med = +(dur.med ?? 0).toFixed(1); }
    if (proc) { out.alloc_p95 = +(proc['p(95)'] ?? 0).toFixed(2); out.alloc_med = +(proc.med ?? 0).toFixed(2); }
    if (drop) out.dropped = drop.count ?? null;
    if (fail) out.failed_pct = +((fail.value ?? 0) * 100).toFixed(2);
    if (vus) out.vus = vus.value ?? null;
  } else {
    prev.reqs = null;
  }

  // Both images expose this. The baseline answers with a null allocator so the
  // two containers receive identical polling traffic -- same request rate, same
  // parse, same event-loop turn. Without that, only SAMM would be paying for
  // being observed.
  const stats = await getJson(`${SERVER}/samm/stats`);
  if (stats) out.allocator = stats.allocator === null ? null : stats;

  // Latency over the last dashboard window, if one arrived recently enough to
  // still describe "now". Older than two windows means k6 has gone quiet.
  const fresh = rolling && mono - rolling.mono < 2000 * (rolling.window_s || WINDOW_S);
  out.e2e_p95_roll = fresh ? rolling.e2e_p95 : null;
  out.e2e_p99_roll = fresh ? rolling.e2e_p99 : null;
  out.alloc_p95_roll = fresh ? rolling.alloc_p95 : null;
  out.alloc_p99_roll = fresh ? rolling.alloc_p99 : null;
  out.roll_window_s = fresh ? rolling.window_s : null;
  out.warmup = MODE === 'samm' && WARMUP;

  prev.mono = mono;
  return out;
}

/**
 * Why the container is gone. Docker keeps the stopped container around (no
 * --rm), so this still answers after the death -- which matters, because the
 * cgroup files disappear the moment it dies and take oom_kill with them.
 */
async function postMortem(last) {
  const state = { oom_killed: null, exit_code: null, finished_at: null, docker_status: null };
  const r = await sh('docker', ['inspect', CONTAINER, '--format',
    '{{.State.OOMKilled}}|{{.State.ExitCode}}|{{.State.FinishedAt}}|{{.State.Status}}']);
  if (r.ok) {
    const [oom, code, at, status] = r.out.trim().split('|');
    state.oom_killed = oom === 'true';
    state.exit_code = Number(code);
    state.finished_at = at;
    state.docker_status = status;
  }
  // Docker's OOMKilled flag is the only trustworthy answer. Exit 137 is plain
  // SIGKILL: the kernel's OOM killer leaves it behind, but so does `docker
  // kill` and so does a Ctrl-C on the right process. Calling every 137 an OOM
  // would announce "killed for exceeding the memory limit" to a room full of
  // examiners whenever anyone stopped a container by hand. The cgroup's own
  // oom_kill counter cannot fill the gap either: it disappears with the
  // container, and the real baseline death was sampled at oom_kills = 0.
  const sigkill = state.exit_code === 137;
  const oom = state.oom_killed === true || Boolean(last && last.oom_kills > 0);
  return {
    event: 'died',
    ...state,
    oom,
    sigkill,
    // True only when Docker could not be asked: then 137 is all we have.
    uncertain: state.oom_killed === null && sigkill,
    during_run: Boolean(k6Proc),
    run: activeRun,
    last: last ? {
      rss_mb: last.rss_mb, peak_rss_mb: last.peak_rss_mb, limit_mb: last.limit_mb,
      oom_kills: last.oom_kills, t: last.t,
    } : null,
  };
}

// ---------------------------------------------------------------- SSE plumbing
const clients = new Set();
let recording = null;
let replaying = false;

function emit(event, data) {
  const frame = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const res of clients) { try { res.write(frame); } catch { clients.delete(res); } }
  if (recording) recording.write(JSON.stringify({ event, data }) + '\n');
}

// Records ONLY while a run is in progress. The first version recorded from
// startup unconditionally, and a collector left running by mistake wrote 2,055
// events over 34 minutes -- almost all of them "container down". Idle metrics
// still stream live over SSE, so an audience sees the quiet container; they
// just are not written to disk.
function startRecording(tag) {
  fs.mkdirSync(RECORD_DIR, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const file = path.join(RECORD_DIR, `${LABEL}-${tag}-${stamp}.jsonl`);
  recording = fs.createWriteStream(file, { flags: 'a' });
  console.log(`[collector] recording -> ${file}`);
  return file;
}

function stopRecording() {
  if (recording) { recording.end(); recording = null; }
}

// A recorded run replays through the identical event stream, so the frontend
// cannot tell the two apart. That is the whole point: rehearse, record, and if
// the live run misbehaves in front of an audience, replay the good one.
async function replay(file) {
  replaying = true;
  const lines = fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean);
  console.log(`[collector] replaying ${lines.length} events from ${path.basename(file)}`);
  let last = null;
  for (const line of lines) {
    const { event, data } = JSON.parse(line);
    const at = data && (data.tm ?? data.t);
    if (last !== null && at) {
      await new Promise((r) => setTimeout(r, Math.min(5000, Math.max(0, at - last))));
    }
    if (at) last = at;
    emit(event, data);
  }
  emit('stage', { name: 'replay', status: 'done' });
  replaying = false;
}


// ============================================================ control layer
const { spawn, execFile } = require('child_process');

let k6Proc = null;
let activeRun = null;        // { id, mode, k, seed, minutes, file, startedAt, summary }
let switching = false;

function sh(cmd, args) {
  return new Promise((resolve) => {
    execFile(cmd, args, { encoding: 'utf8' }, (err, stdout, stderr) =>
      resolve({ ok: !err, out: (stdout || '') + (stderr || '') }));
  });
}

// Container arguments mirror _bench-lib.sh's run_condition exactly, so a demo
// container is the same container the benchmark measures. The two images are
// NOT interchangeable -- the baseline ships no allocator and the SAMM server
// refuses to start without it -- so switching mode is a stop and a start, not a
// flag flipped inside a running process.
function containerArgs(mode, k) {
  const L = LOAD[k];
  const common = [
    'run', '-d', '--name', CONTAINER,
    '--memory=1024m', '--memory-swap=1024m', '--cpus=1.0',
    '-p', `${new URL(SERVER).port || 3000}:3000`,
    '-e', 'SHADOW_PROFILER_ENABLED=false', '-e', 'SAMM_TELEMETRY=false',
    '-e', `PROCESS_MAX_BYTES=${16 * 1024 * 1024}`,
    '-e', `HOLD_SCALE=${L.HOLD_SCALE}`, '-e', `PROCESS_HOLD_MS=${L.PROCESS_HOLD_MS}`,
    '-e', `LD_PRELOAD=${JEMALLOC_SO}`,
  ];
  if (mode === 'baseline') return [...common, 'samm-baseline:bench'];
  const samm = [...common,
    '-e', 'SAMM_ALLOCATOR_ENABLED=true', '-e', 'SAMM_RECLAIM_POLICY=none', '-e', `SAMM_WARMUP=${WARMUP}`];
  // The table is characterized at k=1.0. Other load points keep lambda*W, and
  // therefore every quota, unchanged -- but the fingerprint hashes lambda and W
  // separately and cannot see that, so it has to be told.
  if (k !== '1.0') samm.push('-e', 'SAMM_ALLOW_WORKLOAD_MISMATCH=true');
  return [...samm, 'samm-enabled:bench'];
}

async function waitHealthy(timeoutMs = 60000) {
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) {
    if (await getJson(`${SERVER}/health`, 800)) return true;
    await new Promise((r) => setTimeout(r, 500));
  }
  return false;
}

async function startContainer(mode, k) {
  emit('stage', { name: 'container', status: 'starting', mode });
  await sh('docker', ['rm', '-f', CONTAINER]);
  cgroupDir = null; cgroupFor = null;            // force re-resolution
  prev.cpuUsec = null; prev.faults = null; prev.reqs = null;
  const r = await sh('docker', containerArgs(mode, k));
  if (!r.ok) { emit('stage', { name: 'container', status: 'failed', mode, detail: r.out.trim() }); return false; }
  if (!(await waitHealthy())) {
    const logs = await sh('docker', ['logs', '--tail', '25', CONTAINER]);
    // The workload guard refusing to boot looks exactly like a crash from the
    // outside. Surface its message rather than a spinner.
    emit('stage', { name: 'container', status: 'failed', mode, detail: logs.out.trim() });
    return false;
  }
  MODE = mode;
  emit('stage', { name: 'container', status: 'ready', mode });
  return true;
}

async function switchMode(mode, k) {
  if (switching) return { ok: false, error: 'a mode switch is already in progress' };
  if (k6Proc) return { ok: false, error: 'a load test is running; stop it first' };
  switching = true;
  try { return { ok: await startContainer(mode, k), mode }; }
  finally { switching = false; }
}

function summaryFrom(exportPath) {
  let s;
  try { s = JSON.parse(fs.readFileSync(exportPath, 'utf8')); } catch { return null; }
  const m = s.metrics || {};
  const g = (name, field) => (m[name] && m[name][field] !== undefined ? m[name][field] : null);
  const reqs = g('http_reqs', 'count') || 0;
  const dropped = g('dropped_iterations', 'count') || 0;
  const dir = cgroupDir;
  const peak = dir ? readNum(dir, 'memory.peak') : null;
  return {
    mode: MODE, label: LABEL,
    requests: reqs,
    throughput_rps: g('http_reqs', 'rate'),
    dropped, dropped_pct: reqs + dropped ? (100 * dropped) / (reqs + dropped) : 0,
    failed_pct: (g('http_req_failed', 'value') || 0) * 100,
    // p99 is available HERE, from the end-of-test summary, and nowhere live.
    e2e_p95: g('http_req_duration', 'p(95)'), e2e_p99: g('http_req_duration', 'p(99)'),
    alloc_p95: g('processing_time', 'p(95)'), alloc_p99: g('processing_time', 'p(99)'),
    peak_rss_mb: peak === null ? null : +(peak / 1048576).toFixed(1),
    oom_kills: dir ? readKeyed(dir, 'memory.events', 'oom_kill') : null,
    container_survived: Boolean(dir),
  };
}

async function startRun({ k = RUN_DEFAULTS.k, seed = RUN_DEFAULTS.seed, minutes = RUN_DEFAULTS.minutes } = {}) {
  if (k6Proc) return { ok: false, error: 'a load test is already running' };
  if (!LOAD[k]) return { ok: false, error: `k must be one of ${Object.keys(LOAD).join(', ')}` };
  if (!findCgroup(CONTAINER)) return { ok: false, error: `container ${CONTAINER} is not running; POST /mode first` };

  // Reset the kernel's high-water mark so the peak reported at the end belongs
  // to this run, not to whatever the container did while idle beforehand.
  try { fs.writeFileSync(path.join(cgroupDir, 'memory.peak'), '0'); } catch { /* needs root; peak then spans idle too */ }

  const L = LOAD[k];
  const warm = MODE === 'samm' && WARMUP;
  // A warmed run is a different condition, so it must never be mistaken for a
  // cold one in the history or as a reference line.
  const id = `${MODE}-k${k}-s${seed}${warm ? '-warm' : ''}`;
  const exportPath = path.join(RECORD_DIR, `${LABEL}-${id}-summary.json`);
  fs.mkdirSync(RECORD_DIR, { recursive: true });
  const file = startRecording(id);
  activeRun = { id, mode: MODE, k, seed, minutes, file, warmup: warm, startedAt: Date.now() };

  const tm = path.join(REPO, 'datasets/azure-trace-2019/processed/traffic-models');
  const env = {
    ...process.env,
    BASE_URL: SERVER,
    MARKOV_MATRIX_PATH: path.join(tm, 'markov_transition_matrix.csv'),
    TRAFFIC_SERIES_PATH: path.join(tm, 'traffic_state_series.csv'),
    JITTER_PARAMS_PATH: path.join(tm, 'jitter_parameters.json'),
    PAYLOAD_CSV_PATH: path.join(REPO, 'datasets/azure-trace-2019/processed/memory-models/memory_payload_allocations.csv'),
    MIN_RPS: '5', MAX_RPS: String(L.MAX_RPS),
    SIMULATION_MINUTES: String(minutes),
    PRE_ALLOCATED_VUS: '400', MAX_VUS: '1400',
    SCHEDULE_SEED: String(seed),
    HOLD_SCALE: String(L.HOLD_SCALE), PROCESS_HOLD_MS: String(L.PROCESS_HOLD_MS),
    // k6's built-in dashboard aggregates per window; the collector reads each
    // window to get a rolling p95/p99 (see k6dash.js). Demo runs only.
    K6_WEB_DASHBOARD: 'true',
    K6_WEB_DASHBOARD_HOST: '127.0.0.1',
    K6_WEB_DASHBOARD_PORT: String(K6_DASH_PORT),
    K6_WEB_DASHBOARD_PERIOD: `${WINDOW_S}s`,
  };
  const args = ['run', '--address', K6_ADDRESS,
    '--summary-export', exportPath,
    '--summary-trend-stats', 'avg,min,med,p(90),p(95),p(99),max',
    'samm-load-test.js'];

  emit('stage', { name: 'k6', status: 'running', ...activeRun });
  k6Proc = spawn('k6', args, { cwd: path.join(REPO, 'load-generator/k6-scenarios'), env });
  rolling = null;
  const dash = k6dash.follow({
    port: K6_DASH_PORT,
    onWindow: (w) => { rolling = { ...w, mono: performance.now() }; },
    onError: (err) => emit('log', { stage: 'k6-dashboard', line: err.message }),
  });
  k6Proc.stdout.on('data', () => {});                 // drain; k6 progress is noise here
  k6Proc.stderr.on('data', (d) => {
    const line = d.toString().trim();
    if (/level=error/.test(line)) emit('log', { stage: 'k6', line: line.slice(0, 400) });
  });
  k6Proc.on('exit', (code) => {
    dash.stop();
    rolling = null;
    const summary = summaryFrom(exportPath);
    const run = activeRun;
    k6Proc = null; activeRun = null;
    emit('stage', { name: 'k6', status: code === 0 ? 'done' : 'stopped', code, id: run && run.id });
    if (summary) {
      const final = {
        ...summary,
        run,
        finished_at: new Date().toISOString(),
        recording: run && run.file ? path.basename(run.file) : null,
      };
      emit('final', final);
      // Archived so the dashboard can show past runs after a restart. The
      // 'final' event alone lives only as long as the page is open.
      try {
        fs.writeFileSync(
          path.join(RECORD_DIR, `${LABEL}-${run.id}-${final.finished_at.replace(/[:.]/g, '-')}-final.json`),
          JSON.stringify(final, null, 2),
        );
      } catch (err) { console.error('[collector] could not archive the summary:', err.message); }
    }
    stopRecording();
  });
  return { ok: true, run: activeRun };
}

function stopRun() {
  if (!k6Proc) return { ok: false, error: 'no load test is running' };
  k6Proc.kill('SIGINT');                             // k6 still writes its summary on SIGINT
  return { ok: true };
}

// ------------------------------------------------------------ static UI
const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.json': 'application/json',
  '.png': 'image/png', '.ico': 'image/x-icon', '.woff2': 'font/woff2',
};

// The dashboard is served from the collector itself, so the page and its data
// share an origin and the demo needs one process, not two.
function serveStatic(req, res) {
  if (req.method !== 'GET') return false;
  const rel = decodeURIComponent(req.url.split('?')[0]);
  const file = path.normalize(path.join(UI_DIR, rel === '/' ? 'index.html' : rel));
  if (!file.startsWith(UI_DIR)) { res.writeHead(403); res.end(); return true; }
  let target = file;
  let stat;
  try { stat = fs.statSync(target); } catch { return false; }
  // A directory serves its index, so "/" and a stray "//" both land on the page.
  if (stat.isDirectory()) {
    target = path.join(target, 'index.html');
    try { stat = fs.statSync(target); } catch { return false; }
  }
  if (!stat.isFile()) return false;
  res.writeHead(200, {
    'Content-Type': MIME[path.extname(target)] || 'application/octet-stream',
    // No caching: during rehearsal the page is edited between refreshes.
    'Cache-Control': 'no-store',
  });
  fs.createReadStream(target).pipe(res);
  return true;
}

// Recording files are named "<label>-<mode>-k<k>-s<seed>-<stamp>.jsonl", which
// is enough for the dashboard to find the other mode's last run and draw it as
// a reference line.
function listRecordings() {
  let names = [];
  try { names = fs.readdirSync(RECORD_DIR); } catch { return []; }
  return names
    .filter((n) => n.endsWith('.jsonl'))
    .map((name) => {
      const m = name.match(/^(.*)-(samm|baseline)-k([\d.]+)-s(\d+)-(.+)\.jsonl$/);
      const st = fs.statSync(path.join(RECORD_DIR, name));
      return {
        name, bytes: st.size, mtime: st.mtimeMs,
        label: m ? m[1] : null, mode: m ? m[2] : null,
        k: m ? m[3] : null, seed: m ? Number(m[4]) : null,
        warmup: /-warm-/.test(name),
      };
    })
    .sort((a, b) => b.mtime - a.mtime);
}

/**
 * Every run this machine has finished, newest first.
 *
 * Archived summaries (written when a run ends) carry everything, including the
 * p99s that only exist in k6's end-of-test summary. Recordings made before that
 * archiving existed -- or by a collector that was killed before the run ended --
 * are reconstructed from their own samples instead, and marked as such: mode,
 * peak RSS and whether the container survived are all the samples can honestly
 * give. Nothing is invented to fill the other columns.
 */
function history() {
  let names = [];
  try { names = fs.readdirSync(RECORD_DIR); } catch { return []; }

  const archived = [];
  for (const name of names.filter((n) => n.endsWith('-final.json'))) {
    try { archived.push({ ...JSON.parse(fs.readFileSync(path.join(RECORD_DIR, name), 'utf8')), file: name, source: 'archive' }); }
    catch { /* a half-written file is simply skipped */ }
  }
  const covered = new Set(archived.map((r) => r.recording).filter(Boolean));

  const reconstructed = [];
  for (const rec of listRecordings()) {
    if (covered.has(rec.name)) continue;
    let peak = null, samples = 0, lastUp = null, saw = false;
    try {
      for (const line of fs.readFileSync(path.join(RECORD_DIR, rec.name), 'utf8').split('\n')) {
        if (!line) continue;
        let row;
        try { row = JSON.parse(line); } catch { continue; }
        if (row.event !== 'metrics' || !row.data) continue;
        samples++;
        if (row.data.up) { saw = true; lastUp = true; if (row.data.peak_rss_mb !== null) peak = Math.max(peak ?? 0, row.data.peak_rss_mb); }
        else if (saw) lastUp = false;
      }
    } catch { continue; }
    if (!samples) continue;
    reconstructed.push({
      source: 'recording',
      mode: rec.mode, recording: rec.name, file: rec.name,
      finished_at: new Date(rec.mtime).toISOString(),
      run: { k: rec.k, seed: rec.seed, minutes: null, warmup: rec.warmup },
      requests: null, throughput_rps: null, dropped: null, dropped_pct: null, failed_pct: null,
      e2e_p95: null, e2e_p99: null, alloc_p95: null, alloc_p99: null,
      peak_rss_mb: peak, oom_kills: null,
      container_survived: lastUp === null ? null : lastUp,
      samples,
    });
  }

  return [...archived, ...reconstructed]
    .sort((a, b) => String(b.finished_at).localeCompare(String(a.finished_at)));
}

function readBody(req) {
  return new Promise((resolve) => {
    let b = ''; req.on('data', (d) => { b += d; });
    req.on('end', () => { try { resolve(b ? JSON.parse(b) : {}); } catch { resolve({}); } });
  });
}

function send(res, code, obj) {
  res.writeHead(code, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
  res.end(JSON.stringify(obj));
}

async function control(req, res) {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'GET,POST',
      'Access-Control-Allow-Headers': 'Content-Type' });
    res.end(); return true;
  }
  if (req.method === 'GET' && req.url === '/status') {
    send(res, 200, { label: LABEL, mode: MODE, container_up: Boolean(findCgroup(CONTAINER)),
      running: Boolean(k6Proc), run: activeRun, switching, replaying, warmup: WARMUP,
      defaults: RUN_DEFAULTS, loads: Object.keys(LOAD), replay: Boolean(REPLAY) });
    return true;
  }
  if (req.method === 'GET' && req.url === '/table') {
    // Read per request: a retrain then shows up on the next refresh.
    try { send(res, 200, readTable()); }
    catch (err) { send(res, 500, { error: 'routing table unavailable', detail: err.message }); }
    return true;
  }
  if (req.method === 'GET' && req.url === '/history') {
    send(res, 200, { runs: history() });
    return true;
  }
  if (req.method === 'GET' && req.url === '/recordings') {
    send(res, 200, { recordings: listRecordings() }); return true;
  }
  if (req.method === 'GET' && req.url.startsWith('/recordings/')) {
    const name = path.basename(decodeURIComponent(req.url.slice('/recordings/'.length)));
    const file = path.join(RECORD_DIR, name);
    if (!name.endsWith('.jsonl') || !fs.existsSync(file)) { send(res, 404, { error: 'no such recording' }); return true; }
    res.writeHead(200, { 'Content-Type': 'application/x-ndjson', 'Access-Control-Allow-Origin': '*' });
    fs.createReadStream(file).pipe(res);
    return true;
  }
  if (REPLAY && req.method === 'POST') { send(res, 409, { ok: false, error: 'collector is in replay mode' }); return true; }
  if (req.method === 'POST' && req.url === '/replay') {
    const b = await readBody(req);
    const name = path.basename(String(b.file || ''));
    const file = path.join(RECORD_DIR, name);
    if (!name.endsWith('.jsonl') || !fs.existsSync(file)) { send(res, 404, { ok: false, error: 'no such recording' }); return true; }
    if (k6Proc || switching || replaying) { send(res, 409, { ok: false, error: 'busy: a run, switch or replay is in progress' }); return true; }
    send(res, 202, { ok: true, replaying: name });
    replay(file);
    return true;
  }
  if (req.method === 'POST' && req.url === '/mode') {
    const b = await readBody(req);
    if (!['samm', 'baseline'].includes(b.mode)) { send(res, 400, { ok: false, error: 'mode must be samm or baseline' }); return true; }
    // Check refusals BEFORE answering. The first version replied 202 and only
    // then let switchMode() discover a run was in progress, so a request that
    // was never going to happen was reported as accepted.
    if (k6Proc) { send(res, 409, { ok: false, error: 'a load test is running; stop it first' }); return true; }
    if (switching) { send(res, 409, { ok: false, error: 'a mode switch is already in progress' }); return true; }
    send(res, 202, { ok: true, accepted: b.mode });   // the switch itself takes seconds; progress arrives over SSE
    switchMode(b.mode, String(b.k || RUN_DEFAULTS.k));
    return true;
  }
  if (req.method === 'POST' && req.url === '/warmup') {
    const b = await readBody(req);
    if (typeof b.enabled !== 'boolean') { send(res, 400, { ok: false, error: 'enabled must be true or false' }); return true; }
    if (k6Proc) { send(res, 409, { ok: false, error: 'a load test is running; stop it first' }); return true; }
    if (switching) { send(res, 409, { ok: false, error: 'a mode switch is already in progress' }); return true; }
    WARMUP = b.enabled;
    // Warmup happens at container start, so SAMM has to be restarted for the
    // new setting to mean anything. The baseline has nothing to warm.
    const restart = MODE === 'samm';
    send(res, 202, { ok: true, warmup: WARMUP, restarting: restart });
    if (restart) switchMode('samm', String(b.k || RUN_DEFAULTS.k));
    return true;
  }
  if (req.method === 'POST' && req.url === '/run') {
    const r = await startRun(await readBody(req));
    send(res, r.ok ? 202 : 409, r); return true;
  }
  if (req.method === 'POST' && req.url === '/stop') { const r = stopRun(); send(res, r.ok ? 202 : 409, r); return true; }
  return false;
}

function shutdown() {
  if (k6Proc) k6Proc.kill('SIGINT');
  stopRecording();
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

// --------------------------------------------------------------------- server
const server = http.createServer(async (req, res) => {
  if (await control(req, res)) return;
  if (req.url === '/events') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive',
      'Access-Control-Allow-Origin': '*',
    });
    res.write(`event: hello\ndata: ${JSON.stringify({ label: LABEL, container: CONTAINER, replay: Boolean(REPLAY), session: SESSION })}\n\n`);
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
    return res.end(JSON.stringify({ ok: true, label: LABEL, clients: clients.size, replay: Boolean(REPLAY) }));
  }
  if (serveStatic(req, res)) return;
  res.writeHead(404); res.end();
});

server.listen(PORT, () => {
  console.log(`[collector] ${LABEL} on :${PORT}  (SSE at /events)`);
  console.log(`[collector] container=${CONTAINER} mode=${MODE} k6=${K6_API} server=${SERVER}`);
  console.log(`[collector] POST /mode {mode}   POST /run {k,seed,minutes}   POST /stop   GET /status`);
  console.log(`[collector] dashboard: http://localhost:${PORT}/   warmup=${WARMUP}   rolling window=${WINDOW_S}s`);
  if (REPLAY) { replay(REPLAY).catch((e) => console.error(e)); return; }
  // An up -> down transition is the interesting moment of the whole demo: the
  // baseline dying under load. Without this the dashboard would just go quiet.
  let wasUp = false;
  let lastUp = null;
  setInterval(async () => {
    try {
      const s = await sample();
      emit('metrics', s);
      if (wasUp && !s.up) emit('container', await postMortem(lastUp));
      wasUp = s.up;
      if (s.up) lastUp = s;
    } catch (e) { console.error('[collector] sample failed:', e.message); }
  }, INTERVAL_MS);
});
