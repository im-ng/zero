const std = @import("std");
const root = @import("../zero.zig");

/// Backend implementations available through the `FileStore` interface.
pub const Backend = enum {
    local,
    ftp,
    sftp,
};

/// Options used when registering a store via `App.addFileStore`.
pub const Options = struct {
    /// Root directory for the `local` backend. When empty, falls back to
    /// `FILE_STORE_ROOT` (or `./data/files`).
    root: []const u8 = "",
};

/// An uploaded file received via a `multipart/form-data` request. The `data`
/// slice is owned by the request's arena and is valid only for the duration of
/// the handler; copy it (e.g. into a `FileStore`) if it must outlive the request.
pub const UploadedFile = struct {
    data: []const u8,
    filename: []const u8,
    size: usize,
};

/// Unified, type-erased file store handle. Mirrors `root.KVStore` so a caller
/// can use `get`/`create`/`delete`/`list` without knowing the backend.
///
/// Returned slices from `get`/`list` are allocated with `ctx.allocator` and
/// owned by the caller (free with `ctx.allocator.free`).
pub const FileStore = struct {
    ptr: *anyopaque,
    backend: Backend,

    pub fn init(ptr: anytype, backend: Backend) FileStore {
        return .{
            .ptr = @ptrCast(@alignCast(ptr)),
            .backend = backend,
        };
    }

    pub fn get(self: *FileStore, ctx: *root.Context, key: []const u8) !?[]const u8 {
        return switch (self.backend) {
            .local => @as(*local.FileStoreLocal, @ptrCast(@alignCast(self.ptr))).get(ctx, key),
            .ftp, .sftp => error.FileStoreBackendNotImplemented,
        };
    }

    pub fn create(self: *FileStore, ctx: *root.Context, key: []const u8, data: []const u8) !void {
        return switch (self.backend) {
            .local => @as(*local.FileStoreLocal, @ptrCast(@alignCast(self.ptr))).create(ctx, key, data),
            .ftp, .sftp => error.FileStoreBackendNotImplemented,
        };
    }

    pub fn delete(self: *FileStore, ctx: *root.Context, key: []const u8) !void {
        return switch (self.backend) {
            .local => @as(*local.FileStoreLocal, @ptrCast(@alignCast(self.ptr))).delete(ctx, key),
            .ftp, .sftp => error.FileStoreBackendNotImplemented,
        };
    }

    pub fn list(self: *FileStore, ctx: *root.Context, prefix: []const u8) ![][]const u8 {
        return switch (self.backend) {
            .local => @as(*local.FileStoreLocal, @ptrCast(@alignCast(self.ptr))).list(ctx, prefix),
            .ftp, .sftp => error.FileStoreBackendNotImplemented,
        };
    }
};

/// Construct a backend instance from the container's configured connections and
/// wrap it in a type-erased `FileStore`. The returned handle is owned by the
/// caller (typically `container.fileStores`).
pub fn build(container: *root.container, backend: Backend, opts: Options) !*FileStore {
    const store = try container.allocator.create(FileStore);
    errdefer container.allocator.destroy(store);

    switch (backend) {
        .local => {
            const root_dir = if (opts.root.len > 0)
                opts.root
            else
                container.config.getOrDefault("FILE_STORE_ROOT", "./data/files");
            const b = try local.FileStoreLocal.open(container.allocator, root_dir);
            store.* = FileStore.init(b, .local);
        },
        .ftp, .sftp => return error.FileStoreBackendNotImplemented,
    }
    return store;
}

pub const local = @import("local.zig");
