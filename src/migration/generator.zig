const std = @import("std");
const zero = @import("../zero.zig");
const utils = zero.utils;

const migrations_dir = "src/migrations";
const all_file = "all.zig";

fn sanitizeName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const buf = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        buf[i] = if (c == '-') '_' else c;
    }
    return buf;
}

fn epochSeconds() i64 {
    return @as(i64, @intCast(@divFloor(utils.nowReal().nanoseconds, 1_000_000_000)));
}

fn nameLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Scaffold a new migration into `src/migrations/` (the CLI entry point).
pub fn add(allocator: std.mem.Allocator, raw_name: []const u8) !void {
    return addToDir(allocator, migrations_dir, raw_name);
}

/// Scaffold a new migration into `dir`, then regenerate `all.zig` there.
fn addToDir(allocator: std.mem.Allocator, dir: []const u8, raw_name: []const u8) !void {
    const name = try sanitizeName(allocator, raw_name);
    const cwd = std.Io.Dir.cwd();
    const io = utils.io;

    // 2. Create the migrations directory if it does not exist (mkdir -p).
    cwd.createDirPath(io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.zig", .{ dir, name });

    // Guard: do not clobber an existing migration.
    const existing = cwd.openFile(io, file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |f| {
        f.close(io);
        std.debug.print("error: migration '{s}' already exists\n", .{file_path});
        return error.MigrationAlreadyExists;
    }

    const epoch = epochSeconds();

    // The migration run function is named `<name>_run`.
    const fn_name = try std.fmt.allocPrint(allocator, "{s}_run", .{name});
    defer allocator.free(fn_name);

    var sb = std.ArrayList(u8).empty;
    defer sb.deinit(allocator);

    try sb.appendSlice(allocator,
        \\const std = @import("std");
        \\const zero = @import("zero");
        \\const Context = zero.Context;
        \\const migrate = zero.migrate;
        \\
        \\pub const migrationNumber: i64 = 
    );
    const epoch_line = try std.fmt.allocPrint(allocator, "{d};\n\n", .{epoch});
    try sb.appendSlice(allocator, epoch_line);
    allocator.free(epoch_line);

    // Normal (non-multiline) string literal so the SQL placeholder's `\\`
    // survives verbatim as two backslashes in the generated file.
    const fn_prefix = try std.fmt.allocPrint(
        allocator,
        "pub fn {s}(c: *Context) anyerror!void {{\n    const query =\n",
        .{fn_name},
    );
    try sb.appendSlice(allocator, fn_prefix);
    allocator.free(fn_prefix);

    // The generated file needs exactly two backslashes (`\\`) to start the
    // multiline-string SQL line. A Zig string literal halves backslashes, so
    // four source backslashes yield the two we want in the output file.
    try sb.appendSlice(allocator, "        \\\\ -- TODO: write your migration SQL\n    ;\n    _ = try c.SQL.exec(c, query, .{});\n}\n\n");

    const migrate_line = try std.fmt.allocPrint(
        allocator,
        \\pub const _migrate = &migrate{{
        \\    .migrationNumber = migrationNumber,
        \\    .run = {s},
        \\}};
    ,
        .{fn_name},
    );
    try sb.appendSlice(allocator, migrate_line);
    allocator.free(migrate_line);

    const content = try sb.toOwnedSlice(allocator);
    try cwd.writeFile(io, .{ .sub_path = file_path, .data = content });

    try regenerateAll(allocator, io, cwd, dir);

    printReminders(allocator, file_path, epoch, dir);
}

/// Rebuild `all.zig` by scanning the directory for `*.zig` files (excluding
/// `all.zig`). Run order is irrelevant — `migration.run` sorts by
/// migrationNumber at execution time.
fn regenerateAll(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, dir: []const u8) !void {
    var d = cwd.openDir(io, dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer d.close(io);

    var list = std.ArrayList([]const u8).empty;
    defer {
        for (list.items) |it| allocator.free(it);
        list.deinit(allocator);
    }

    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.eql(u8, entry.name, all_file)) continue;
        const owned = try allocator.dupe(u8, entry.name[0 .. entry.name.len - ".zig".len]);
        try list.append(allocator, owned);
    }

    std.mem.sort([]const u8, list.items, {}, nameLessThan);

    var sb = std.ArrayList(u8).empty;
    defer sb.deinit(allocator);

    try sb.appendSlice(allocator,
        \\const std = @import("std");
        \\const Self = @This();
        \\const migrations = @This();
        \\const zero = @import("zero");
        \\
        \\const App = zero.App;
        \\const migrate = zero.migrate;
        \\const utils = zero.utils;
        \\
    );
    for (list.items) |n| {
        const line = try std.fmt.allocPrint(allocator, "const {s} = @import(\"{s}.zig\");\n", .{ n, n });
        try sb.appendSlice(allocator, line);
    }
    try sb.appendSlice(allocator,
        \\
        \\pub fn all(app: *App) !void {
        \\
    );
    for (list.items) |n| {
        const line = try std.fmt.allocPrint(
            allocator,
            "    try app.addMigration(try Key(app, {s}._migrate), {s}._migrate);\n",
            .{ n, n },
        );
        try sb.appendSlice(allocator, line);
    }
    try sb.appendSlice(allocator,
        \\}
        \\
        \\fn Key(app: *App, m: *const migrate) ![]const u8 {
        \\    return try utils.toStringFromInt(app.container.allocator, "{d}", m.migrationNumber);
        \\}
    );

    const all_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, all_file });
    try cwd.writeFile(io, .{ .sub_path = all_path, .data = sb.items });
}

fn printReminders(allocator: std.mem.Allocator, file_path: []const u8, epoch: i64, dir: []const u8) void {
    const out = std.Io.File.stdout();
    const all_path = std.fmt.allocPrint(allocator, "{s}/all.zig", .{dir}) catch "";
    defer allocator.free(all_path);
    const epoch_msg = std.fmt.allocPrint(allocator, " (migrationNumber = {d})\n", .{epoch}) catch "";
    defer allocator.free(epoch_msg);

    out.writeStreamingAll(utils.io, "\n") catch {};
    out.writeStreamingAll(utils.io, "Created migration: ") catch {};
    out.writeStreamingAll(utils.io, file_path) catch {};
    out.writeStreamingAll(utils.io, epoch_msg) catch {};
    out.writeStreamingAll(utils.io, "Updated: ") catch {};
    out.writeStreamingAll(utils.io, all_path) catch {};
    out.writeStreamingAll(utils.io,
        \\
        \\
        \\# Make sure to invoke the all migrations.
        \\try migrations.all(app);
        \\
        \\# To run migrations add this line
        \\try app.runMigrations();
        \\
    ) catch {};
}

test "generator: scaffold migration and regenerate all.zig" {
    const ta = std.testing;
    const allocator = ta.allocator;

    const dir = ".ztmp-migration-generator";
    const cwd = std.Io.Dir.cwd();
    const io = zero.utils.io;
    cwd.createDirPath(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try addToDir(allocator, dir, "create-user-table");
    try addToDir(allocator, dir, "add_entries");

    // First migration should have been sanitized: hyphen -> underscore.
    _ = cwd.openFile(io, dir ++ "/create_user_table.zig", .{}) catch |err| {
        std.debug.print("expected create_user_table.zig: {any}\n", .{err});
        return err;
    };

    const all_buf = try readFileAlloc(allocator, io, dir ++ "/all.zig");
    defer allocator.free(all_buf);

    try ta.expect(std.mem.indexOf(u8, all_buf, "const create_user_table = @import(\"create_user_table.zig\");") != null);
    try ta.existing(std.mem.indexOf(u8, all_buf, "const add_entries = @import(\"add_entries.zig\");") != null);
    try ta.expect(std.mem.indexOf(u8, all_buf, "try app.addMigration(try Key(app, create_user_table._migrate), create_user_table._migrate);") != null);
    try ta.expect(std.mem.indexOf(u8, all_buf, "try app.addMigration(try Key(app, add_entries._migrate), add_entries._migrate);") != null);

    // Re-adding the same name must be rejected.
    try ta.expectError(error.MigrationAlreadyExists, addToDir(allocator, dir, "create-user-table"));
}

/// Test-only: read a whole file via std.Io (mirrors context.File).
fn readFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var rbuf: [8192]u8 = undefined;
    var reader = file.reader(io, &rbuf);
    return try reader.interface.allocRemainingAlignedSentinel(
        allocator,
        std.Io.Limit.limited(1 << 20),
        std.mem.Alignment.@"1",
        null,
    );
}
