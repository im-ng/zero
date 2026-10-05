### zero-nosql example

Demonstrates NoSQL CRUD over the `zero` framework's `ctx.NoSQL` interface. One
backend is active at a time — **Cassandra** (wide-column, CQL) or **Couchbase**
(document, N1QL/HTTP). The other's migration is scoped out and skipped.

Routes (collection = `users`):

| Method | Path | Description |
|--------|------|-------------|
| GET    | `/users`        | list users (`SELECT ... LIMIT 50`) |
| GET    | `/users/:key`   | get a user by key |
| PUT    | `/users/:key`   | upsert a user (request body = value) |
| POST   | `/users/:key`   | upsert a user |
| DELETE | `/users/:key`   | delete a user by key |
| POST   | `/query`        | run a raw CQL / N1QL statement (request body) |

### Per-backend migrations

`src/migrations/all.zig` registers both:

- `create_schema_cassandra.zig` — `CREATE TABLE IF NOT EXISTS users (...)`
- `create_schema_couchbase.zig` — `CREATE PRIMARY INDEX IF NOT EXISTS ON <bucket>`

Each carries a `.backend` tag. On startup the runner applies only the active
backend's migration.

### Configure

Set one backend's contact points in `configs/.env` (`CASSANDRA_*` or
`COUCHBASE_*`); with neither set the routes return `501 not configured`.

```bash
zig build nosql
# or
zig build run
```
