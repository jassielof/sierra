const std = @import("std");
const sierra = @import("sierra");

test "counting allocator tracks alloc free peak" {
    var counting = sierra.CountingAllocator.init(std.testing.allocator);
    const a = counting.allocator();

    const p1 = try a.alloc(u8, 100);
    const p2 = try a.alloc(u8, 50);
    try std.testing.expectEqual(@as(u64, 2), counting.metrics.alloc_calls);
    try std.testing.expectEqual(@as(u64, 150), counting.metrics.bytes_outstanding);
    try std.testing.expectEqual(@as(u64, 150), counting.metrics.bytes_peak);

    a.free(p1);
    try std.testing.expectEqual(@as(u64, 50), counting.metrics.bytes_outstanding);
    try std.testing.expectEqual(@as(u64, 150), counting.metrics.bytes_peak);
    a.free(p2);
    try std.testing.expectEqual(@as(u64, 0), counting.metrics.bytes_outstanding);
    try std.testing.expectEqual(@as(u64, 2), counting.metrics.free_calls);
}

test "unavailable distinct from zero" {
    const zero = sierra.memory.Snapshot.fromMetrics(.{});
    const missing = sierra.memory.Snapshot.unavailable();
    try std.testing.expect(zero.availability == .available);
    try std.testing.expect(missing.availability == .unavailable);
    try std.testing.expectEqual(@as(u64, 0), zero.metrics.alloc_calls);
}
