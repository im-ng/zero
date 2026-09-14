# zero-graphql — PostgreSQL-backed GraphQL CRUD

A minimal [zero](https://github.com/anomalyco/zero) example that serves a GraphQL-over-HTTP API backed by PostgreSQL. 

The schema exposes a `User` entity with full create / read / update / delete operations.

## Schema

```graphql
type User {
  id: Int!          # BIGSERIAL primary key (mapped to i64)
  name: String!
  email: String      # nullable
}

type Query {
  users: [User!]!
  user(id: Int!): User
}

type Mutation {
  createUser(name: String!, email: String): User!
  updateUser(id: Int!, name: String, email: String): User
  deleteUser(id: Int!): Boolean!
}
```

- `email` is optional — omit it to store `null`.
- `updateUser` is a **partial** update: only the fields you pass are changed.
- `deleteUser` returns `true` if a row was deleted, `false` if no row with that `id` exists.

## Running

```bash
# from this directory
zig build            # produces ./zig-out/bin/graphql
./zig-out/bin/graphql
```

The server listens on `:8080` and connects to PostgreSQL using the credentials in `configs/.env` (`DB_DIALECT=postgres`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`). 

On startup it runs the `users` table migration automatically.

## Endpoint

`POST /graphql` with a JSON body `{"query": "..."}` (and optionally `"variables": {...}`). 

`GET /graphql?query=...` is also supported.

```bash
curl -s localhost:8080/graphql \
  -H 'content-type: application/json' \
  -d '{"query":"{ users { id name email } }"}'
```

## Queries & mutations to try manually

### List all users

```bash
curl -s localhost:8080/graphql -H 'content-type: application/json' -d '{
  "query": "{ users { id name email } }"
}'
```

### Fetch a single user by id

```bash
curl -s localhost:8080/graphql -H 'content-type: application/json' -d '{
  "query": "query { user(id: 1) { id name email } }"
}'
```

### Create a user (with email)

```bash
curl -s localhost:8080/graphql -H 'content-type: application/json' -d '{
  "query": "mutation { createUser(name: \"Bob\", email: \"bob@x.com\") { id name email } }"
}'
```

### Create a user without email (nullable field → null)

```bash
curl -s localhost:8080/graphql -H 'content-type: application/json' -d '{
  "query": "mutation { createUser(name: \"Alice\") { id name email } }"
}'
```

### Update a user's name only (partial update)

```bash
curl -s localhost:8080/graphql -H 'content-type: application/json' -d '{
  "query": "mutation { updateUser(id: 1, name: \"Bobby\") { id name email } }"
}'
```

### Update a user's email only (partial update)

```bash
curl -s localhost:8080/graphql -H 'content-type: application/json' -d '{
  "query": "mutation { updateUser(id: 1, email: \"bobby@x.com\") { id name email } }"
}'
```

### Update both name and email

```bash
curl -s localhost:8080/graphql -H 'content-type: application/json' -d '{
  "query": "mutation { updateUser(id: 1, name: \"Bobby\", email: \"bobby@x.com\") { id name email } }"
}'
```

### Delete a user (returns true when deleted)

```bash
curl -s localhost:8080/graphql -H 'content-type: application/json' -d '{
  "query": "mutation { deleteUser(id: 2) }"
}'
```

### Delete a non-existent user (returns false)

```bash
curl -s localhost:8080/graphql -H 'content-type: application/json' -d '{
  "query": "mutation { deleteUser(id: 9999) }"
}'
```

## Using variables

Instead of inlining arguments, send them separately:

```bash
curl -s localhost:8080/graphql -H 'content-type: application/json' -d '{
  "query": "mutation ($name: String!, $email: String) { createUser(name: $name, email: $email) { id name email } }",
  "variables": { "name": "Carol", "email": "carol@x.com" }
}'
```

## Full smoke-test sequence

```bash
# create two users
curl -s localhost:8080/graphql -H 'content-type: application/json' -d '{"query":"mutation { createUser(name: \"Bob\", email: \"bob@x.com\") { id name email } }"}'

curl -s localhost:8080/graphql -H 'content-type: application/json' -d '{"query":"mutation { createUser(name: \"Alice\") { id name email } }"}'

# list them
curl -s localhost:8080/graphql -H 'content-type: application/json' -d '{"query":"{ users { id name email } }"}'

# read one
curl -s localhost:8080/graphql -H 'content-type: application/json' -d '{"query":"query { user(id: 1) { id name email } }"}'

# partial update
curl -s localhost:8080/graphql -H 'content-type: application/json' -d '{"query":"mutation { updateUser(id: 1, name: \"Bobby\") { id name email } }"}'

# delete, then confirm
curl -s localhost:8080/graphql -H 'content-type: application/json' -d '{"query":"mutation { deleteUser(id: 2) }"}'

curl -s localhost:8080/graphql -H 'content-type: application/json' -d '{"query":"{ users { id name email } }"}'
```
