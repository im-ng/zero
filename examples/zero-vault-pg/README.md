# zero-vault-pg

Demonstrates zero's built-in **HashiCorp Vault secret injection** for a Postgres
connection. The example itself contains **no vault code** — zero reads the
`VAULT_*` env at startup, pulls the `DB_*` connection config from a KV secret,
merges it into the process config, and wires Postgres automatically. The link is
**plaintext / no-TLS** (`DB_SSL_MODE=disable`, which is the default).

It reuses the standard `ctx.SQL` CRUD pack (`/users` table) from `zero-sql`, but
all connection secrets arrive from Vault instead of `configs/.env`.

## Mechanics

- `App.new` calls `vault.load()` before datasources are wired. With `VAULT_ADDR`
  set, it authenticates (`VAULT_TOKEN`, or AppRole `VAULT_ROLE_ID`+`VAULT_SECRET_ID`)
  and merges the KV path's keys into config. So `DB_*` set in Vault become
  available to the Postgres wiring with no example-side code.
- Postgres uses `DB_SSL_MODE`; `disable` (the default in `container.zig`) maps to
  `pgz.Conn.Opts.TLS = .off`. No `DB_TLS_ROOT_CA` is needed.
- `configs/.env` ships only `VAULT_*` (plus comments). It is required by zero's
  config loader even though the `DB_*` values come from Vault.

## Run it

### 1. A Postgres server with TLS off

`postgresql.conf`: `ssl = off`. Create db `demo`, user `appuser`/`apppass`.

### 2. A Vault dev server

```bash
vault server -dev -dev-root-token-id=root
# VAULT_ADDR = http://127.0.0.1:8200 , token = root
```

(The dev server already has the KV v2 secret engine mounted at `secret/`.)

### 3. Put the DB connection as a Vault secret

```bash
vault kv put -mount=secret zero/db \
  DB_DIALECT=postgres \
  DB_HOST=localhost \
  DB_PORT=5432 \
  DB_USER=appuser \
  DB_PASSWORD=apppass \
  DB_NAME=demo \
  DB_SSL_MODE=disable
```

This stores the secret at the KV v2 path `secret/data/zero/db` (API:
`/v1/secret/data/zero/db`). zero accepts either the v1-style `secret/zero/db`
or the v2-style `secret/data/zero/db` for `VAULT_SECRETS_PATH` — it inserts the
`data/` segment automatically if needed (mirroring the `vault kv` CLI).

### 4. Build and run

```bash
cd examples/zero-vault-pg
zig build --release=small

VAULT_ADDR=http://127.0.0.1:8200 \
VAULT_TOKEN=token \
VAULT_SECRETS_PATH=secret/data/zero/db \
./zig-out/bin/vaultpg
```

> The Vault dev container used here is unsealed with the literal root token
> `token`, so `VAULT_TOKEN=token` works. For any other Vault, supply the real
> token (or `VAULT_ROLE_ID` + `VAULT_SECRET_ID`). A wrong token is reported
> clearly by the loader: `vault: GET ... -> HTTP 403: ...invalid token...`.

### 5. Verify the vault-sourced connection

The startup log includes a line like `vault: loaded secrets from ...`, proving
injection. Then:

```bash
curl -s localhost:8080/       # -> tells you config came from Vault, routes listed
curl -s localhost:8080/users  # -> rows from the Postgres DB wired via Vault creds
curl -s -X POST localhost:8080/users -d '{"name":"ada","email":"ada@x.io"}'
```

## Production notes

- Keep `VAULT_TOKEN` out of any committed file; pass it at runtime. Prefer AppRole
  (`VAULT_ROLE_ID` + `VAULT_SECRET_ID`) for non-interactive workloads.
- To enable TLS instead, set `DB_SSL_MODE=require` (or `verify-ca`/`verify-full`)
  in the Vault secret and, for the verify modes, also `DB_TLS_ROOT_CA`.
