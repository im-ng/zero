const std = @import("std");

pub const natsConfig = struct {
    url: []const u8 = undefined,
    stream: []const u8 = undefined,
    subjects: []const u8 = undefined,
    max_wait_ms: u32 = undefined,
    max_pull_wait_ms: u32 = undefined,
    consumer: []const u8 = undefined,
    creds_file: []const u8 = undefined,

    pub fn hasStream(self: *const natsConfig) bool {
        return self.stream.len > 0;
    }
};
