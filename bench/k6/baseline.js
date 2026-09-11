// zero framework — local baseline load test (k6)
//
// Drives the same endpoints the in-tree Zig bench harness exercises, but via
// k6 so you get nicely formatted, exportable reports (console table + JSON
// + HTML). Run the zero bench server first, then point k6 at it:
//
//   ./zig-out/bin/bench --server            # serves on :8080
//   k6 run bench/k6/baseline.js              # defaults to http://localhost:8080
//
// Tune with env vars:
//   BASE_URL=http://localhost:8080  (target; any running zero app works)
//   VUS=25                          (concurrent users per endpoint)
//   DURATION=20s                    (per-endpoint ramp length)
//
// The endpoints are exercised sequentially (staggered startTimes) so each
// baseline number is isolated. Reports are written to bench/k6/report.json
// and bench/k6/report.html.

import http from 'k6/http';
import { check } from 'k6';
import { Trend, Counter } from 'k6/metrics';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';
const DURATION = __ENV.DURATION || '20s';
const VUS = parseInt(__ENV.VUS || '25', 10);
const durSec = parseInt(DURATION, 10) || 20;

// --- request bodies -------------------------------------------------------

// TestMsg { value: string } — field 1, wire type 2 (length-delimited).
// tag = (1 << 3) | 2 = 0x0a, then length, then UTF-8 bytes.
function protoBody() {
  const s = 'bench-proto-payload';
  const bytes = Array.from(s).map((c) => c.charCodeAt(0)); // ASCII payload
  return new Uint8Array([0x0a, bytes.length, ...bytes]);
}

const graphqlBody = JSON.stringify({ query: '{ hello }' });

// --- per-endpoint metrics -------------------------------------------------

const endpoints = {
  health: {
    url: '/.well-known/health',
    method: 'GET',
    trend: new Trend('ep_health_duration'),
    fails: new Counter('ep_health_fails'),
  },
  health_json: {
    url: '/.well-known/health',
    method: 'GET',
    accept: 'application/json',
    trend: new Trend('ep_health_json_duration'),
    fails: new Counter('ep_health_json_fails'),
  },
  health_html: {
    url: '/.well-known/health',
    method: 'GET',
    accept: 'text/html',
    trend: new Trend('ep_health_html_duration'),
    fails: new Counter('ep_health_html_fails'),
  },
  proto: {
    url: '/bench/proto',
    method: 'POST',
    body: protoBody(),
    ctype: 'application/x-protobuf',
    trend: new Trend('ep_proto_duration'),
    fails: new Counter('ep_proto_fails'),
  },
  graphql: {
    url: '/bench/graphql',
    method: 'POST',
    body: graphqlBody,
    ctype: 'application/json',
    trend: new Trend('ep_graphql_duration'),
    fails: new Counter('ep_graphql_fails'),
  },
  filestore: {
    url: '/bench/filestore',
    method: 'POST',
    body: 'x',
    trend: new Trend('ep_filestore_duration'),
    fails: new Counter('ep_filestore_fails'),
  },
};

function run(name) {
  const ep = endpoints[name];
  const params = {};
  if (ep.accept || ep.ctype) {
    params.headers = {};
    if (ep.accept) params.headers['Accept'] = ep.accept;
    if (ep.ctype) params.headers['Content-Type'] = ep.ctype;
  }
  const res = ep.method === 'POST'
    ? http.post(BASE + ep.url, ep.body, params)
    : http.get(BASE + ep.url, params);

  ep.trend.add(res.timings.duration);
  if (res.status !== 200) ep.fails.add(1);
  check(res, { 'status 200': (r) => r.status === 200 });
}

export function health() { run('health'); }
export function healthJson() { run('health_json'); }
export function healthHtml() { run('health_html'); }
export function proto() { run('proto'); }
export function graphql() { run('graphql'); }
export function filestore() { run('filestore'); }

// --- scenarios: run each endpoint in its own staggered executor ----------

const execFor = {
  health: 'health',
  health_json: 'healthJson',
  health_html: 'healthHtml',
  proto: 'proto',
  graphql: 'graphql',
  filestore: 'filestore',
};

const scenarios = {};
let i = 0;
for (const [name, _] of Object.entries(endpoints)) {
  scenarios[name] = {
    executor: 'constant-vus',
    vus: VUS,
    duration: DURATION,
    exec: execFor[name],
    startTime: `${i * durSec}s`,
    gracefulStop: '2s',
  };
  i += 1;
}

export const options = { scenarios };

// --- reporting ------------------------------------------------------------

export function handleSummary(data) {
  const rows = [];
  let totalReqs = 0;
  let totalFails = 0;

  for (const [name, ep] of Object.entries(endpoints)) {
    const m = (data.metrics[ep.trend.name] && data.metrics[ep.trend.name].values) || {};
    const f = (data.metrics[ep.fails.name] && data.metrics[ep.fails.name].values) || {};
    const n = m.n || 0;
    const fails = f.count || 0;
    totalReqs += n;
    totalFails += fails;
    rows.push({
      endpoint: name,
      reqs: n,
      fails: fails,
      rps: n > 0 ? (n / (durSec * VUS)) * VUS / VUS : 0, // placeholder; real rps below
      avg_ms: m.avg || 0,
      p95_ms: m.p95 || 0,
      p99_ms: m.p99 || 0,
      max_ms: m.max || 0,
    });
  }

  // Real throughput: reqs / (duration per endpoint) since endpoints run serially.
  for (const r of rows) {
    r.rps = r.reqs / durSec;
  }

  const pad = (s, w) => String(s).padEnd(w);
  const num = (v) => (v != null ? v.toFixed(2) : '0.00');

  let text = '\n=== zero framework baseline (k6) ===\n';
  text += `target=${BASE}  vus=${VUS}  duration=${DURATION}/endpoint\n\n`;
  text += `${pad('endpoint', 14)}${pad('reqs', 9)}${pad('fails', 8)}${pad('rps', 9)}${pad('avg_ms', 9)}${pad('p95_ms', 9)}${pad('p99_ms', 9)}${pad('max_ms', 9)}\n`;
  for (const r of rows) {
    text += `${pad(r.endpoint, 14)}${pad(r.reqs, 9)}${pad(r.fails, 8)}${pad(num(r.rps), 9)}${pad(num(r.avg_ms), 9)}${pad(num(r.p95_ms), 9)}${pad(num(r.p99_ms), 9)}${pad(num(r.max_ms), 9)}\n`;
  }
  text += `\ntotal reqs=${totalReqs}  total fails=${totalFails}\n`;

  const json = JSON.stringify(
    { target: BASE, vus: VUS, duration_per_endpoint: DURATION, endpoints: rows, total_reqs: totalReqs, total_fails: totalFails },
    null,
    2,
  );

  let html = '<html><head><meta charset="utf-8"><title>zero baseline</title>';
  html += '<style>body{font-family:monospace}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:4px 8px;text-align:right}th{background:#eee}</style>';
  html += '</head><body><h1>zero framework baseline</h1>';
  html += `<p>target=${BASE} | vus=${VUS} | duration=${DURATION}/endpoint</p>`;
  html += '<table><tr><th>endpoint</th><th>reqs</th><th>fails</th><th>rps</th><th>avg_ms</th><th>p95_ms</th><th>p99_ms</th><th>max_ms</th></tr>';
  for (const r of rows) {
    html += `<tr><td>${r.endpoint}</td><td>${r.reqs}</td><td>${r.fails}</td><td>${num(r.rps)}</td><td>${num(r.avg_ms)}</td><td>${num(r.p95_ms)}</td><td>${num(r.p99_ms)}</td><td>${num(r.max_ms)}</td></tr>`;
  }
  html += `</table></body></html>`;

  return {
    stdout: text,
    'bench/k6/report.json': json,
    'bench/k6/report.html': html,
  };
}
