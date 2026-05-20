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
    module.linkSystemLibrary("rdkafka", .{ .weak = true });

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("pg", pgz.module("pg"));
    test_module.addImport("httpz", httpz.module("httpz"));
    test_module.addImport("metriks", metriks.module("metriks"));
    test_module.addImport("dotenv", env.module("dotenv"));
    test_module.addImport("zul", zul.module("zul"));
    test_module.addImport("rediz", rediz.module("okredis"));
    test_module.addImport("zdt", zdt.module("zdt"));
    test_module.addImport("regexp", regexp.module("regex"));
    test_module.addImport("mqttz", mqttz.module("mqttz"));
    test_module.addImport("jwt", jwt.module("zig-jwt"));
    test_module.addImport("zero", module);

    if (builtin.os.tag == .macos) {
        test_module.addIncludePath(.{ .cwd_relative = "/usr/local/Cellar/librdkafka/2.13.0/include" });
        test_module.addLibraryPath(.{ .cwd_relative = "/usr/local/Cellar/librdkafka/2.13.0/lib" });
    }
    test_module.linkSystemLibrary("rdkafka", .{ .weak = true });

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_exe_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    const binary = b.addExecutable(.{
        .name = "zero",
        .root_module = module,
    });

    if (b.option(bool, "install-zero", "install zero cli") orelse false) {
        b.installArtifact(binary);
    }

    // `zig build test-bin` installs test binary for coverage tools (kcov)
    const test_bin_step = b.step("test-bin", "Build test binary for coverage");
    const install_test = b.addInstallArtifact(unit_tests, .{ .dest_sub_path = "test" });
    test_bin_step.dependOn(&install_test.step);

    // coverage references
    // https://github.com/dot96gal/zcli/pull/2/files
    const coverage = b.option(bool, "coverage", "Generate test coverage report") orelse false;
    if (coverage) {
        const test_bin = b.addInstallArtifact(unit_tests, .{});
        const kcov_cmd = b.addSystemCommand(&.{
            "kcov",
            "--clean",
            "--include-pattern=src/",
            "kcov-output",
        });
        kcov_cmd.addArtifactArg(unit_tests);
        kcov_cmd.step.dependOn(&test_bin.step);
        test_step.dependOn(&kcov_cmd.step);
    } else {
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
}
