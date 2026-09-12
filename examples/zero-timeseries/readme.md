### zero-timeseries example

Demonstrates InfluxDB (time-series) write + query over the `zero` framework's
`ctx.Timeseries` interface.

Routes:

| Method | Path | Description |
|--------|------|-------------|
| POST | `/points` | write a point (JSON `{"measurement","tags","fields","ts"}`) |
| POST | `/write`  | write a point (InfluxDB line protocol body) |
| GET  | `/query?q=<flux>` | run a Flux query |
| POST | `/query`  | run a Flux query (request body) |

Set `INFLUXDB_URL`, `INFLUXDB_ORG`, `INFLUXDB_BUCKET` (and optionally
`INFLUXDB_TOKEN`) in `configs/.env` to enable the backend; with them unset the
routes return `501 not configured`.

```bash
zig build timeseries
# or
zig build run
```
