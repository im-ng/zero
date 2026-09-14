const std = @import("std");
const Io = std.Io;
const root = @import("../zero.zig");

/// Local-disk file store. Keys are treated as posix-style relative paths under
/// a configured root directory; `..` segments are rejected to prevent path
/// traversal outside the root.
pub const FileStoreLocal = struct {
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    max_bytes: usize = 100 * 1024 * 1024,

    pub fn open(allocator: std.mem.Allocator, root_dir: []const u8) !*FileStoreLocal {
        const self = try allocator.create(FileStoreLocal);
        errdefer allocator.destroy(self);

        self.* = .{ .allocator = allocator, .root_dir = root_dir };

        // Create the root eagerly so the store is usable immediately.
        std.Io.Dir.cwd().createDirPath(root.utils.io, root_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        return self;
    }

    /// Resolve `key` to an absolute-ish path under `root_dir`, rejecting any
    /// `..` segment. The returned path is allocated with `ctx.allocator` and
    /// owned by the caller.
    fn resolve(self: *FileStoreLocal, ctx: *root.Context, key: []const u8) ![]const u8 {
        var total: usize = self.root_dir.len;
        var it = std.mem.splitScalar(u8, key, '/');
        while (it.next()) |p| {
            if (p.len == 0) continue;
            if (std.mem.eql(u8, p, "..")) return error.InvalidFilePath;
            total += 1 + p.len;
        }

        const path = try ctx.allocator.alloc(u8, total);
        errdefer ctx.allocator.free(path);

        var off: usize = 0;
        @memcpy(path[off .. off + self.root_dir.len], self.root_dir);
        off += self.root_dir.len;

        it = std.mem.splitScalar(u8, key, '/');
        while (it.next()) |p| {
            if (p.len == 0) continue;
            path[off] = '/';
            off += 1;
            @memcpy(path[off .. off + p.len], p);
            off += p.len;
        }
        return path;
    }

    pub fn get(self: *FileStoreLocal, ctx: *root.Context, key: []const u8) !?[]const u8 {
        const path = try self.resolve(ctx, key);
        defer ctx.allocator.free(path);

        const file = std.Io.Dir.cwd().openFile(ctx.io, path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close(ctx.io);

        var rbuf: [8192]u8 = undefined;
        var reader = file.reader(ctx.io, &rbuf);
        const data = try reader.interface.allocRemainingAlignedSentinel(
            ctx.allocator,
            Io.Limit.limited(self.max_bytes),
            std.mem.Alignment.@"1",
            null,
        );
        return data;
    }

    pub fn create(self: *FileStoreLocal, ctx: *root.Context, key: []const u8, data: []const u8) !void {
        const path = try self.resolve(ctx, key);
        defer ctx.allocator.free(path);

        if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
            const dir = path[0..idx];
            std.Io.Dir.cwd().createDirPath(ctx.io, dir) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }

        try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = data });
    }

    pub fn delete(self: *FileStoreLocal, ctx: *root.Context, key: []const u8) !void {
        const path = try self.resolve(ctx, key);
        defer ctx.allocator.free(path);
        try std.Io.Dir.cwd().deleteFile(ctx.io, path);
    }

    pub fn list(self: *FileStoreLocal, ctx: *root.Context, prefix: []const u8) ![][]const u8 {
        var out = std.ArrayList([]const u8).init(ctx.allocator);
        errdefer {
            for (out.items) |k| ctx.allocator.free(k);
            out.deinit();
        }
        try self.walk(ctx.allocator, self.root_dir, prefix, &out);
        return out.toOwnedSlice();
    }

    fn walk(
        self: *FileStoreLocal,
        allocator: std.mem.Allocator,
        dir: []const u8,
        prefix: []const u8,
        out: *std.ArrayList([]const u8),
    ) !void {
        var d = std.Io.Dir.cwd().openDir(root.utils.io, dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer d.close(root.utils.io);

        var it = d.iterate();
        while (try it.next(root.utils.io)) |entry| {
            const child = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, entry.name });
            if (entry.kind == .directory) {
                try self.walk(allocator, child, prefix, out);
                allocator.free(child);
                continue;
            }

            // Strip the root prefix (+ leading separator) to get the relative key.
            if (child.len <= self.root_dir.len) continue;
            const rel = child[self.root_dir.len + 1 ..];
            if (prefix.len == 0 or std.mem.startsWith(u8, rel, prefix)) {
                try out.append(try allocator.dupe(u8, rel));
            }
            allocator.free(child);
        }
    }
};


// ===================== Tests =====================


test "FileStoreLocal: create/get/delete/list + path-traversal guard" {
    const ta = std.testing;
    const root_dir = ".ztmp-filestore-local";
    defer std.Io.Dir.cwd().deleteTree(root.utils.io, root_dir) catch {};

    var ctx: root.Context = undefined;
    ctx.allocator = ta.allocator;

    const store = try FileStoreLocal.open(ta.allocator, root_dir);
    defer ta.allocator.destroy(store);

    try store.create(&ctx, "avatars/user1.png", "binarydata");
    try store.create(&ctx, "docs/readme.txt", "hello world");

    const got = (try store.get(&ctx, "docs/readme.txt")).?;
    defer ta.allocator.free(got);
    try ta.expectEqualStrings("hello world", got);

    const list = try store.list(&ctx, "avatars/");
    defer {
        for (list) |k| ta.allocator.free(k);
        ta.allocator.free(list);
    }
    try ta.expectEqual(@as(usize, 1), list.len);
    try ta.expectEqualStrings("avatars/user1.png", list[0]);

    const all = try store.list(&ctx, "");
    defer {
        for (all) |k| ta.allocator.free(k);
        ta.allocator.free(all);
    }
    try ta.expectEqual(@as(usize, 2), all.len);

    try store.delete(&ctx, "docs/readme.txt");
    try ta.expectEqual(@as(?[]const u8, null), try store.get(&ctx, "docs/readme.txt"));

    // path traversal must be rejected
    try ta.expectError(error.InvalidFilePath, store.get(&ctx, "../escape.txt"));
    try ta.expectError(error.InvalidFilePath, store.create(&ctx, "a/../../escape.txt", "x"));
}
