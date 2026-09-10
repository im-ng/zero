const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const utils = zero.utils;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

pub fn main(init: std.process.Init) !void {
    utils.setIo(init.io);

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    _ = gpa.detectLeaks();

    const app = try App.new(allocator, init.environ_map);

    // Register a local file store rooted at ./data/uploads. With FILE_STORE_ROOT
    // set in config this is also auto-registered as the default store.
    try app.addFileStore("uploads", .local, .{ .root = "./data/uploads" });

    try app.get("/", indexHandler);
    try app.post("/upload", uploadHandler);
    try app.get("/download/:name", downloadHandler);

    try app.run();
}

fn indexHandler(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.header("content-type", "text/html");
    ctx.response.body =
        \\<h1>Upload a file</h1>
        \\<form method=post action=/upload enctype="multipart/form-data">
        \\  <input type=file name=file required>
        \\  <button type=submit>Upload</button>
        \\</form>
    ;
}

fn uploadHandler(ctx: *Context) !void {
    const f = (try ctx.GetFile("file")) orelse {
        ctx.response.setStatus(.bad_request);
        try ctx.json(.{ .@"error" = "no 'file' field in multipart form" });
        return;
    };

    // Persist the uploaded bytes into the "uploads" store (keyed by filename).
    try ctx.SaveFileToStore("uploads", f.filename, f.data);

    try ctx.json(.{ .stored = f.filename, .bytes = f.size });
}

fn downloadHandler(ctx: *Context) !void {
    const name = ctx.param("name");
    // `data` is request-arena owned and valid through the response write, so it
    // must not be freed inside the handler.
    const data = (try ctx.GetFileFromStore("uploads", name)) orelse {
        ctx.response.setStatus(.not_found);
        return;
    };

    ctx.response.body = data;
    ctx.response.header("content-type", "application/octet-stream");
    const disp = try std.fmt.allocPrint(ctx.allocator, "attachment; filename=\"{s}\"", .{name});
    ctx.response.header("content-disposition", disp);
    ctx.response.setStatus(.ok);
}
