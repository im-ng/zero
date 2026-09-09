const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const utils = zero.utils;

// ---- Resolver input + nested object types ----

const UserArgs = struct {
    id: []const u8,
};

const User = struct {
    id: []const u8,
    name: []const u8,
};

// The root Query resolver. Constant fields are returned as-is; function fields
// are invoked as resolvers with the signature `fn(*Context, Args) !Return`.
const Query = struct {
    hello: []const u8 = "world",
    pi: f64 = 3.14159,
    now: *const fn (*Context, void) anyerror!i64,
    user: *const fn (*Context, UserArgs) anyerror!User,
    users: *const fn (*Context, void) anyerror![2]User,
};

fn nowResolver(_: *Context, _: void) anyerror!i64 {
    return 1700000000;
}

fn userResolver(ctx: *Context, args: UserArgs) anyerror!User {
    const name = try std.fmt.allocPrint(ctx.allocator, "User {s}", .{args.id});
    return .{ .id = args.id, .name = name };
}

fn usersResolver(_: *Context, _: void) anyerror![2]User {
    return .{
        .{ .id = "1", .name = "Alice" },
        .{ .id = "2", .name = "Bob" },
    };
}

var query_root = Query{
    .hello = "world",
    .pi = 3.14159,
    .now = nowResolver,
    .user = userResolver,
    .users = usersResolver,
};

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

pub fn main(init: std.process.Init) !void {
    utils.setIo(init.io);

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    const app = try App.new(allocator, init.environ_map);

    try app.get("/", index);
    // GraphQL-over-HTTP endpoint. POST {"query": "...", "variables": {...}}.
    try app.graphql("/graphql", Query, null, &query_root, null);

    try app.run();
}

fn index(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.body =
        \\POST a GraphQL query to /graphql, e.g.:
        \\  {"query":"{ hello pi now user(id:\"42\"){ id name } users{ id name } }"}
    ;
}
