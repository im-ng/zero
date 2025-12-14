const std = @import("std");

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

    const metriks = b.dependency("metriks", .{});
    module.addImport("metriks", metriks.module("metriks"));

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

    module.linkSystemLibrary("rdkafka", .{ .weak = true });

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/zero.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("zero", module);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_exe_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
