# zero-duckgres

A Zero framework example that uses **DuckGres** — the wired (network) DuckDB
client. It speaks the PostgreSQL wire protocol to a DuckDB PG-wire front-end
(e.g. [duckgres](https://github.com/...) or PostDuck), so no `duckdb` C library
is linked.

## What it shows

- `DB_DIALECT=duckgres` selects the wired DuckDB backend at startup (reusing the
  shared `DB_*` connection settings).
- `app.addRestHandlers(User, .{ .resource = "users" })` exposes full REST CRUD
  through the unified `ctx.SQL` relational surface — identical to the Postgres /
  in-process DuckDB examples.
- `app.onStartup(initDb)` creates the `users` table via `ctx.SQL.exec`.

## Running

DuckGres needs a running DuckDB PG-wire front-end. Point `DB_*` in
`configs/.env` at it (default `127.0.0.1:5432`), then:

```bash
zig build
./zig-out/bin/duckgres
```

Routes (all JSON):

```
GET    /users            list
GET    /users/:id        get by id
POST   /users            create  body: {"id":N,"name":..,"email":..}
PUT    /users/:id        update
DELETE /users/:id        delete
```
