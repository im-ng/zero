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
  index: { url: '/', method: 'GET', trend: new Trend('ep_index_duration'), fails: new Counter('ep_index_fails') },
  text: { url: '/text', method: 'GET', trend: new Trend('ep_text_duration'), fails: new Counter('ep_text_fails') },
  json: { url: '/json', method: 'GET', trend: new Trend('ep_json_duration'), fails: new Counter('ep_json_fails') },
  keys: { url: '/keys', method: 'GET', trend: new Trend('ep_keys_duration'), fails: new Counter('ep_keys_fails') },
  db: { url: '/db', method: 'GET', trend: new Trend('ep_db_duration'), fails: new Counter('ep_db_fails') },
  proto_get: { url: '/proto', method: 'GET', trend: new Trend('ep_proto_get_duration'), fails: new Counter('ep_proto_get_fails') },
  graphql_get: { url: '/graphql?query=' + encodeURIComponent('{ hello }'), method: 'GET', trend: new Trend('ep_graphql_get_duration'), fails: new Counter('ep_graphql_get_fails') },
  filestore_get: { url: '/filestore?key=bench-seed', method: 'GET', trend: new Trend('ep_filestore_get_duration'), fails: new Counter('ep_filestore_get_fails') },
  proto: {
    url: '/proto',
    method: 'POST',
    body: protoBody(),
    ctype: 'application/x-protobuf',
    trend: new Trend('ep_proto_duration'),
    fails: new Counter('ep_proto_fails'),
  },
  graphql: {
    url: '/graphql',
    method: 'POST',
    body: graphqlBody,
    ctype: 'application/json',
    trend: new Trend('ep_graphql_duration'),
    fails: new Counter('ep_graphql_fails'),
  },
  filestore: {
    url: '/filestore',
    method: 'POST',
    body: 'x',
    trend: new Trend('ep_filestore_duration'),
    fails: new Counter('ep_filestore_fails'),
  },
  // Round-1 datasources (DuckDB works in-memory; ts/solr/nosql need their
  // backend env vars configured on the bench server or they return 501).
  duckdb_write: { url: '/duckdb/write', method: 'GET', trend: new Trend('ep_duckdb_write_duration'), fails: new Counter('ep_duckdb_write_fails') },
  duckdb_query: { url: '/duckdb/query', method: 'GET', trend: new Trend('ep_duckdb_query_duration'), fails: new Counter('ep_duckdb_query_fails') },
  ts_write: { url: '/ts/write', method: 'GET', trend: new Trend('ep_ts_write_duration'), fails: new Counter('ep_ts_write_fails') },
  ts_query: { url: '/ts/query', method: 'GET', trend: new Trend('ep_ts_query_duration'), fails: new Counter('ep_ts_query_fails') },
  solr_index: { url: '/solr/index', method: 'GET', trend: new Trend('ep_solr_index_duration'), fails: new Counter('ep_solr_index_fails') },
  solr_query: { url: '/solr/query', method: 'GET', trend: new Trend('ep_solr_query_duration'), fails: new Counter('ep_solr_query_fails') },
  nosql_put: { url: '/nosql/put', method: 'GET', trend: new Trend('ep_nosql_put_duration'), fails: new Counter('ep_nosql_put_fails') },
  nosql_get: { url: '/nosql/get', method: 'GET', trend: new Trend('ep_nosql_get_duration'), fails: new Counter('ep_nosql_get_fails') },
};

for (const [name, ep] of Object.entries(endpoints)) {
  // Per-endpoint request counter. k6 v2 reports `.values.count` reliably for
  // custom Counters (the framework's `Trend` also exposes `count`, but a
  // `Trend` does not, so we count attempts with a Counter for an accurate
  // request total).
  ep.reqs = new Counter('ep_' + name + '_reqs');
}

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

  ep.reqs.add(1);
  ep.trend.add(res.timings.duration);
  if (res.status !== 200) ep.fails.add(1);
  check(res, { 'status 200': (r) => r.status === 200 });
}

export function health() { run('health'); }
export function healthJson() { run('health_json'); }
export function healthHtml() { run('health_html'); }
export function index() { run('index'); }
export function text() { run('text'); }
export function json() { run('json'); }
export function keys() { run('keys'); }
export function db() { run('db'); }
export function protoGet() { run('proto_get'); }
export function graphqlGet() { run('graphql_get'); }
export function filestoreGet() { run('filestore_get'); }
export function proto() { run('proto'); }
export function graphql() { run('graphql'); }
export function filestore() { run('filestore'); }
export function duckdbWrite() { run('duckdb_write'); }
export function duckdbQuery() { run('duckdb_query'); }
export function tsWrite() { run('ts_write'); }
export function tsQuery() { run('ts_query'); }
export function solrIndex() { run('solr_index'); }
export function solrQuery() { run('solr_query'); }
export function nosqlPut() { run('nosql_put'); }
export function nosqlGet() { run('nosql_get'); }

// --- scenarios: run each endpoint in its own staggered executor ----------

const execFor = {
  health: 'health',
  health_json: 'healthJson',
  health_html: 'healthHtml',
  index: 'index',
  text: 'text',
  json: 'json',
  keys: 'keys',
  db: 'db',
  proto_get: 'protoGet',
  graphql_get: 'graphqlGet',
  filestore_get: 'filestoreGet',
  proto: 'proto',
  graphql: 'graphql',
  filestore: 'filestore',
  duckdb_write: 'duckdbWrite',
  duckdb_query: 'duckdbQuery',
  ts_write: 'tsWrite',
  ts_query: 'tsQuery',
  solr_index: 'solrIndex',
  solr_query: 'solrQuery',
  nosql_put: 'nosqlPut',
  nosql_get: 'nosqlGet',
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
    const rq = (data.metrics[ep.reqs.name] && data.metrics[ep.reqs.name].values) || {};
    const f = (data.metrics[ep.fails.name] && data.metrics[ep.fails.name].values) || {};
    const m = (data.metrics[ep.trend.name] && data.metrics[ep.trend.name].values) || {};
    // k6 v2: Counter exposes `count`; Trend percentiles are keyed `p(95)`/`p(99)`.
    const n = rq.count || 0;
    const fails = f.count || 0;
    totalReqs += n;
    totalFails += fails;
    rows.push({
      endpoint: name,
      reqs: n,
      fails: fails,
      rps: n > 0 ? n / durSec : 0,
      avg_ms: m.avg || 0,
      p95_ms: m['p(95)'] || 0,
      p99_ms: m['p(99)'] || 0,
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
