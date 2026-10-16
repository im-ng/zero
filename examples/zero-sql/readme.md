# zero-sql

Multi-dialect SQL pack for the zero framework. One backend binds to `ctx.SQL`,
chosen by `DB_DIALECT` in `configs/.env`. The other dialects' migrations stay
scoped out and are skipped.

## Backends

| Dialect    | Config                                   | Migration file                     |
|------------|------------------------------------------|------------------------------------|
| Postgres   | `DB_DIALECT=postgres` + `DB_*`           | `create_users_postgres.zig`        |
| SQLite     | `DB_DIALECT=sqlite` + `SQLITE_PATH`      | `create_users_sqlite.zig`          |
| DuckDB     | `DB_DIALECT=duckdb` + `DUCKDB_PATH`      | `create_users_duckdb.zig`          |
| ClickHouse | `DB_DIALECT=clickhouse` + `CLICKHOUSE_*` | `create_users_clickhouse.zig`      |

## Run

```bash
# SQLite needs no external service — good for a first run.
zig build
./zig-out/bin/sql
# or uncomment the SQLite block in configs/.env, then:
DB_DIALECT=sqlite SQLITE_PATH=./data/app.db zig build run
```

## Routes

```
GET    /users            list users
POST   /users            create (JSON {name,email})
GET    /users/:id        get by id
PUT    /users/:id        update
DELETE /users/:id        delete
```

## Per-dialect migrations

`src/migrations/all.zig` registers all four `users` migrations. Each carries a
`.dialect` tag. On startup the runner applies only the one matching the active
`DB_DIALECT` and skips the rest, so a pack can ship every dialect's DDL without
cross-applying. Set a dialect's block in `configs/.env` to switch backends.
