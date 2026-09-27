# zero-pubsub-publisher

A single Zero example that publishes to **Kafka, MQTT, or NATS** through the
unified `ctx.pubsub` interface. The backend is chosen entirely by environment
configuration — no code change needed to switch brokers.

## Configure the backend

Set `PUBSUB_BACKEND` in `configs/.env`:

- `MQTT` → set `MQTT_HOST` / `MQTT_PORT`
- `KAFKA` → set `PUBSUB_BROKER` (bootstrap.servers)
- `NATS` → set `PUBSUB_BROKER` (`nats://host:port`)

The topic defaults to `zero` (`PUBSUB_TOPIC`).

## Publish

```bash
zig build run
# or run the binary directly
./zig-out/bin/pubsub-publisher
```

Then send messages:

```bash
# via query string
curl "http://127.0.0.1:8080/publish?message=hello&topic=zero"

# via POST body
curl -X POST "http://127.0.0.1:8080/publish?topic=zero" -d "hello from post"
```

A heartbeat is published to `zero` automatically every 5 seconds.

Run the matching `zero-pubsub-subscriber` (pointed at the same backend/topic)
to see the messages arrive.
