### zero-search example

Demonstrates Solr (search / persistence) over the `zero` framework's `ctx.Search`
interface. Solr is used both as the persistence layer (index/get/delete) and the
search layer (query).

Routes (collection = `docs`):

| Method | Path | Description |
|--------|------|-------------|
| POST   | `/docs`        | index a JSON document (body must include `id`) |
| GET    | `/docs/:id`    | fetch a document by id |
| DELETE | `/docs/:id`    | delete a document by id |
| GET    | `/search?q=<q>`| search the collection |
| POST   | `/search`      | search the collection (request body = query) |

Set `SOLR_URL` and `SOLR_DEFAULT_COLLECTION` in `configs/.env` to enable the
backend; with them unset the routes return `501 not configured`.

```bash
zig build search
# or
zig build run
```
