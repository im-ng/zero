### zero-nosql example

Demonstrates Cassandra (wide-column / NoSQL) CRUD over the `zero` framework's
`ctx.NoSQL` interface.

Routes (collection = `users`):

| Method | Path | Description |
|--------|------|-------------|
| GET    | `/users`        | list users (`SELECT ... LIMIT 50`) |
| GET    | `/users/:key`   | get a user by key |
| PUT    | `/users/:key`   | upsert a user (request body = value) |
| POST   | `/users/:key`   | upsert a user |
| DELETE | `/users/:key`   | delete a user by key |
| POST   | `/query`        | run a raw CQL statement (request body) |

Set `CASSANDRA_CONTACT_POINTS` and `CASSANDRA_KEYSPACE` in `configs/.env` to
enable the backend; with them unset the routes return `501 not configured`.

```bash
zig build nosql
# or
zig build run
```
