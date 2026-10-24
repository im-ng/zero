const std = @import("std");
const root = @import("zero.zig");
const httpz = root.httpz;
const Context = @import("context.zig").Context;
const utils = root.utils;

// Tests for Context split out of context.zig (674 lines) so the source file
// stays free of test code. All exercised Context methods here are `pub`.

test "context: protobuf bindProto and protobuf round-trip" {
    const protobuf = @import("protobuf");
    const t = httpz.testing;

    // A minimal protobuf message described entirely via the generic
    // protobuf.encode/decode primitives (no generated code needed here).
    const TestMsg = struct {
        value: []const u8 = &.{},

        pub const _desc_table = .{
            .value = protobuf.fd(1, .{ .scalar = .string }),
        };

        pub fn encode(self: @This(), writer: *std.Io.Writer, allocator: std.mem.Allocator) !void {
            return protobuf.encode(writer, allocator, self);
        }
        pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) !@This() {
            return protobuf.decode(@This(), reader, allocator);
        }
    };

    var testing = t.init(.{});
    defer testing.deinit();

    // Encode a TestMsg into protobuf bytes.
    const msg = TestMsg{ .value = "hello protobuf" };
    var w: std.Io.Writer.Allocating = .init(testing.arena);
    try msg.encode(&w.writer, testing.arena);
    const encoded = w.written();

    // Put the encoded bytes on the request body.
    testing.body(encoded);

    // Build a Context over the mocked request/response.
    var ctx: Context = undefined;
    ctx.allocator = testing.arena;
    ctx.request = testing.req;
    ctx.response = testing.res;

    // bindProto decodes the body.
    const decoded = (try ctx.bindProto(TestMsg)).?;
    try std.testing.expectEqualStrings("hello protobuf", decoded.value);

    // protobuf serializes back into the response.
    try ctx.protobuf(decoded);
    try testing.expectStatusCode(.ok);
    try testing.expectHeader("content-type", "application/x-protobuf");
    try testing.expectBody(encoded);
}

test "context: xml writes application/xml body" {
    const t = httpz.testing;
    var testing = t.init(.{});
    defer testing.deinit();

    var ctx: Context = undefined;
    ctx.allocator = testing.arena;
    ctx.request = testing.req;
    ctx.response = testing.res;

    try ctx.xml("<note><to>Zero</to></note>");
    try testing.expectStatusCode(.ok);
    try testing.expectHeader("content-type", "application/xml");
    try testing.expectBody("<note><to>Zero</to></note>");
}

test "context: GetFile parses a multipart upload" {
    const t = httpz.testing;
    var testing = t.init(.{ .request = .{ .max_multiform_count = 5 } });
    defer testing.deinit();

    const body =
        "--BOUND\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n" ++
        "\r\n" ++
        "hello file\r\n" ++
        "--BOUND--\r\n";
    testing.header("content-type", "multipart/form-data; boundary=BOUND");
    testing.body(body);

    var ctx: Context = undefined;
    ctx.allocator = testing.arena;
    ctx.request = testing.req;
    ctx.response = testing.res;

    const f = (try ctx.GetFile("file")).?;
    try std.testing.expectEqualStrings("a.txt", f.filename);
    try std.testing.expectEqualStrings("hello file", f.data);
    try std.testing.expectEqual(@as(usize, 10), f.size);
}

test "context: File serves a local file as a download" {
    const t = httpz.testing;
    var testing = t.init(.{});
    defer testing.deinit();

    const dir = ".ztmp-filestore-ctx";
    defer std.Io.Dir.cwd().deleteTree(utils.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(utils.io, dir);
    const path = try std.fmt.allocPrint(testing.arena, "{s}/serve.txt", .{dir});
    const fh = try std.Io.Dir.cwd().createFile(utils.io, path, .{});
    defer fh.close(utils.io);
    try fh.writeStreamingAll(utils.io, "download me");

    var ctx: Context = undefined;
    ctx.allocator = testing.arena;
    ctx.io = std.testing.io;
    ctx.request = testing.req;
    ctx.response = testing.res;

    try ctx.File(path);
    try testing.expectStatusCode(.ok);
    try testing.expectHeader("content-disposition", "attachment; filename=\"serve.txt\"");
    try testing.expectHeader("content-type", "text/plain");
    try testing.expectBody("download me");
}
