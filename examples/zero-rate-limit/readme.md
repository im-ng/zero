# zero-rate-limit

Rate limiting demo. The limiter is middleware built into the HTTP server. The code
registers routes, config turns the limiter on and tunes it.

`RATE_LIMIT_ENABLE` is on by default.

This app exists so you can drive it and watch the behavior.

## Run

```bash
zig build run
# probe the default limit: 100 requests per 60s window (memory store, IP-keyed);
# tighten with RATE_LIMIT_MAX=3 / RATE_LIMIT_WINDOW=10 to watch 429 quickly
for i in $(seq 1 6); do curl -si localhost:8080/heavy | head -3; done
```

## Configs

Copy `configs/.env.example` to `configs/.env` and uncomment what you need:

| Key                          | Default  | Meaning                                                                                           |
| ---------------------------- | -------- | ------------------------------------------------------------------------------------------------- |
| `RATE_LIMIT_ENABLE`          | on       | set `false` to disable the limiter                                                                |
| `RATE_LIMIT_MAX`             | `100`    | requests allowed per window                                                                       |
| `RATE_LIMIT_WINDOW`          | `60` (s) | window size in seconds                                                                            |
| `RATE_LIMIT_KEY`             | `ip`     | `ip` or `header:<Header-Name>` (e.g. `header:X-Client-Id`)                                        |
| `RATE_LIMIT_STORE`           | `memory` | `redis` enforces one counter across app instances (needs `REDIS_HOST`/`REDIS_PORT`)               |
| `RATE_LIMIT_TRUSTED_PROXIES` | —        | comma list of proxy CIDRs; when set, header keys are only honored for requests from trusted peers |

When the limit trips, the limiter responds `429 Too Many Requests` with a
`Retry-After` header carrying the seconds left in the window.
