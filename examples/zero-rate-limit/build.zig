const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const kafka = b.option(bool, "kafka", "Enable Kafka/RDKafka pub-sub support (default on)") orelse true;
    const duckdb = b.option(bool, "duckdb", "Enable DuckDB in-process OLAP support (default on)") orelse true;

    const zero = b.dependency("zero", .{ .kafka = kafka, .duckdb = duckdb });

    const exe = b.addExecutable(.{
        .name = "zero-rate-limit",
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

    const run_step = b.step("run", "Run zero rate limiting example");
    run_step.dependOn(&run_cmd.step);
}
