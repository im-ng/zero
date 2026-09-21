const std = @import("std");
const zero = @import("zero.zig");
const generator = @import("migration/generator.zig");

pub fn run(args: std.process.Args) !void {
    var it = std.process.Args.Iterator.init(args);

    // Skip argv[0] (program name).
    _ = it.next();

    const cmd = it.next() orelse {
        printHelp();
        return;
    };

    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printHelp();
        return;
    }

    if (std.mem.eql(u8, cmd, "migrator")) {
        const sub = it.next() orelse {
            printHelp();
            return;
        };
        if (!std.mem.eql(u8, sub, "add")) {
            printHelp();
            return;
        }

        var name: ?[]const u8 = null;
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--name")) {
                name = it.next() orelse {
                    std.debug.print("error: --name requires a value\n", .{});
                    return error.MissingNameValue;
                };
            } else if (std.mem.startsWith(u8, arg, "--name=")) {
                name = arg["--name=".len..];
            } else {
                std.debug.print("error: unknown flag '{s}'\n", .{arg});
                return error.UnknownFlag;
            }
        }

        if (name == null) {
            std.debug.print("error: migrator add requires --name <name>\n", .{});
            return error.MissingName;
        }

        generator.add(std.heap.page_allocator, name.?) catch |err| switch (err) {
            error.MigrationAlreadyExists => return,
            else => return err,
        };
        return;
    }

    std.debug.print("error: unknown command '{s}'\n", .{cmd});
    printHelp();
}

fn printHelp() void {
    const out = std.Io.File.stdout();
    out.writeStreamingAll(zero.utils.io,
        \\zero - the zero framework CLI
        \\
        \\Usage:
        \\  zero --help
        \\  zero migrator add --name <name>
        \\
        \\Commands:
        \\  migrator add --name <name>   Scaffold a new migration in src/migrations/
        \\
    ) catch {};
}
