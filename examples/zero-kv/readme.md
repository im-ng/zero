# zero-kv

Multi-backend key/value pack for the zero framework. Each backend wires only
when its env is present, so the example runs with the always-available memory
store and lights up SQLite / Redis / NATS KV as they become available.

## Backends

| Name    | Backend | Config to enable                        |
|---------|---------|-----------------------------------------|
| `mem`   | memory  | always on (no env)                      |
| `sqlkv` | sqlite  | `DB_DIALECT=sqlite` + `SQLITE_PATH`     |
| `redis` | redis   | `REDIS_HOST` + `REDIS_PORT`             |
| `natskv`| nats_kv | `PUBSUB_BACKEND=nats` + `PUBSUB_BROKER` |

## Routes

```
GET    /kv/:store/:key     get a value (404 if absent)
PUT    /kv/:store/:key     set a value (request body = value)
DELETE /kv/:store/:key     delete a value
```

## Run

```bash
# memory store only — no external services required
zig build kv

# then, in another shell:
curl -X PUT localhost:8080/kv/mem/hello -d 'world'
curl localhost:8080/kv/mem/hello        # -> world
curl -X DELETE localhost:8080/kv/mem/hello
```

Uncomment a backend block in `configs/.env` to add `sqlkv` / `redis` / `natskv`,
then hit the same routes with that store name.
