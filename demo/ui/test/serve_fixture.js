#!/usr/bin/env node
'use strict';
/**
 * Serves the dashboard with canned data, for visual checks.
 *
 * The real collector holds /events open forever, which means headless Chrome
 * never reaches "load finished" and never takes its screenshot. This serves the
 * same event shapes but ENDS the stream after a fixed number of samples, so a
 * browser can load the page, draw it and exit.
 *
 * The samples are replayed from a real recording when one exists, so the
 * screenshots show real numbers rather than invented ones.
 *
 * Usage: node test/serve_fixture.js [port] [samples]
 */

const http = require('http');
const fs = require('fs');
const path = require('path');

const UI = path.resolve(__dirname, '..');
const RECORDINGS = path.resolve(UI, '..', 'recordings');
const PORT = Number(process.argv[2] || 9210);
const SAMPLES = Number(process.argv[3] || 60);

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.json': 'application/json',
};

let table = { sites: [], cluster_count: 0, clusters: {}, system_cluster: null, slab_classes: [], budget: {} };
try { table = require('../../table').readTable(); } catch { /* the page must survive this too */ }

/** Metrics events from the most recent SAMM recording, or synthesised. */
function samples() {
  let file = null;
  try {
    file = fs.readdirSync(RECORDINGS).filter((n) => n.includes('-samm-') && n.endsWith('.jsonl'))
      .map((n) => ({ n, t: fs.statSync(path.join(RECORDINGS, n)).mtimeMs }))
      .sort((a, b) => b.t - a.t)[0];
  } catch { /* none */ }
  if (file) {
    const rows = fs.readFileSync(path.join(RECORDINGS, file.n), 'utf8').trim().split('\n')
      .map((l) => { try { return JSON.parse(l); } catch { return null; } })
      .filter((r) => r && r.event === 'metrics' && r.data.up)
      .map((r) => r.data);
    if (rows.length >= 10) {
      // The busiest stretch, so the screenshot is not of a warm-up.
      const start = Math.max(0, Math.floor(rows.length / 2) - Math.floor(SAMPLES / 2));
      return rows.slice(start, start + SAMPLES);
    }
  }
  const now = Date.now();
  return Array.from({ length: SAMPLES }, (_, i) => ({
    t: now + i * 1000, up: true, rss_mb: 600 + i * 4, peak_rss_mb: 600 + i * 4, limit_mb: 1024,
    cpu_pct: 80, throttled_periods: 100 + i * 8, oom_kills: 0, faults_per_sec: 3000,
    rps: 890 + (i % 7) * 10, e2e_p95: 1300 + (i % 5) * 40, alloc_p95: 180,
    dropped: 100 + i * 2, failed_pct: 0, vus: 400, allocator: null,
  }));
}

const STATUS = {
  label: 'SAMM', mode: 'samm', container_up: true, running: false, run: null,
  switching: false, replaying: false, defaults: { k: '2.5', seed: 2025, minutes: 3 },
  loads: ['1.0', '1.5', '2.0', '2.5'], replay: true,
};

const json = (res, body) => {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
};

http.createServer((req, res) => {
  const url = req.url.split('?')[0];

  if (url === '/status') return json(res, STATUS);
  if (url === '/table') return json(res, table);
  if (url === '/history') return json(res, { runs: [] });
  if (url === '/recordings') return json(res, { recordings: [] });

  if (url === '/events') {
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
    res.write(`event: hello\ndata: ${JSON.stringify({ label: 'SAMM', container: 'fixture' })}\n\n`);
    for (const s of samples()) res.write(`event: metrics\ndata: ${JSON.stringify(s)}\n\n`);
    res.end();                       // <- the whole point: a stream that finishes
    return;
  }

  const file = path.normalize(path.join(UI, url === '/' ? 'index.html' : url));
  if (!file.startsWith(UI) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
    res.writeHead(404); return res.end();
  }
  res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
  fs.createReadStream(file).pipe(res);
}).listen(PORT, () => console.log(`fixture on http://localhost:${PORT}/  (${SAMPLES} samples, stream ends)`));
