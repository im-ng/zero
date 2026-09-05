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
    var _rows = std.array_list.Managed(models.Todo).init(ctx.allocator);
    _ = try ctx.SQL.selectSlice(ctx, models.Todo, &_rows, models.getAllTodos, .{});

    var responses = std.array_list.Managed(
        models.HandlerTodo,
    ).init(
        ctx.allocator,
    );

    for (_rows.items) |row| {
        const response = models.HandlerTodo{
            .id = try std.fmt.allocPrint(ctx.allocator, "{d}", .{row.id.?}),
            .description = row.description,
            .task = row.task,
            .isDone = row.is_done,
            .created_at = try utils.DTtimestampz(
                ctx.allocator,
                row.created_at,
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

    const row: ?models.Todo = ctx.SQL.select(
        ctx,
        models.Todo,
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

    // const res = try row.?.to(models.Todo, .{});

    var response = models.HandlerTodo{
        .id = try std.fmt.allocPrint(ctx.allocator, "{d}", .{row.?.id.?}),
        .description = row.?.description,
        .task = row.?.task,
        .isDone = row.?.is_done,
    };
    response.created_at = try utils.DTtimestampz(ctx.allocator, row.?.created_at);

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
    const id = try ctx.SQL.exec(ctx, models.addTodoEntry, .{ t.task, t.description });

    {
        const status = try utils.toStringFromInt(
            ctx.allocator,
            "{d} task persisted",
            id,
        );
        ctx.info(status);
    }

    const row: ?models.Todo = try ctx.SQL.select(
        ctx,
        models.Todo,
        models.getTodoEntry,
        .{},
    );

    var response = models.HandlerTodo{
        .id = try std.fmt.allocPrint(
            ctx.allocator,
            "{d}",
            .{row.?.id.?},
        ),
        .description = row.?.description,
        .task = row.?.task,
        .isDone = row.?.is_done,
    };
    response.created_at = try utils.DTtimestampz(
        ctx.allocator,
        row.?.created_at,
    );

    ctx.response.setStatus(.ok);
    ctx.response.header("HX-Refresh", "true");
}

pub fn deleteTodo(ctx: *Context) !void {
    const id = ctx.param("id");
    ctx.info(id);

    const row = ctx.SQL.queryRow(
        ctx,
        models.Todo,
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

    _ = try ctx.SQL.exec(ctx, models.deleteTodo, .{id});

    ctx.response.setStatus(.ok);
    ctx.response.header("HX-Refresh", "true");
}

pub fn updateTodo(ctx: *Context) !void {
    const todoID = ctx.param("id");

    const t = try ctx.bind(models.Todo);

    // persist todo entry in database
    const id = try ctx.SQL.exec(
        ctx,
        models.updateTodo,
        .{ t.?.task.?, t.?.description.?, todoID },
    );

    if (id != 0) {
        const status = try utils.toStringFromInt(
            ctx.allocator,
            "{d} task updated",
            id,
        );
        ctx.info(status);
    }

    const row: ?models.Todo = try ctx.SQL.select(
        ctx,
        models.Todo,
        models.getTodoByID,
        .{todoID},
    );
    // const res = try row.to(models.Todo, .{});

    var response = models.HandlerTodo{
        .id = try std.fmt.allocPrint(
            ctx.allocator,
            "{d}",
            .{row.?.id.?},
        ),
        .description = row.?.description,
        .task = row.?.task,
        .isDone = row.?.is_done,
    };
    response.created_at = try utils.DTtimestampz(
        ctx.allocator,
        row.?.created_at,
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
    const id = try ctx.SQL.exec(ctx, models.updateDone, .{ true, todoID });

    if (id != 0) {
        const status = try utils.toStringFromInt(
            ctx.allocator,
            "{d} task updated",
            id,
        );
        ctx.info(status);
    }

    const row = try ctx.SQL.queryRow(
        ctx,
        models.Todo,
        models.getTodoByID,
        .{todoID},
    ) orelse unreachable;
    // defer row.deinit() catch {};

    // const res = try row.to(models.Todo, .{});

    var response = models.HandlerTodo{
        .id = try std.fmt.allocPrint(
            ctx.allocator,
            "{d}",
            .{row.id.?},
        ),
        .description = row.description,
        .task = row.task,
        .isDone = row.is_done,
    };
    response.created_at = try utils.DTtimestampz(
        ctx.allocator,
        row.created_at,
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
    const id = try ctx.SQL.exec(ctx, models.updateDone, .{ false, todoID });

    if (id != 0) {
        const status = try utils.toStringFromInt(
            ctx.allocator,
            "{d} task updated",
            id,
        );
        ctx.info(status);
    }

    const row = try ctx.SQL.queryRow(
        ctx,
        models.Todo,
        models.getTodoByID,
        .{todoID},
    ) orelse unreachable;
    // defer row.deinit() catch {};

    // const res = try row.to(models.Todo, .{});

    var response = models.HandlerTodo{
        .id = try std.fmt.allocPrint(
            ctx.allocator,
            "{d}",
            .{row.id.?},
        ),
        .description = row.description,
        .task = row.task,
        .isDone = row.is_done,
    };
    response.created_at = try utils.DTtimestampz(ctx.allocator, row.created_at);

    var sb = Builder.init(ctx.allocator);
    try helper.innerHtmlItem(ctx.allocator, &sb, &response);
    ctx.response.content_type = .HTML;
    ctx.response.setStatus(.ok);
    ctx.response.body = sb.string();
}
