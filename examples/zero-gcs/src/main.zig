const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    _ = gpa.detectLeaks();

    const app = try App.new(allocator, init.io, init.environ_map);

    // Register a Google Cloud Storage file store. Object keys map 1:1 to GCS
    // object names, so `/file/:name?username=` style composite keys read back
    // exactly what was saved. Credentials come from env before startup:
    //   GCS_BUCKET          bucket name (required)
    //   GCS_PROJECT         project id (required)
    //   GCS_CLIENT_ID       OAuth2 client id
    //   GCS_CLIENT_SECRET   OAuth2 client secret
    //   GCS_ACCESS_TOKEN    bearer token (skips the OAuth2 grant when set)
    //   GCS_ENDPOINT        https://storage.googleapis.com (emulator-friendly)
    //   GCS_SCOPE           https://www.googleapis.com/auth/devstorage.full_control
    try app.addFileStore("assets", .gcs, .{});

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
        \\<h1>Upload to Google Cloud Storage</h1>
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
