const std = @import("std");
const zero = @import("zero");

const models = @import("models.zig");
const helper = @import("helper.zig");

const Todo = models.Todo;
const Builder = zero.zul.StringBuilder;

const Handler = @This();
const Self = @This();

const Context = zero.Context;
const utils = zero.utils;

pub fn getAll(ctx: *Context) !void {
    var rows = try ctx.SQL.queryRows(models.getAllTodos, .{});
    defer rows.deinit();

    // var res = rows.mapper(models.Todo, .{ .dupe = true });

    var responses = std.array_list.Managed(
        models.HandlerTodo,
    ).init(
        ctx.allocator,
    );

    while (try rows.next()) |row| {
        const todo = try row.to(models.Todo, .{});

        const response = models.HandlerTodo{
            .id = try std.fmt.allocPrint(ctx.allocator, "{d}", .{todo.id.?}),
            .description = todo.description,
            .task = todo.task,
            .isDone = todo.isDone,
            .created_at = try utils.DTtimestampz(
                ctx.allocator,
                todo.created_at,
            ),
        };

        try responses.append(response);
    }

    const list = try helper.itemList(ctx, responses);

    ctx.response.content_type = .HTML;
    ctx.response.setStatus(.ok);
    ctx.response.body = list;
}

pub fn getTodo(ctx: *Context) !void {
    const id = ctx.param("id");

    if (id.len == 0) {
        ctx.response.setStatus(.bad_request);
        try ctx.response.json(
            .{ .message = "id query param can't be empty" },
            .{},
        );
        return;
    }

    var row = ctx.SQL.queryRow(
        models.getTodoByID,
        .{id},
    ) catch |err| {
        ctx.response.setStatus(.internal_server_error);
        ctx.err("something went wrong!");
        ctx.any(err);
        return;
    };

    if (row == null) {
        const msg = try utils.toString(
            ctx.allocator,
            "No valid data found for id: {s}",
            id,
        );
        ctx.info(msg);

        try ctx.json(.{ .message = "no valid data found" });
        return;
    }

    defer row.?.deinit() catch {};

    const res = try row.?.to(models.Todo, .{});

    var response = models.HandlerTodo{
        .id = try std.fmt.allocPrint(ctx.allocator, "{d}", .{res.id.?}),
        .description = res.description,
        .task = res.task,
        .isDone = res.isDone,
    };
    response.created_at = try utils.DTtimestampz(ctx.allocator, res.created_at);

    const list = try helper.getEditItem(ctx, &response);

    ctx.response.content_type = .HTML;
    ctx.response.setStatus(.ok);
    ctx.response.body = list;
}

pub fn persistTodo(ctx: *Context) !void {
    var t: models.Todo = undefined;

    if (try ctx.bind(models.Todo)) |todo| {
        t = todo;
    }

    // persist todo entry in database
    const id = try ctx.SQL.exec(models.addTodoEntry, .{ t.task, t.description });

    if (id) |_id| {
        const status = try utils.toStringFromInt(
            ctx.allocator,
            "{d} task persisted",
            _id,
        );
        ctx.info(status);
    }

    var row = try ctx.SQL.queryRow(
        models.getTodoEntry,
        .{},
    ) orelse unreachable;
    defer row.deinit() catch {};

    const res = try row.to(models.Todo, .{});

    var response = models.HandlerTodo{
        .id = try std.fmt.allocPrint(
            ctx.allocator,
            "{d}",
            .{res.id.?},
        ),
        .description = res.description,
        .task = res.task,
        .isDone = res.isDone,
    };
    response.created_at = try utils.DTtimestampz(
        ctx.allocator,
        res.created_at,
    );

    ctx.response.setStatus(.ok);
    ctx.response.header("HX-Refresh", "true");
}

pub fn deleteTodo(ctx: *Context) !void {
    const id = ctx.param("id");
    ctx.info(id);

    const row = ctx.SQL.queryRow(
        models.getTodoByID,
        .{id},
    ) catch |err| {
        ctx.response.setStatus(.internal_server_error);
        ctx.err("something went wrong!");
        ctx.any(err);
        return;
    };

    if (row == null) {
        const msg = try utils.toString(
            ctx.allocator,
            "No valid data found for id: {s}",
            id,
        );
        ctx.info(msg);

        ctx.response.setStatus(.not_found);
        ctx.response.header("HX-Refresh", "true");
        return;
    }

    _ = try ctx.SQL.exec(models.deleteTodo, .{id});

    ctx.response.setStatus(.ok);
    ctx.response.header("HX-Refresh", "true");
}

pub fn updateTodo(ctx: *Context) !void {
    const todoID = ctx.param("id");

    const t = try ctx.bind(models.Todo);

    // persist todo entry in database
    const id = try ctx.SQL.exec(
        models.updateTodo,
        .{ t.?.task.?, t.?.description.?, todoID },
    );

    if (id) |_id| {
        const status = try utils.toStringFromInt(
            ctx.allocator,
            "{d} task updated",
            _id,
        );
        ctx.info(status);
    }

    var row = try ctx.SQL.queryRow(
        models.getTodoByID,
        .{todoID},
    ) orelse unreachable;
    defer row.deinit() catch {};

    const res = try row.to(models.Todo, .{});

    var response = models.HandlerTodo{
        .id = try std.fmt.allocPrint(
            ctx.allocator,
            "{d}",
            .{res.id.?},
        ),
        .description = res.description,
        .task = res.task,
        .isDone = res.isDone,
    };
    response.created_at = try utils.DTtimestampz(
        ctx.allocator,
        res.created_at,
    );

    var sb = Builder.init(ctx.allocator);
    try helper.innerHtmlItem(ctx.allocator, &sb, &response);
    ctx.response.content_type = .HTML;
    ctx.response.setStatus(.ok);
    ctx.response.body = sb.string();
}

pub fn markDone(ctx: *Context) !void {
    const todoID = ctx.param("id");

    // persist todo entry in database
    const id = try ctx.SQL.exec(models.updateDone, .{ true, todoID });

    if (id) |_id| {
        const status = try utils.toStringFromInt(
            ctx.allocator,
            "{d} task updated",
            _id,
        );
        ctx.info(status);
    }

    var row = try ctx.SQL.queryRow(
        models.getTodoByID,
        .{todoID},
    ) orelse unreachable;
    defer row.deinit() catch {};

    const res = try row.to(models.Todo, .{});

    var response = models.HandlerTodo{
        .id = try std.fmt.allocPrint(
            ctx.allocator,
            "{d}",
            .{res.id.?},
        ),
        .description = res.description,
        .task = res.task,
        .isDone = res.isDone,
    };
    response.created_at = try utils.DTtimestampz(
        ctx.allocator,
        res.created_at,
    );

    var sb = Builder.init(ctx.allocator);
    try helper.innerHtmlItem(ctx.allocator, &sb, &response);
    ctx.response.content_type = .HTML;
    ctx.response.setStatus(.ok);
    ctx.response.body = sb.string();
}

pub fn markUndone(ctx: *Context) !void {
    const todoID = ctx.param("id");

    // persist todo entry in database
    const id = try ctx.SQL.exec(models.updateDone, .{ false, todoID });

    if (id) |_id| {
        const status = try utils.toStringFromInt(
            ctx.allocator,
            "{d} task updated",
            _id,
        );
        ctx.info(status);
    }

    var row = try ctx.SQL.queryRow(
        models.getTodoByID,
        .{todoID},
    ) orelse unreachable;
    defer row.deinit() catch {};

    const res = try row.to(models.Todo, .{});

    var response = models.HandlerTodo{
        .id = try std.fmt.allocPrint(
            ctx.allocator,
            "{d}",
            .{res.id.?},
        ),
        .description = res.description,
        .task = res.task,
        .isDone = res.isDone,
    };
    response.created_at = try utils.DTtimestampz(ctx.allocator, res.created_at);

    var sb = Builder.init(ctx.allocator);
    try helper.innerHtmlItem(ctx.allocator, &sb, &response);
    ctx.response.content_type = .HTML;
    ctx.response.setStatus(.ok);
    ctx.response.body = sb.string();
}
