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

    // Register an S3-compatible object store. Credentials/region/bucket come from
    // env (S3_REGION, S3_BUCKET, S3_ACCESS_KEY, S3_SECRET_KEY, S3_ENDPOINT).
    // `SaveFileToStore` / `GetFileFromStore` / `DeleteFileFromStore` / listing all
    // work against the bucket; keys map 1:1 to S3 object keys.
    try app.addFileStore("assets", .s3, .{});

    try app.get("/", indexHandler);
    try app.post("/upload", uploadHandler);
    try app.get("/file/:name", downloadHandler);
    try app.delete("/file/:name", deleteHandler);

    try app.run();
}

fn indexHandler(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.header("content-type", "text/html");
    ctx.response.body =
        \\<h1>Upload to S3-compatible store</h1>
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

    try ctx.SaveFileToStore("assets", f.filename, f.data);
    try ctx.json(.{ .stored = f.filename, .bytes = f.size });
}

fn downloadHandler(ctx: *Context) !void {
    const name = ctx.param("name");
    const data = (try ctx.GetFileFromStore("assets", name)) orelse {
        ctx.response.setStatus(.not_found);
        return;
    };
    ctx.response.header("content-type", "application/octet-stream");
    const disp = try std.fmt.allocPrint(ctx.allocator, "attachment; filename=\"{s}\"", .{name});
    ctx.response.header("content-disposition", disp);
    ctx.response.setStatus(.ok);
    try ctx.response.writer().writeAll(data);
}

fn deleteHandler(ctx: *Context) !void {
    const name = ctx.param("name");
    try ctx.DeleteFileFromStore("assets", name);
    ctx.response.setStatus(.ok);
    try ctx.json(.{ .deleted = name });
}
