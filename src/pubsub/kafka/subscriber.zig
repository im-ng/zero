const root = @import("../../zero.zig");
const Self = @This();
const KafkaSubscriber = @This();
const rdkafka = root.rdkafka;

name: []const u8,
topic: []const u8,
packetIdentifier: u16 = 0,
topics: ?*rdkafka.struct_rd_kafka_topic_partition_list_s = undefined,
exec: *const fn (*root.Context) anyerror!void = undefined,
