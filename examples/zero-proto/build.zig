const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zero = b.dependency("zero", .{});
    // `protobuf` is both needed at build time for the codegen step below and at
    // compile time for the generated structs. The `zero` framework no longer
    // imports protobuf into its main module, so this is the only protobuf module
    // instance in the build — no collision.
    const protobuf = b.dependency("protobuf", .{});
    const protobuf_mod = @import("protobuf");

    const exe = b.addExecutable(.{
        .name = "proto",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("zero", zero.module("zero"));
    exe.root_module.addImport("protobuf", protobuf.module("protobuf"));

    // Generate Zig structs from the .proto definitions under `proto/`. Run
    // `zig build gen-proto` whenever the .proto changes. The first run downloads
    // Google's protoc (cached in the zig global cache); pass a local binary via
    // `.protoc = b.path("protoc")` to build fully offline.
    const gen_proto = b.step("gen-proto", "Generate Zig structs from .proto definitions");
    const protoc_step = protobuf_mod.RunProtocStep.create(protobuf.builder, target, .{
        .destination_directory = b.path("src/proto"),
        .source_files = &.{
            b.path("proto/crud.proto"),
        },
        .include_directories = &.{
            b.path("."),
        },
    });
    gen_proto.dependOn(&protoc_step.step);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("proto", "Run the protobuf-over-http example server");
    run_step.dependOn(&run_cmd.step);
}
