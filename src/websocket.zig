const std = @import("std");
const root = @import("zero.zig");
const httpz = root.httpz;
const constants = root.constants;
const Context = root.Context;
const utils = root.utils;
const Conn = root.httpz.websocket.Conn;
const Container = root.container;
const Responder = root.responder;

const WebSocket = @This();
const Self = @This();

conn: *Conn,
context: *Context,
container: *Container = undefined,
message: []const u8 = undefined,
_req: *httpz.Request = undefined,
_res: *httpz.Response = undefined,

pub fn init(
    conn: *Conn,
    context: *Context,
) !WebSocket {
    var ws = WebSocket{
        .conn = conn,
        .context = context,
    };
    ws.context.wsClient = conn;
    context.info("websocket connection created");
    return ws;
}

pub fn clientMessage(self: *WebSocket, data: []const u8) !void {
    self.context.wsMessage = data;
    try self.context.action(self.context);
}

pub fn afterInit(self: *WebSocket) !void {
    try self.conn.write("connected!");
    try self.context.action(self.context);
}
