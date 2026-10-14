const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const WebSocketClient = zero.WebSocketClient;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

// Bybit V5 public spot websocket. Subscribing to `tickers.ETHUSDT` streams the
// ETH/USDT last price, best bid/ask, and 24h stats in real time, with no
// credentials required.
const BYBIT_WS = "wss://stream.bybit.com/v5/public/spot";
const ETH_SYMBOL = "ETHUSDT";

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    _ = gpa.detectLeaks();

    const app: *App = try App.new(allocator, init.io, init.environ_map);

    // The client owns its own background thread, reconnects with backoff, and
    // dispatches each frame to `onMessage` with a datasource-wired Context.
    const client = try app.addWebsocketClient("bybit-eth", BYBIT_WS, .{
        .headers = null,
        .on_message = onMessage,
        .on_open = onOpen,
        .userdata = null,
    });
    // Hand the client to its own callbacks so `onMessage` can reply to the
    // Bybit application-level heartbeat without a global.
    client.userdata = @as(*anyopaque, @ptrCast(client));

    try app.run();
}

// Fired once after the handshake: subscribe to the ETH ticker.
fn onOpen(client: *WebSocketClient, _: ?*anyopaque) !void {
    var buf: [128]u8 = undefined;
    const sub = try std.fmt.bufPrint(
        &buf,
        "{{\"op\":\"subscribe\",\"args\":[\"tickers.{s}\"]}}",
        .{ETH_SYMBOL},
    );
    try client.sendText(sub);
}

// Bybit ticker `data` payload. The `tickers` stream carries the last price and
// 24h stats but no bid/ask (that lives in the `orderbook` stream), and every
// field arrives as a string. Fields are optional so a frame missing some of
// them (or a subscription ack with no `data` at all) still parses.
const Ticker = struct {
    symbol: ?[]const u8 = null,
    lastPrice: ?[]const u8 = null,
};

const Envelope = struct {
    topic: ?[]const u8 = null,
    data: ?Ticker = null,
};

// Called for every inbound frame. Reply to Bybit's `{"op":"ping"}` heartbeat
// (it drops the connection otherwise), then parse and print the ETH ticker.
fn onMessage(ctx: *Context, frame: []const u8, ud: ?*anyopaque) !void {
    // Bybit's application-level heartbeat: answer with `pong` or it disconnects.
    if (std.mem.indexOf(u8, frame, "\"op\":\"ping\"") != null) {
        if (ud) |p| {
            const c = @as(*WebSocketClient, @ptrCast(@alignCast(p)));
            c.sendText("{\"op\":\"pong\"}") catch {};
        }
        return;
    }

    const parsed = std.json.parseFromSlice(
        Envelope,
        ctx.allocator,
        frame,
        .{ .ignore_unknown_fields = true },
    ) catch {
        // Genuinely unexpected payloads: print so a bad shape is visible
        // instead of silently dropped.
        std.log.err("unparsed ws frame: {s}", .{frame});
        return;
    };
    defer parsed.deinit();

    // Subscription acks and non-ticker frames have no `data`: skip silently.
    const data = parsed.value.data orelse return;
    const last = data.lastPrice orelse return;

    const msg = try std.fmt.allocPrint(
        ctx.allocator,
        "ETH {s} last={s}",
        .{ data.symbol orelse ETH_SYMBOL, last },
    );
    defer ctx.allocator.free(msg);

    ctx.info(msg);
}
