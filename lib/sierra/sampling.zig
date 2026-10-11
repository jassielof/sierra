//! Warmup and adaptive batch calibration.
const std = @import("std");

pub const Config = struct {
    /// Warmup time budget in nanoseconds.
    warmup_ns: u64 = 100 * std.time.ns_per_ms,
    /// Measurement time budget in nanoseconds.
    measure_ns: u64 = 500 * std.time.ns_per_ms,
    /// Minimum number of independent timed samples.
    min_samples: u32 = 10,
    /// Maximum number of independent timed samples.
    max_samples: u32 = 100,
    /// Minimum iterations per timed sample (batch size floor).
    min_batch: u64 = 1,
    /// Maximum iterations per timed sample.
    max_batch: u64 = 1_000_000,
    /// Target nanoseconds per timed sample during measurement.
    target_sample_ns: u64 = 10 * std.time.ns_per_ms,
};

pub const Calibration = struct {
    batch_size: u64,
    estimated_ns_per_op: f64,
};

/// Choose a batch size from a measured cost of `iters` iterations taking `elapsed_ns`.
pub fn calibrateBatch(elapsed_ns: u64, iters: u64, config: Config) Calibration {
    const safe_elapsed: f64 = @floatFromInt(@max(elapsed_ns, 1));
    const safe_iters: f64 = @floatFromInt(@max(iters, 1));
    const ns_per_op = safe_elapsed / safe_iters;

    var batch: u64 = 1;
    if (ns_per_op > 0) {
        const target: f64 = @floatFromInt(config.target_sample_ns);
        const computed = target / ns_per_op;
        if (computed > 1) batch = @intFromFloat(@floor(computed));
    }
    batch = @max(batch, config.min_batch);
    batch = @min(batch, config.max_batch);
    return .{
        .batch_size = batch,
        .estimated_ns_per_op = ns_per_op,
    };
}

/// How many independent samples fit in the measurement budget.
pub fn sampleCount(config: Config, batch_size: u64, ns_per_op: f64) u32 {
    if (ns_per_op <= 0) return config.min_samples;
    const sample_cost = ns_per_op * @as(f64, @floatFromInt(@max(batch_size, 1)));
    const budget: f64 = @floatFromInt(config.measure_ns);
    var count: u32 = @intFromFloat(@floor(budget / @max(sample_cost, 1)));
    count = @max(count, config.min_samples);
    count = @min(count, config.max_samples);
    return count;
}

test "calibrate batches fast ops" {
    // 10ns/op should produce a large batch targeting ~10ms.
    const cal = calibrateBatch(10_000, 1000, .{});
    try std.testing.expect(cal.batch_size > 100);
    try std.testing.expectApproxEqAbs(@as(f64, 10), cal.estimated_ns_per_op, 1e-6);
}

test "calibrate keeps slow ops at batch 1" {
    const cal = calibrateBatch(50 * std.time.ns_per_ms, 1, .{});
    try std.testing.expectEqual(@as(u64, 1), cal.batch_size);
}
