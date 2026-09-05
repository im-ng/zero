const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("zero", .{
        .root_source_file = b.path("src/zero.zig"),
        .target = target,
        .optimize = optimize,
    });

    const pgz = b.dependency("pg", .{});
    module.addImport("pg", pgz.module("pg"));

    const httpz = b.dependency("httpz", .{});
    module.addImport("httpz", httpz.module("httpz"));

    const env = b.dependency("dotenv", .{});
    module.addImport("dotenv", env.module("dotenv"));

    const zul = b.dependency("zul", .{});
    module.addImport("zul", zul.module("zul"));

    const rediz = b.dependency("okredis", .{});
    module.addImport("rediz", rediz.module("okredis"));

    const zdt = b.dependency("zdt", .{});
    module.addImport("zdt", zdt.module("zdt"));

    const regexp = b.dependency("regexp", .{});
    module.addImport("regexp", regexp.module("regex"));

    const mqttz = b.dependency("mqttz", .{});
    module.addImport("mqttz", mqttz.module("mqttz"));

    const jwt = b.dependency("jwt", .{});
    module.addImport("jwt", jwt.module("zig-jwt"));

    const sqlite = b.dependency("sqlite", .{});
    module.addImport("sqlite", sqlite.module("sqlite"));

    const nats = b.dependency("nats", .{});
    module.addImport("nats", nats.module("nats"));

    // if (b.option(
    //     bool,
    //     "kafka",
    //     "attach kafka dependencies",
    // ) orelse false) {
    //     module.linkSystemLibrary("rdkafka", .{ .weak = true });
    // }
    if (builtin.os.tag == .macos) {
        module.addIncludePath(.{ .cwd_relative = "/usr/local/Cellar/librdkafka/2.13.0/include" });
        module.addLibraryPath(.{ .cwd_relative = "/usr/local/Cellar/librdkafka/2.13.0/lib" });
    }
    module.linkSystemLibrary("rdkafka", .{
        .weak = true,
    });

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("pg", pgz.module("pg"));
    test_module.addImport("httpz", httpz.module("httpz"));
    test_module.addImport("dotenv", env.module("dotenv"));
    test_module.addImport("zul", zul.module("zul"));
    test_module.addImport("rediz", rediz.module("okredis"));
    test_module.addImport("zdt", zdt.module("zdt"));
    test_module.addImport("regexp", regexp.module("regex"));
    test_module.addImport("mqttz", mqttz.module("mqttz"));
    test_module.addImport("jwt", jwt.module("zig-jwt"));
    test_module.addImport("sqlite", sqlite.module("sqlite"));
    test_module.addImport("nats", nats.module("nats"));
    test_module.addImport("zero", module);

    if (builtin.os.tag == .macos) {
        test_module.addIncludePath(.{ .cwd_relative = "/usr/local/Cellar/librdkafka/2.13.0/include" });
        test_module.addLibraryPath(.{ .cwd_relative = "/usr/local/Cellar/librdkafka/2.13.0/lib" });
    }
    test_module.linkSystemLibrary("rdkafka", .{ .weak = true });

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    // Integration tests require a real database driver (native lib) and must not
    // be traced by kcov, which aborts on driver initialization. They run via a
    // separate step that performs no coverage instrumentation.
    const integration_module = b.createModule(.{
        .root_source_file = b.path("src/tests_integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_module.addImport("pg", pgz.module("pg"));
    integration_module.addImport("httpz", httpz.module("httpz"));
    integration_module.addImport("dotenv", env.module("dotenv"));
    integration_module.addImport("zul", zul.module("zul"));
    integration_module.addImport("rediz", rediz.module("okredis"));
    integration_module.addImport("zdt", zdt.module("zdt"));
    integration_module.addImport("regexp", regexp.module("regex"));
    integration_module.addImport("mqttz", mqttz.module("mqttz"));
    integration_module.addImport("jwt", jwt.module("zig-jwt"));
    integration_module.addImport("sqlite", sqlite.module("sqlite"));
    integration_module.addImport("nats", nats.module("nats"));
    integration_module.addImport("zero", module);

    if (builtin.os.tag == .macos) {
        integration_module.addIncludePath(.{ .cwd_relative = "/usr/local/Cellar/librdkafka/2.13.0/include" });
        integration_module.addLibraryPath(.{ .cwd_relative = "/usr/local/Cellar/librdkafka/2.13.0/lib" });
    }
    integration_module.linkSystemLibrary("rdkafka", .{ .weak = true });

    const integration_tests = b.addTest(.{
        .root_module = integration_module,
    });
    const run_integration = b.addRunArtifact(integration_tests);
    const integration_step = b.step("test-integration", "Run integration tests (real database)");
    integration_step.dependOn(&run_integration.step);

    // Memory-validation harness: proves allocations under zero.Context are
    // released per request / cron tick / pubsub message. Uses a counting
    // allocator; excluded from kcov (no coverage instrumentation) like the
    // integration tests.
    const validation_module = b.createModule(.{
        .root_source_file = b.path("src/tests_validation.zig"),
        .target = target,
        .optimize = optimize,
    });
    validation_module.addImport("pg", pgz.module("pg"));
    validation_module.addImport("httpz", httpz.module("httpz"));
    validation_module.addImport("dotenv", env.module("dotenv"));
    validation_module.addImport("zul", zul.module("zul"));
    validation_module.addImport("rediz", rediz.module("okredis"));
    validation_module.addImport("zdt", zdt.module("zdt"));
    validation_module.addImport("regexp", regexp.module("regex"));
    validation_module.addImport("mqttz", mqttz.module("mqttz"));
    validation_module.addImport("jwt", jwt.module("zig-jwt"));
    validation_module.addImport("sqlite", sqlite.module("sqlite"));
    validation_module.addImport("nats", nats.module("nats"));
    validation_module.addImport("zero", module);

    if (builtin.os.tag == .macos) {
        validation_module.addIncludePath(.{ .cwd_relative = "/usr/local/Cellar/librdkafka/2.13.0/include" });
        validation_module.addIncludePath(.{ .cwd_relative = "/usr/local/Cellar/librdkafka/2.13.0/lib" });
    }
    validation_module.linkSystemLibrary("rdkafka", .{
        .weak = true,
    });

    const validation_tests = b.addTest(.{
        .root_module = validation_module,
    });
    const run_validation = b.addRunArtifact(validation_tests);
    const validation_step = b.step("test-validation", "Validate Context memory management (HTTP/cron/pubsub)");
    validation_step.dependOn(&run_validation.step);

    // HTTP load/benchmark harness: starts the real zero App (framework-only,
    // no DB/Redis) and drives it with the in-repo zul.http.Client across a
    // concurrency ramp, reporting req/s + latency percentiles. Run the built
    // binary directly (./zig-out/bin/bench) — not via `zig build run` — to
    // avoid the --listen=- stdout protocol.
    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_module.addImport("pg", pgz.module("pg"));
    bench_module.addImport("httpz", httpz.module("httpz"));
    bench_module.addImport("dotenv", env.module("dotenv"));
    bench_module.addImport("zul", zul.module("zul"));
    bench_module.addImport("rediz", rediz.module("okredis"));
    bench_module.addImport("zdt", zdt.module("zdt"));
    bench_module.addImport("regexp", regexp.module("regex"));
    bench_module.addImport("mqttz", mqttz.module("mqttz"));
    bench_module.addImport("jwt", jwt.module("zig-jwt"));
    bench_module.addImport("sqlite", sqlite.module("sqlite"));
    bench_module.addImport("nats", nats.module("nats"));
    bench_module.addImport("zero", module);

    if (builtin.os.tag == .macos) {
        bench_module.addIncludePath(.{ .cwd_relative = "/usr/local/Cellar/librdkafka/2.13.0/include" });
        bench_module.addLibraryPath(.{ .cwd_relative = "/usr/local/Cellar/librdkafka/2.13.0/lib" });
    }
    bench_module.linkSystemLibrary("rdkafka", .{
        .weak = true,
    });

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_module,
    });
    const install_bench = b.addInstallArtifact(bench_exe, .{});
    const bench_step = b.step("bench", "Build the HTTP load/benchmark harness");
    bench_step.dependOn(&install_bench.step);

    const test_step = b.step("test", "Run tests");

    const coverage = b.option(bool, "coverage", "enable code coverage using kcov") orelse false;
    if (coverage) {
        const mkdir_kcov = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/kcov" });
        const run_kcov = b.addSystemCommand(&.{
            "kcov",
            "--clean",
            "--include-path=src/",
            "zig-out/kcov",
        });
        run_kcov.addArtifactArg(unit_tests);
        run_kcov.step.dependOn(&mkdir_kcov.step);

        test_step.dependOn(&unit_tests.step);
        test_step.dependOn(&run_kcov.step);
    } else {
        const run_exe_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_exe_tests.step);
    }

    const binary = b.addExecutable(.{
        .name = "zero",
        .root_module = module,
    });

    if (b.option(
        bool,
        "install-zero",
        "install zero cli",
    ) orelse false) {
        b.installArtifact(binary);
    }
}
