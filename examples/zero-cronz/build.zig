const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const kafka = b.option(bool, "kafka", "Enable Kafka/RDKafka pub-sub support (default on)") orelse true;
    const duckdb = b.option(bool, "duckdb", "Enable DuckDB in-process OLAP support (default on)") orelse true;

    const zero = b.dependency("zero", .{ .kafka = kafka, .duckdb = duckdb });

    const exe = b.addExecutable(.{
        .name = "cronz",
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
    run_cmd.addPassthruArgs();

    const run_step = b.step("cronz", "Run zero cronz...");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/t.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("test", zero.module("zero"));

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    unit_tests.root_module.addImport("zero", zero.module("zero"));

    const run_exe_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
