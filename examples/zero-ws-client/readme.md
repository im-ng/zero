### zero-ws-client example

Open an outbound websocket connection from a `zero` app. The connection runs on
its own background thread and reconnects with backoff until the app shuts down.

What you get:

- `app.connectWebSocket(url, headers, on_message, on_open, userdata)` — starts the client.
- `onOpen` — fires once after the handshake. Send a subscribe or login frame here.
- `onMessage` — fires for every inbound frame. Parse it or forward it.

Run it:

```bash
cd examples/zero-ws-client
zig build run
```

The demo connects to a public echo server, sends a JSON subscribe frame on open,
and prints each frame it receives. Swap the URL for a real broker (Zerodha,
Dhan, and so on) and the callbacks will keep working unchanged.

Trade-off: each client drives its own thread and socket. If many clients write
to a single shared backend connection (SQLite, DuckDB), serialize those writes
or route to a thread-safe backend.
