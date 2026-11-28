# zero-supabase

One app, both Supabase surfaces:

- **SQL**: the database is plain Postgres with forced SSL (`DB_DIALECT=supabase`
  reuses the Postgres backend), so routes work exactly like any SQL app.
- **Storage**: `FILE_STORE_BACKEND=supabase` drives the S3-compatible bucket
  file store via `SUPABASE_STORAGE_*` keys.

## Run

Set connection env (values from a Supabase project, Settings → Database / API):

```bash
export DB_DIALECT=supabase
export SUPABASE_DB_HOST=aws-0-us-east-1.pooler.supabase.com
export SUPABASE_DB_PORT=5432
export SUPABASE_DB_USER=postgres.<project-ref>
export SUPABASE_DB_PASSWORD=...
export SUPABASE_DB_NAME=postgres
export SUPABASE_DB_SSL_MODE=require

export FILE_STORE_BACKEND=supabase
export SUPABASE_STORAGE_PROJECT=<ref>.supabase.co
export SUPABASE_STORAGE_BUCKET=uploads
export SUPABASE_STORAGE_ACCESS_KEY=...
export SUPABASE_STORAGE_SECRET_KEY=...

zig build run

# exercise it
curl -s -X POST localhost:8080/messages -d '{"body":"hello supabase"}'
curl -s localhost:8080/messages
curl -s -F "file=@readme.md" localhost:8080/upload
```

## Notes

- The startup hook creates a `messages` table (id identity PK, body, created_at)
  in the project's `public` schema if it does not exist.
- This example registers storage explicitly with
  `app.addFileStore("uploads", .supabase, .{})` that reads `SUPABASE_STORAGE_*`
  directly, so `FILE_STORE_BACKEND` is not needed here. Set
  `FILE_STORE_BACKEND=supabase` instead when you want the auto-registered
  default store with no explicit call.
- Swap `DB_DIALECT=postgres` + `DB_HOST/...` and the same routes point at any
  Postgres useful for local testing without a Supabase project.
- Full key list with defaults: `configs/.env.example` (`SUPABASE_*` sections)
  and `docs/CONFIG_REFERENCE.md`.
