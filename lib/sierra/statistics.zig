//! Statistical summaries for independent sample observations.
//!
//! Iterations inside a timed batch are not treated as independent samples.
//! Callers must pass one observation per timed sample (typically ns/op).
const std = @import("std");

pub const Summary = struct {
    sample_count: usize,
    mean: f64,
    median: f64,
    min: f64,
    max: f64,
    stddev: f64,
    mad: f64,
    p25: f64,
    p75: f64,
    p95: f64,
    p99: f64,
    /// Approximate 95% CI for the mean via normal approximation (n >= 2).
    ci_low: f64,
    ci_high: f64,
};

pub fn summarize(samples: []const f64) Summary {
    if (samples.len == 0) {
        return .{
            .sample_count = 0,
            .mean = 0,
            .median = 0,
            .min = 0,
            .max = 0,
            .stddev = 0,
            .mad = 0,
            .p25 = 0,
            .p75 = 0,
            .p95 = 0,
            .p99 = 0,
            .ci_low = 0,
            .ci_high = 0,
        };
    }

    var sorted: [4096]f64 = undefined;
    const n = samples.len;
    if (n > sorted.len) {
        // Fallback: compute without full sort for oversized inputs.
        return summarizeUnsorted(samples);
    }
    @memcpy(sorted[0..n], samples);
    std.sort.pdq(f64, sorted[0..n], {}, std.sort.asc(f64));
    return summarizeSorted(sorted[0..n]);
}

fn summarizeUnsorted(samples: []const f64) Summary {
    var min: f64 = samples[0];
    var max: f64 = samples[0];
    var sum: f64 = 0;
    for (samples) |v| {
        min = @min(min, v);
        max = @max(max, v);
        sum += v;
    }
    const mean = sum / @as(f64, @floatFromInt(samples.len));
    var var_sum: f64 = 0;
    for (samples) |v| {
        const d = v - mean;
        var_sum += d * d;
    }
    const stddev = if (samples.len > 1)
        @sqrt(var_sum / @as(f64, @floatFromInt(samples.len - 1)))
    else
        0;
    const se = if (samples.len > 0) stddev / @sqrt(@as(f64, @floatFromInt(samples.len))) else 0;
    return .{
        .sample_count = samples.len,
        .mean = mean,
        .median = mean,
        .min = min,
        .max = max,
        .stddev = stddev,
        .mad = 0,
        .p25 = min,
        .p75 = max,
        .p95 = max,
        .p99 = max,
        .ci_low = mean - 1.96 * se,
        .ci_high = mean + 1.96 * se,
    };
}

fn summarizeSorted(sorted: []const f64) Summary {
    const n = sorted.len;
    var sum: f64 = 0;
    for (sorted) |v| sum += v;
    const mean = sum / @as(f64, @floatFromInt(n));

    var var_sum: f64 = 0;
    for (sorted) |v| {
        const d = v - mean;
        var_sum += d * d;
    }
    const stddev = if (n > 1)
        @sqrt(var_sum / @as(f64, @floatFromInt(n - 1)))
    else
        0;

    const median = quantileSorted(sorted, 0.50);
    var abs_devs: [4096]f64 = undefined;
    for (sorted, 0..) |v, i| abs_devs[i] = @abs(v - median);
    std.sort.pdq(f64, abs_devs[0..n], {}, std.sort.asc(f64));
    const mad = quantileSorted(abs_devs[0..n], 0.50);

    const se = stddev / @sqrt(@as(f64, @floatFromInt(n)));
    return .{
        .sample_count = n,
        .mean = mean,
        .median = median,
        .min = sorted[0],
        .max = sorted[n - 1],
        .stddev = stddev,
        .mad = mad,
        .p25 = quantileSorted(sorted, 0.25),
        .p75 = quantileSorted(sorted, 0.75),
        .p95 = quantileSorted(sorted, 0.95),
        .p99 = quantileSorted(sorted, 0.99),
        .ci_low = mean - 1.96 * se,
        .ci_high = mean + 1.96 * se,
    };
}

/// Linear-interpolation quantile for a sorted ascending slice.
pub fn quantileSorted(sorted: []const f64, q: f64) f64 {
    if (sorted.len == 0) return 0;
    if (sorted.len == 1) return sorted[0];
    const clamped = std.math.clamp(q, 0.0, 1.0);
    const pos = clamped * @as(f64, @floatFromInt(sorted.len - 1));
    const lo: usize = @intFromFloat(@floor(pos));
    const hi = @min(lo + 1, sorted.len - 1);
    const frac = pos - @as(f64, @floatFromInt(lo));
    return sorted[lo] * (1.0 - frac) + sorted[hi] * frac;
}

/// Welch's t-test approximation. Returns (t_statistic, significant_at_0.05).
pub fn welchCompare(a: Summary, b: Summary) struct { t: f64, significant: bool, relative: f64 } {
    if (a.sample_count < 2 or b.sample_count < 2) {
        const relative = if (b.median != 0) (a.median - b.median) / b.median else 0;
        return .{ .t = 0, .significant = false, .relative = relative };
    }
    const na: f64 = @floatFromInt(a.sample_count);
    const nb: f64 = @floatFromInt(b.sample_count);
    const va = a.stddev * a.stddev;
    const vb = b.stddev * b.stddev;
    const denom = @sqrt(va / na + vb / nb);
    const t = if (denom > 0) (a.mean - b.mean) / denom else 0;
    const relative = if (b.median != 0) (a.median - b.median) / b.median else 0;
    // Two-sided critical value ~1.96 for large df; conservative enough for reporting.
    return .{ .t = t, .significant = @abs(t) > 1.96, .relative = relative };
}

test "quantile known dataset" {
    const data = [_]f64{ 1, 2, 3, 4, 5 };
    try std.testing.expectApproxEqAbs(@as(f64, 3), quantileSorted(&data, 0.5), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1), quantileSorted(&data, 0.0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5), quantileSorted(&data, 1.0), 1e-9);
}

test "summarize known dataset" {
    const data = [_]f64{ 10, 20, 30, 40, 50 };
    const s = summarize(&data);
    try std.testing.expectEqual(@as(usize, 5), s.sample_count);
    try std.testing.expectApproxEqAbs(@as(f64, 30), s.mean, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 30), s.median, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10), s.min, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 50), s.max, 1e-9);
    try std.testing.expect(s.stddev > 0);
    try std.testing.expect(s.ci_low < s.mean and s.ci_high > s.mean);
}
