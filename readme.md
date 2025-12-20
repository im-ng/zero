![zero](./static/zero-fmk.png)

Zero is a strongly opinionated web framework written in Zig, built on top of http.zig that aims for zero allocations and created to make development easier while keeping performance and observability in mind.

Zero framework is completely configurable, you may isolate and attach best-in-class built-in solutions as you see fit using the 12 Factor App methodology.

zero framework has useful features like drop-in support for numerous `databases`, `queuing systems`, and external services, as well as `REST`, `authentication`, `logging`, `metrics`, `observability`, and `scheduling`.

### Zero mascot

![mascot](./static/iguanax128.png)

### What is available? 

Check [feature parity](./feature_parity.md) file to know more upcoming and missing things.

### Pre-requisite 

```bash
❯ zig version
0.15.1
```

### How to get started?

[zero-docs](https://im-ng.github.io/zero-docs/) covers all examples and documentations of the `zero` framework.  Take a deep dive into the framework, usage and outcomes of each built-in services and solutions.

- [Basic](https://im-ng.github.io/zero-docs/hello-zero.html)
- [Authentications](https://im-ng.github.io/zero-docs/authentication.html)
- [CRUD Operations](https://im-ng.github.io/zero-docs/htmx-crud.html)
- [Scheduler](https://im-ng.github.io/zero-docs/cronz.html)
- [Websockets](https://im-ng.github.io/zero-docs/websocket.html)
- [OnStartup](https://im-ng.github.io/zero-docs/caching.html)
- [Pub/Sub](https://im-ng.github.io/zero-docs/message-queue-publisher.html)
- [Data Migrations](https://im-ng.github.io/zero-docs/migrations.html)

### Installation

Add zero to your build.zig.zon:

```
zig fetch --save https://github.com/im-ng/zero/archive/refs/heads/main.zip
```

### Usage

0. Create a new zero fmk application

```bash
mkdir zero-web-app && cd zero-web-app
zig init
zig fetch --save https://github.com/im-ng/zero/archive/refs/heads/main.zip

```

1. Update dependency to load `zero` module

```zig
const target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{});

const zero = b.dependency("zero", .{});

const exe = b.addExecutable(.{
    .name = "basic",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});

exe.root_module.addImport("zero", zero.module("zero"));

b.installArtifact(exe);

const run_cmd = b.addRunArtifact(exe);
run_cmd.step.dependOn(b.getInstallStep());
if (b.args) |args| {
    run_cmd.addArgs(args);
}

const run_step = b.step("basic", "Run basic http server");
run_step.dependOn(&run_cmd.step);
```

2. Add service configrations `configs/.env` to attach to basic web-app

```bash
cd zero-web-app
mkdir configs
touch configs/.env
```

```bash
APP_ENV=dev
APP_NAME=basic-app
APP_VERSION=1.0.0
LOG_LEVEL=debug

# DB_HOST=localhost
# DB_USER=user1
# DB_PASSWORD=password1
# DB_NAME=demo
# DB_PORT=5432
# DB_DIALECT=postgres

# REDIS_HOST=127.0.0.1
# REDIS_PORT=6379
# REDIS_USER=redis
# REDIS_PASSWORD=password
# REDIS_DB=0
```

2. Start writing your first zero web-app to serve requests

```zig
const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // create zero App
    // internally it loads container with db, logs, metrics
    const app = try App.new(allocator);

    // register routes on app
    try app.get("/json", jsonResponse);

    // register route to handle db queries
    // try app.get("/user", dbResponse);

    // register route to handle redis queries
    // try app.get("/redis", redisResponse);

    // try app.addHttpService("auth-service", "http://external-service:8081");

    // try app.get("/status", serviceStatus);

    // start the server by invoking run
    try app.run();
}

pub fn jsonResponse(ctx: *Context) !void {
    try ctx.json(.{ .msg = "hello json!" });
}

pub fn dbResponse(ctx: *Context) !void {
    const User = struct {
        id: i32,
        name: []const u8,
    };

    var row = try ctx.SQL.row(ctx.allocator, "select id, name from users limit 1", .{}) orelse unreachable;
    defer row.deinit() catch {};

    const user = try row.to(User, .{});
    try ctx.json(user);
}

pub fn redisResponse(ctx: *Context) !void {
    const reply = try ctx.Cache.sendAlloc([]u8, ctx.allocator, .{ "GET", "msg" });
    defer ctx.allocator.free(reply);

    try ctx.json(reply);
}

const RemoteSvcResponse = struct {
    msg: []u8,
};

fn serviceStatus(ctx: *Context) !void {
    const service = ctx.GetService("auth-service");

    if (service) |basicSvc| {
        const response = try basicSvc.Get(RemoteSvcResponse, "/keys", null, null);

        try ctx.json(response);
    }
}
```

3. Run your new web app.

```
❯ zig build basic-web-app
❯ zig build basic
 INFO [03:23:39] Loaded config from file: ./configs/.env
 INFO [03:23:39] config overriden from: ./configs/.dev.env
 INFO [03:23:39] generating database connection string for postgres
 INFO [03:23:39] connected to user1 user to demo database at 'localhost:5432'
 INFO [03:23:39] connecting to redis at '127.0.0.1:6379' on database 0
 INFO [03:23:39] ping status PONG
 INFO [03:23:39] connected to redis at '127.0.0.1:6379' on database 0
 INFO [03:23:39] container is being created
 INFO [03:23:39] basic-web-app app pid 181443
 INFO [03:23:39] warming up the cache entries
 INFO [03:23:41] cache prepared
 INFO [03:23:41] registered static files from directory ./static
 INFO [03:23:41] Starting server on port: 8080
 INFO [03:23:42] 0199d969-d541-7000-b7e6-8f6cc9c93ed4    200 0ms .GET /json
 INFO [03:23:43] 0199d96a-00ed-7000-994d-839cc86b1fdb    200 0ms .GET /metrics
 INFO [03:23:44] 0199d96a-1f88-7000-9dd4-4ed394ef5a68    200 0ms .GET /index.html
 INFO [03:23:44] 0199d96b-0873-7000-b391-28f26e5d963d    200 0ms .GET /test.txt
 INFO [03:23:45] 0199d96b-1412-7000-9eaf-f4f88888053e    200 0ms .GET /
 INFO [05:05:37] 019a149b-abca-7000-b307-fc04282cc334    200 1ms GET http://external-service:8081/json
 INFO [05:05:37] 019a149b-abc9-7000-ae1e-38847fb79210    200 1ms GET /status
```

### Simple Benchmark

Running the [zero-basic](./examples/zero-basic/) example with none as log_level to preview the framework baseline, but typically we don't use `none` in development environment :)

```bash
 go-wrk -c 100 -d 100 http://localhost:8080/json
Running 100s test @ http://localhost:8080/json
  100 goroutine(s) running concurrently
8344879 requests in 1m39.643117619s, 1.39GB read
Requests/sec:		83747.67
Transfer/sec:		14.30MB
Overall Requests/sec:	83430.16
Overall Transfer/sec:	14.24MB
Fastest Request:	84µs
Avg Req Time:		1.193ms
Slowest Request:	19.669ms
Number of Errors:	0
10%:			124µs
50%:			150µs
75%:			164µs
99%:			175µs
99.9%:			176µs
99.9999%:		176µs
99.99999%:		176µs
stddev:			743µs
```

### Attributions

Refer to [Attribution](./attribution.md) file more details.

### 📄 License

[Apache](./LICENSE)

This project is licensed under the Apache License 

Please refer the LICENSE file for details.
