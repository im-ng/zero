# zero-gcs

Google Cloud Storage file store. Saves, reads, lists, and deletes objects in a
bucket through the framework's file-store API (same routes as the `zero-s3`
example — the backend difference is entirely config).

## Run

You need a GCS bucket plus OAuth2 credentials (service-account client id /
secret) or a pre-issued access token:

```bash
export FILE_STORE_BACKEND=gcs
export GCS_BUCKET=my-bucket
export GCS_PROJECT=my-project-123
export GCS_CLIENT_ID=...apps.googleusercontent.com
export GCS_CLIENT_SECRET=...
# or skip the OAuth2 grant with an issued token:
# export GCS_ACCESS_TOKEN=ya29.....
zig build run

# exercise it
curl -s -F "file=@readme.md" localhost:8080/upload
curl -s localhost:8080/file/readme.md
curl -s -X DELETE localhost:8080/file/readme.md
```

Point `GCS_ENDPOINT` at an emulator (e.g. fake-gcs-server) to run offline.

## Notes

- `FILE_STORE_BACKEND=gcs` (container startup env) registers the *default*
  store backed by the same env; this example instead shows the explicit
  `app.addFileStore("assets", .gcs, .{})` form.
- Keys map 1:1 to GCS object names in the bucket.
- Full key list with defaults: `configs/.env.example` (`GCS_*` section) and
  `docs/CONFIG_REFERENCE.md`.
