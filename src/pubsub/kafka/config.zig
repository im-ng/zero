const root = @import("../../zero.zig");
const Self = @This();
const Config = @This();

defaulBatchSize: u32 = 100,
defaultBatchBytes: u32 = 1048576,
defaultBatchTimeout: u32 = 1000,
defaultMaxBytes: u32 = 10000000,
defaultMinBytes: u32 = 10000,
defaultRetryTimeout: u8 = 10,
defaultReadTimeout: u8 = 30,
protocolPlainText: []const u8 = "PLAINTEXT",
protocolSASL: []const u8 = "SASL_PLAINTEXT",
protocolSSL: []const u8 = "SSL",
protocolSASLSSL: []const u8 = "SASL_SSL",
messageMultipleBrokers: []const u8 = "MULTIPLE_BROKERS",
brokerStartup: []const u8 = "UP",
