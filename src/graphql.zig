const std = @import("std");

const parser = @import("graphql").parser;
const ast = @import("graphql").ast;

pub const error_ = error{
    GraphQLExecutionError,
    GraphQLParseError,
    GraphQLBadRequest,
    GraphQLNoQuery,
    GraphQLNoMutation,
};

pub const ErrorObject = struct {
    message: []const u8,
};

const GraphQLRequest = struct {
    query: ?[]const u8 = null,
    variables: ?std.json.Value = null,
    operation_name: ?[]const u8 = null,
};

fn ExecCtx(comptime Ctx: type) type {
    return struct {
        ctx: Ctx,
        doc: ast.DocumentNode,
        variables: ?std.json.Value,
        alloc: std.mem.Allocator,
        errors: std.array_list.Managed(ErrorObject),
    };
}

pub fn handle(ctx: anytype, comptime Query: type, comptime Mutation: ?type, query_root: *const Query, mutation_root: ?*const anyopaque) !void {
    const body = ctx.request.body() orelse "";
    var req: GraphQLRequest = .{};
    if (body.len > 0) {
        req = std.json.parseFromSliceLeaky(GraphQLRequest, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch blk: {
            break :blk try readFromQueryString(ctx);
        };
    } else {
        req = try readFromQueryString(ctx);
    }

    const query_str = req.query orelse {
        ctx.response.setStatus(.bad_request);
        ctx.response.header("content-type", "application/json");
        try ctx.response.json(.{ .errors = .{.{ .message = "no query provided" }} }, .{});
        return;
    };

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();

    const doc = parser.parse(arena.allocator(), query_str) catch {
        ctx.response.setStatus(.bad_request);
        ctx.response.header("content-type", "application/json");
        try ctx.response.json(.{ .errors = .{.{ .message = "query parse error" }} }, .{});
        return;
    };

    const op = findOperation(doc, req.operation_name) orelse {
        ctx.response.setStatus(.bad_request);
        ctx.response.header("content-type", "application/json");
        try ctx.response.json(.{ .errors = .{.{ .message = "operation not found" }} }, .{});
        return;
    };

    const is_mutation = op.operation == .Mutation;
    if (is_mutation and Mutation == null) {
        ctx.response.setStatus(.bad_request);
        ctx.response.header("content-type", "application/json");
        try ctx.response.json(.{ .errors = .{.{ .message = "no mutation root configured" }} }, .{});
        return;
    }

    var ec: ExecCtx(@TypeOf(ctx)) = .{
        .ctx = ctx,
        .doc = doc,
        .variables = req.variables,
        .alloc = arena.allocator(),
        .errors = std.array_list.Managed(ErrorObject).init(arena.allocator()),
    };

    // Choose the root type at comptime (Mutation may be null); the actual root
    // pointer is selected at runtime. `Mutation orelse Query` avoids the
    // type-level `.?` that would fail to compile under a runtime `if`.
    const data = (if (is_mutation)
        dispatch(Mutation orelse Query, mutation_root orelse {
            ctx.response.setStatus(.bad_request);
            ctx.response.header("content-type", "application/json");
            try ctx.response.json(.{ .errors = .{.{ .message = "mutation root missing" }} }, .{});
            return;
        }, op.selection_set.?, &ec)
    else
        dispatch(Query, query_root, op.selection_set.?, &ec)) catch {
        ctx.response.setStatus(.internal_server_error);
        ctx.response.header("content-type", "application/json");
        const o = std.json.ObjectMap.empty;
        try ctx.response.json(std.json.Value{ .object = o }, .{});
        return;
    };

    var out = std.json.ObjectMap.empty;
    try out.put(ctx.allocator, "data", data);
    if (ec.errors.items.len > 0) {
        var err_arr = std.json.Array.init(ctx.allocator);
        for (ec.errors.items) |e| {
            var o = std.json.ObjectMap.empty;
            try o.put(ctx.allocator, "message", .{ .string = e.message });
            try err_arr.append(std.json.Value{ .object = o });
        }
        try out.put(ctx.allocator, "errors", std.json.Value{ .array = err_arr });
    }

    ctx.response.setStatus(.ok);
    ctx.response.header("content-type", "application/json");
    try ctx.response.json(std.json.Value{ .object = out }, .{});
}

/// Fallback request source: GraphQL-over-HTTP GET uses URL query params
/// (?query=...&variables=...&operationName=...). Values are URL-decoded by httpz.
fn readFromQueryString(ctx: anytype) !GraphQLRequest {
    const qs = ctx.request.query() catch return GraphQLRequest{};

    const q = qs.get("query") orelse return GraphQLRequest{};

    var gql_req: GraphQLRequest = .{
        .query = q,
    };

    if (qs.get("operationName")) |op| {
        gql_req.operation_name = op;
    }

    if (qs.get("variables")) |v| {
        gql_req.variables = std.json.parseFromSliceLeaky(
            std.json.Value,
            ctx.allocator,
            v,
            .{},
        ) catch null;
    }

    return gql_req;
}

fn findOperation(doc: ast.DocumentNode, operation_name: ?[]const u8) ?ast.OperationDefinitionNode {
    var fallback: ?ast.OperationDefinitionNode = null;

    for (doc.definitions) |def| {
        if (def != .ExecutableDefinition) continue;

        const ed = def.ExecutableDefinition;

        if (ed != .OperationDefinition) continue;

        const op = ed.OperationDefinition;

        if (operation_name) |name| {
            if (op.name) |n| {
                if (std.mem.eql(u8, n.value, name)) return op;
            }
        } else {
            if (op.name == null) return op;
            if (fallback == null) fallback = op;
        }
    }

    if (operation_name != null) return null;

    return fallback;
}

fn findFragment(doc: ast.DocumentNode, name: []const u8) ?ast.FragmentDefinitionNode {
    for (doc.definitions) |def| {
        if (def != .ExecutableDefinition) continue;

        const ed = def.ExecutableDefinition;

        if (ed != .FragmentDefinition) continue;

        if (std.mem.eql(u8, ed.FragmentDefinition.name.value, name)) {
            return ed.FragmentDefinition;
        }
    }
    return null;
}

fn dispatch(comptime T: type, root: *const anyopaque, ss: ast.SelectionSetNode, ec: anytype) !std.json.Value {
    const inst: *const T = @ptrCast(@alignCast(root));
    return resolve(T, inst.*, ss, ec);
}

fn resolve(comptime T: type, instance: T, ss: ast.SelectionSetNode, ec: anytype) !std.json.Value {
    var obj = std.json.ObjectMap.empty;

    for (ss.selections) |sel| {
        switch (sel) {
            .Field => |f| {
                const name = f.name.value;
                const key = if (f.alias) |a| a.value else name;
                var matched: bool = false;
                inline for (@typeInfo(T).@"struct".fields) |field| {
                    if (std.mem.eql(u8, field.name, name)) {
                        matched = true;
                        const FT = field.type;
                        const ft_info = @typeInfo(FT);
                        const is_resolver = ft_info == .pointer and @typeInfo(ft_info.pointer.child) == .@"fn";
                        if (is_resolver) {
                            const FnT = ft_info.pointer.child;
                            const Args = @typeInfo(FnT).@"fn".params[1].type orelse
                                @compileError("resolver '" ++ field.name ++ "' must take an args struct");
                            const args_res = coerceArguments(f.arguments, Args, ec);
                            if (args_res) |args| {
                                const ret_res = @call(.auto, @field(instance, field.name), .{ ec.ctx, args });
                                if (ret_res) |ret| {
                                    try obj.put(ec.alloc, key, try resolveValue(ret, f.selection_set, ec));
                                } else |_| {
                                    try ec.errors.append(.{ .message = try std.fmt.allocPrint(ec.alloc, "resolver failed for field '{s}'", .{name}) });
                                    try obj.put(ec.alloc, key, .null);
                                }
                            } else |_| {
                                try ec.errors.append(.{ .message = try std.fmt.allocPrint(ec.alloc, "invalid arguments for field '{s}'", .{name}) });
                                try obj.put(ec.alloc, key, .null);
                            }
                        } else {
                            const val = @field(instance, field.name);
                            try obj.put(ec.alloc, key, try resolveValue(val, f.selection_set, ec));
                        }
                    }
                }
                if (!matched) {
                    try ec.errors.append(.{ .message = try std.fmt.allocPrint(ec.alloc, "cannot query field '{s}'", .{name}) });
                    try obj.put(ec.alloc, key, .null);
                }
            },
            .FragmentSpread => |sp| {
                if (findFragment(ec.doc, sp.name.value)) |frag| {
                    const sub = try resolve(T, instance, frag.selection_set, ec);
                    try mergeObjects(&obj, sub.object, ec.alloc);
                }
            },
            .InlineFragment => |inf| {
                if (inf.type_condition) |tc| {
                    if (!std.mem.eql(u8, tc.name.value, @typeName(T))) continue;
                }
                const sub = try resolve(T, instance, inf.selection_set, ec);
                try mergeObjects(&obj, sub.object, ec.alloc);
            },
        }
    }
    return .{ .object = obj };
}

fn mergeObjects(dest: *std.json.ObjectMap, src: std.json.ObjectMap, alloc: std.mem.Allocator) !void {
    var it = src.iterator();
    while (it.next()) |e| {
        // Propagate OOM instead of silently dropping a merged field.
        try dest.put(alloc, e.key_ptr.*, e.value_ptr.*);
    }
}

fn resolveValue(value: anytype, ss: ?ast.SelectionSetNode, ec: anytype) !std.json.Value {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => {
            if (ss) |s| return resolve(T, value, s, ec);
            return primitiveToJson(value, ec.alloc);
        },
        .pointer => |p| {
            if (p.child == u8) return primitiveToJson(value, ec.alloc);
            if (p.size == .one) {
                if (ss) |s| return resolve(@TypeOf(value.*), value.*, s, ec);
                return primitiveToJson(value.*, ec.alloc);
            } else {
                if (ss) |s| return resolveList(T, value, s, ec);
                return sliceToJson(T, value, ec.alloc);
            }
        },
        .array => |a| {
            if (a.child == u8) return primitiveToJson(value, ec.alloc);
            if (ss) |s| return resolveList(T, value, s, ec);
            return sliceToJson(T, value, ec.alloc);
        },
        .optional => {
            if (value == null) return .null;
            return resolveValue(value.?, ss, ec);
        },
        else => return primitiveToJson(value, ec.alloc),
    }
}

fn resolveList(comptime T: type, list: T, ss: ast.SelectionSetNode, ec: anytype) !std.json.Value {
    var arr = std.json.Array.init(ec.alloc);

    const ti = @typeInfo(T);

    if (ti == .pointer) {
        for (list) |item| try arr.append(try resolveValue(item, ss, ec));
    } else if (ti == .array) {
        for (list) |item| try arr.append(try resolveValue(item, ss, ec));
    }

    return .{ .array = arr };
}

fn sliceToJson(comptime T: type, list: T, alloc: std.mem.Allocator) !std.json.Value {
    var arr = std.json.Array.init(alloc);

    for (list) |item| try arr.append(try primitiveToJson(item, alloc));

    return .{
        .array = arr,
    };
}

fn primitiveToJson(value: anytype, alloc: std.mem.Allocator) !std.json.Value {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int => return .{
            .integer = @intCast(value),
        },
        .float => return .{
            .float = @floatCast(value),
        },
        .bool => return .{
            .bool = value,
        },
        .@"enum" => return .{
            .string = @tagName(value),
        },
        .pointer => |p| {
            if (p.child == u8) return .{
                .string = value,
            };

            if (@typeInfo(p.child) == .@"fn") return .null;

            if (p.size == .one) return primitiveToJson(value.*, alloc);

            var arr = std.json.Array.init(alloc);

            for (value) |item| {
                try arr.append(try primitiveToJson(item, alloc));
            }

            return .{
                .array = arr,
            };
        },
        .optional => if (value == null) return .null else return primitiveToJson(value.?, alloc),
        .array => {
            var arr = std.json.Array.init(alloc);

            for (value) |item| try arr.append(try primitiveToJson(item, alloc));

            return .{
                .array = arr,
            };
        },
        else => return .null,
    }
}

fn dequote(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
        const inner = raw[1 .. raw.len - 1];
        var out = std.array_list.Managed(u8).init(alloc);
        var i: usize = 0;
        while (i < inner.len) : (i += 1) {
            if (inner[i] == '\\' and i + 1 < inner.len) {
                i += 1;
                switch (inner[i]) {
                    '"' => try out.append('"'),
                    '\\' => try out.append('\\'),
                    '/' => try out.append('/'),
                    'n' => try out.append('\n'),
                    't' => try out.append('\t'),
                    'r' => try out.append('\r'),
                    else => {
                        try out.append('\\');
                        try out.append(inner[i]);
                    },
                }
            } else {
                try out.append(inner[i]);
            }
        }
        return out.toOwnedSlice();
    }
    return try alloc.dupe(u8, raw);
}

fn coerceArguments(
    arguments: ?[]const ast.ArgumentNode,
    comptime Args: type,
    ec: anytype,
) !Args {
    if (Args == void) return {};
    var args: Args = std.mem.zeroes(Args);
    if (arguments) |args_nodes| {
        inline for (@typeInfo(Args).@"struct".fields) |af| {
            for (args_nodes) |an| {
                if (std.mem.eql(u8, an.name.value, af.name)) {
                    @field(args, af.name) = try coerceValue(an.value, af.type, ec);
                    break;
                }
            }
        }
    }
    return args;
}

fn coerceValue(node: ast.ValueNode, comptime T: type, ec: anytype) !T {
    if (node == .Variable) {
        const v = lookupVariable(ec.variables, node.Variable.name.value) orelse return error.VariableNotFound;
        return jsonToT(v, T, ec.alloc);
    }
    return switch (node) {
        .Int => parseIntT(T, node.Int.value),
        .Float => parseFloatT(T, node.Float.value),
        .String => stringToT(T, try dequote(ec.alloc, node.String.value)),
        .Boolean => boolToT(T, node.Boolean.value),
        .Enum => enumToT(T, node.Enum.value),
        .Null => {
            if (@typeInfo(T) == .optional) return @as(T, null);
            return error.TypeMismatch;
        },
        .Object => blk: {
            const jv = try valueNodeToJson(node.Object, ec.alloc);
            break :blk try std.json.parseFromValueLeaky(T, ec.alloc, jv, .{});
        },
        .List => try listToT(T, node.List, ec),
        .Variable => unreachable,
    };
}

fn parseIntT(comptime T: type, s: []const u8) !T {
    const ti = @typeInfo(T);
    if (ti == .int) return std.fmt.parseInt(T, s, 10);
    if (ti == .float) return std.fmt.parseFloat(T, s);
    return error.TypeMismatch;
}

fn parseFloatT(comptime T: type, s: []const u8) !T {
    if (@typeInfo(T) == .float) return std.fmt.parseFloat(T, s);
    return error.TypeMismatch;
}

fn stringToT(comptime T: type, s: []const u8) !T {
    if (T == []const u8) return s;

    if (@typeInfo(T) == .optional and @typeInfo(T).optional.child == []const u8) return s;

    if (@typeInfo(T) == .@"enum") return std.meta.stringToEnum(T, s) orelse error.TypeMismatch;

    if (@typeInfo(T) == .optional and @typeInfo(T).optional.child == .@"enum") {
        return std.meta.stringToEnum(@typeInfo(T).optional.child, s) orelse error.TypeMismatch;
    }
    return error.TypeMismatch;
}

fn boolToT(comptime T: type, b: bool) !T {
    if (T == bool) return b;
    return error.TypeMismatch;
}

fn enumToT(comptime T: type, s: []const u8) !T {
    if (@typeInfo(T) == .@"enum") return std.meta.stringToEnum(T, s) orelse error.TypeMismatch;
    return error.TypeMismatch;
}

fn jsonToT(json: std.json.Value, comptime T: type, _: std.mem.Allocator) !T {
    return switch (@typeInfo(T)) {
        .int => @intCast(json.integer),
        .float => @floatCast(json.float),
        .bool => json.bool,
        .@"enum" => std.meta.stringToEnum(T, json.string) orelse error.TypeMismatch,
        .pointer => |p| if (p.child == u8) json.string else error.TypeMismatch,
        .optional => |o| if (json == .null) null else try jsonToT(json, o.child, undefined),
        else => error.TypeMismatch,
    };
}

fn lookupVariable(vars: ?std.json.Value, name: []const u8) ?std.json.Value {
    const v = vars orelse return null;
    if (v != .object) return null;
    var it = v.object.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, name)) return e.value_ptr.*;
    }
    return null;
}

fn valueNodeToJson(obj: ast.ObjectValueNode, alloc: std.mem.Allocator) anyerror!std.json.Value {
    var m = std.json.ObjectMap.empty;
    for (obj.fields) |of| {
        try m.put(alloc, of.name.value, try valueNodeToJsonValue(of.value, alloc));
    }
    return .{ .object = m };
}

fn valueNodeToJsonValue(node: ast.ValueNode, alloc: std.mem.Allocator) anyerror!std.json.Value {
    return switch (node) {
        .Int => .{ .integer = std.fmt.parseInt(i64, node.Int.value, 10) catch 0 },
        .Float => .{ .float = std.fmt.parseFloat(f64, node.Float.value) catch 0 },
        .String => .{ .string = try dequote(alloc, node.String.value) },
        .Boolean => .{ .bool = node.Boolean.value },
        .Null => .null,
        .Enum => .{ .string = node.Enum.value },
        .Variable => .null,
        .List => blk: {
            var arr = std.json.Array.init(alloc);
            for (node.List.values) |v| try arr.append(try valueNodeToJsonValue(v, alloc));
            break :blk .{ .array = arr };
        },
        .Object => try valueNodeToJson(node.Object, alloc),
    };
}

fn listToT(comptime T: type, list: ast.ListValueNode, ec: anytype) !T {
    const ti = @typeInfo(T);
    if (ti == .pointer and ti.pointer.size == .slice and ti.pointer.child != u8) {
        const Elem = ti.pointer.child;
        var items = std.array_list.Managed(Elem).init(ec.alloc);
        for (list.values) |v| try items.append(try coerceValue(v, Elem, ec));
        return items.items;
    }
    if (ti == .array) {
        const Elem = ti.array.child;
        var items: [ti.array.len]Elem = undefined;
        var i: usize = 0;
        for (list.values) |v| {
            if (i >= ti.array.len) break;
            items[i] = try coerceValue(v, Elem, ec);
            i += 1;
        }
        return items;
    }
    return error.TypeMismatch;
}

const TestCtx = struct {};
const TestUser = struct {
    id: []const u8,
    name: []const u8,
};
const TestArgs = struct { id: []const u8 };
fn testUserResolver(_: *TestCtx, args: TestArgs) anyerror!TestUser {
    const name = try std.fmt.allocPrint(std.testing.allocator, "User {s}", .{args.id});
    return .{ .id = args.id, .name = name };
}
const TestQuery = struct {
    hello: []const u8 = "world",
    pi: f64 = 3.14159,
    user: *const fn (*TestCtx, TestArgs) anyerror!TestUser = testUserResolver,
};

// ===================== Tests =====================

test "graphql: resolve query with constant, resolver and arguments" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const query_root: TestQuery = .{};
    const root_inst = query_root;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parser.parse(a, "{ hello pi user(id: \"42\") { id name } }");
    const op = findOperation(doc, null) orelse return error.TestUnexpectedResult;
    var ec: ExecCtx(TestCtx) = .{
        .ctx = TestCtx{},
        .doc = doc,
        .variables = null,
        .alloc = a,
        .errors = std.array_list.Managed(ErrorObject).init(a),
    };

    const data = try resolve(TestQuery, root_inst, op.selection_set.?, &ec);
    try testing.expect(data == .object);

    const hello = data.object.get("hello") orelse return error.TestUnexpectedResult;
    try testing.expect(hello == .string);
    try testing.expectEqualSlices(u8, "world", hello.string);

    const pi = data.object.get("pi") orelse return error.TestUnexpectedResult;
    try testing.expect(pi == .float);
    try testing.expectApproxEqAbs(@as(f64, 3.14159), pi.float, 0);

    const user = data.object.get("user") orelse return error.TestUnexpectedResult;
    try testing.expect(user == .object);
    try testing.expectEqualSlices(u8, "42", user.object.get("id").?.string);
    try testing.expectEqualSlices(u8, "User 42", user.object.get("name").?.string);

    try testing.expect(ec.errors.items.len == 0);
}
