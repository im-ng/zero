const std = @import("std");
const testing = std.testing;
const zero = @import("zero");
const RegExp = zero.regexp.Regex;

test "test regexp" {
    var matchN = try RegExp.compile(testing.allocator, "(.*)/(\\d+)");
    defer testing.allocator.destroy(matchN);

    const n = &matchN;

    var splitMatches = try RegExp.captures(n, "*/2");
    if (splitMatches) |split| {
        std.log.info("{d}\n", .{split.len()});

        std.log.info("{s} ", .{split.sliceAt(0).?});
        std.log.info("{s} ", .{split.sliceAt(1).?});
        std.log.info("{s} ", .{split.sliceAt(2).?});
    }

    splitMatches = try RegExp.captures(n, "1-10/2");
    if (splitMatches) |split| {
        std.log.info("\n{d}\n", .{split.len()});

        std.log.info("{s} ", .{split.sliceAt(0).?});
        std.log.info("{s} ", .{split.sliceAt(1).?});
        std.log.info("{s} ", .{split.sliceAt(2).?});
    }

    var matchRange = try RegExp.compile(testing.allocator, "^(\\d+)-(\\d+)$");
    defer testing.allocator.destroy(matchRange);

    const r = &matchRange;

    const rangeMatches = try RegExp.captures(r, "30-40");
    if (rangeMatches) |ranges| {
        std.log.info("\n{d}\n", .{ranges.len()});

        std.log.info("{s} ", .{ranges.sliceAt(0).?});
        std.log.info("{s} ", .{ranges.sliceAt(1).?});
        std.log.info("{s} ", .{ranges.sliceAt(2).?});
    }
}
