const root = @import("../../zero.zig");
const Self = @This();
const Config = @This();

port: u16 = undefined,
qos: u16 = undefined,
keepAliveDuaration: u16 = undefined,
connectionTimeout: u32 = undefined,
ip: []const u8 = undefined,
hostname: []const u8 = undefined,
username: []const u8 = undefined,
password: []const u8 = undefined,
clientID: []const u8 = undefined,
retainOnRetrieval: bool = undefined,
