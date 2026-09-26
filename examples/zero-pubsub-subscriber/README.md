# zero-pubsub-subscriber

A single Zero example that subscribes to **Kafka, MQTT, or NATS** through the
unified `ctx.pubsub` interface. The backend is chosen entirely by environment
configuration — no code change needed to switch brokers.

## Configure the backend

Set `PUBSUB_BACKEND` in `configs/.env`:

- `MQTT` → set `MQTT_HOST` / `MQTT_PORT`
- `KAFKA` → set `PUBSUB_BROKER` (bootstrap.servers) **and** `CONSUMER_ID`
  (consumer group)
- `NATS` → set `PUBSUB_BROKER` (`nats://host:port`); JetStream fields optional

The topic defaults to `zero` (`PUBSUB_TOPIC`).

## Run

```bash
zig build run
# or run the binary directly
./zig-out/bin/pubsub-subscriber
```

Incoming messages are logged as they arrive. Use the matching
`zero-pubsub-publisher` (same backend/topic) to send messages.
