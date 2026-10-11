const std = @import("std");
const sierra = @import("sierra");

test "mad of symmetric data" {
    const data = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const s = sierra.statistics.summarize(&data);
    try std.testing.expectApproxEqAbs(@as(f64, 5), s.median, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2), s.mad, 1e-9);
}

test "welch detects large separation" {
    const a = sierra.statistics.summarize(&[_]f64{ 100, 101, 99, 100, 102 });
    const b = sierra.statistics.summarize(&[_]f64{ 10, 11, 9, 10, 12 });
    const cmp = sierra.statistics.welchCompare(a, b);
    try std.testing.expect(cmp.significant);
    try std.testing.expect(cmp.relative > 5);
}

test "empty summary" {
    const s = sierra.statistics.summarize(&.{});
    try std.testing.expectEqual(@as(usize, 0), s.sample_count);
}
