# zero-proto — PostgreSQL-backed protobuf CRUD

A minimal [zero](https://github.com/anomalyco/zero) example that serves a protobuf-over-HTTP CRUD API backed by PostgreSQL. Requests and responses are encoded as protobuf (`Content-Type: application/x-protobuf`) — see `proto/crud.proto`.

A `User` entity supports full create / read / update / delete operations on the isolated `proto_users` table.

## Endpoints

| Method | Path           | Request (protobuf)      | Response (protobuf)   |
|--------|----------------|-------------------------|-----------------------|
| POST   | `/users`       | `CreateUserRequest`     | `UserResponse`        |
| GET    | `/users`       | (empty body)            | `UserList`            |
| GET    | `/users/:id`   | (empty body)            | `UserResponse`        |
| PUT    | `/users/:id`   | `UpdateUserRequest`     | `UserResponse`        |
| DELETE | `/users/:id`   | (empty body)            | `DeleteResponse`      |

- `email` is `optional` — omit it to store `null`.
- `PUT` is a **partial** update: only the fields you send are changed.
- A missing `:id` returns `404` for get/update/delete.

## Running

```bash
# from this directory
zig build            # produces ./zig-out/bin/proto
./zig-out/bin/proto
```

The server listens on `:8080` and connects to PostgreSQL from `configs/.env`. On startup it runs the `proto_users` table migration automatically.

Regenerate the generated structs after editing the schema:

```bash
zig build gen-proto  # writes src/proto/crud.pb.zig from proto/crud.proto
```

## Usage example

Protobuf bodies are binary, so encode/decode them with `protoc`. Given `proto/crud.proto`:

```bash
# create a user (with email)
echo 'name: "alice" email: "alice@example.com"' \
  | protoc --encode=crud.CreateUserRequest proto/crud.proto \
  > /tmp/create.bin

curl -s localhost:8080/users \
  --data-binary @/tmp/create.bin \
  -H 'content-type: application/x-protobuf' \
  -o /tmp/resp.bin

protoc --decode=crud.UserResponse proto/crud.proto < /tmp/resp.bin
# user { id: 1 name: "alice" email: "alice@example.com" }

# create without email
echo 'name: "bob"' \
  | protoc --encode=crud.CreateUserRequest proto/crud.proto > /tmp/create.bin
curl -s localhost:8080/users --data-binary @/tmp/create.bin \
  -H 'content-type: application/x-protobuf' -o /tmp/resp.bin
protoc --decode=crud.UserResponse proto/crud.proto < /tmp/resp.bin
# user { id: 2 name: "bob" }

# list
curl -s localhost:8080/users -H 'content-type: application/x-protobuf' -o /tmp/list.bin
protoc --decode=crud.UserList proto/crud.proto < /tmp/list.bin

# update (rename only)
echo 'name: "alice2"' \
  | protoc --encode=crud.UpdateUserRequest proto/crud.proto > /tmp/upd.bin
curl -s -X PUT localhost:8080/users/1 --data-binary @/tmp/upd.bin \
  -H 'content-type: application/x-protobuf' -o /tmp/resp.bin
protoc --decode=crud.UserResponse proto/crud.proto < /tmp/resp.bin

# delete
curl -s -X DELETE localhost:8080/users/2 -H 'content-type: application/x-protobuf' \
  -o /tmp/del.bin
protoc --decode=crud.DeleteResponse proto/crud.proto < /tmp/del.bin
# success: true
```

`protoc` is required for the commands above (the build's `gen-proto` step downloads it on first run).
