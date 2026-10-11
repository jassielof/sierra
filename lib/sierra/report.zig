//! Terminal and JSON reporters.
const std = @import("std");
const Io = std.Io;
const bench_mod = @import("bench.zig");
const comparison = @import("comparison.zig");
const memory = @import("memory.zig");

pub const Format = enum { text, json, csv };

pub fn formatDuration(ns: f64, buf: []u8) []const u8 {
    if (ns >= std.time.ns_per_s) {
        return std.fmt.bufPrint(buf, "{d:.2}s", .{ns / std.time.ns_per_s}) catch "?";
    }
    if (ns >= std.time.ns_per_ms) {
        return std.fmt.bufPrint(buf, "{d:.2}ms", .{ns / std.time.ns_per_ms}) catch "?";
    }
    if (ns >= std.time.ns_per_us) {
        return std.fmt.bufPrint(buf, "{d:.1}us", .{ns / std.time.ns_per_us}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d:.0}ns", .{ns}) catch "?";
}

pub fn formatThroughput(bytes_per_s: f64, buf: []u8) []const u8 {
    const mib = bytes_per_s / (1024.0 * 1024.0);
    return std.fmt.bufPrint(buf, "{d:.1} MiB/s", .{mib}) catch "?";
}

pub fn writeTextHeader(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\benchmark                         median         ±σ/mad        samples   thrpt/allocs
        \\------------------------------- ------------ -------------- --------- ----------------
        \\
    );
}

pub fn writeTextResult(
    writer: *Io.Writer,
    result: bench_mod.Result,
    baseline: ?comparison.StoredResult,
) !void {
    var med_buf: [32]u8 = undefined;
    var mad_buf: [32]u8 = undefined;
    const med = formatDuration(result.summary.median, &med_buf);
    const mad = formatDuration(result.summary.mad, &mad_buf);

    try writer.print("{s:<31} {s:>10}  ±{s:<10} {d:>7}  ", .{
        result.name,
        med,
        mad,
        result.sample_count,
    });

    if (result.throughput_per_s) |t| {
        var tbuf: [32]u8 = undefined;
        try writer.print("{s}", .{formatThroughput(t, &tbuf)});
    } else {
        try writer.print("{d:.0} ops/s", .{result.opsPerSec()});
    }

    switch (result.allocation.availability) {
        .available => {
            const measure_iters = @max(result.sample_count * @as(usize, @intCast(result.batch_size)), 1);
            const allocs_per_op = result.allocation.metrics.alloc_calls / measure_iters;
            const bytes_per_op = result.allocation.metrics.bytes_requested / measure_iters;
            try writer.print("  allocs/op={d} B/op={d} peak={d}B", .{
                allocs_per_op,
                bytes_per_op,
                result.allocation.metrics.bytes_peak,
            });
        },
        .unavailable => {},
    }

    if (baseline) |b| {
        const rel = comparison.relativeChange(result.summary.median, b.median_ns);
        try writer.print("  {s}{d:.1}% vs baseline", .{
            if (rel >= 0) "+" else "",
            rel * 100.0,
        });
    }

    try writer.writeAll("\n");
    try writer.print("  estimator=median  mean={s}  p95={s}  batch={d}  iters={d}\n", .{
        formatDuration(result.summary.mean, &med_buf),
        formatDuration(result.summary.p95, &mad_buf),
        result.batch_size,
        result.iterations,
    });
    if (result.summary.sample_count >= 2) {
        try writer.print("  mean 95% CI [{s}, {s}]\n", .{
            formatDuration(result.summary.ci_low, &med_buf),
            formatDuration(result.summary.ci_high, &mad_buf),
        });
    }
}

pub fn writeJsonResults(
    gpa: std.mem.Allocator,
    writer: *Io.Writer,
    meta: comparison.Meta,
    results: []const bench_mod.Result,
) !void {
    var stored: std.ArrayList(comparison.StoredResult) = .empty;
    defer stored.deinit(gpa);
    for (results) |r| {
        try stored.append(gpa, toStored(r));
    }

    // Reuse comparison JSON writer via a temporary buffer.
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    // Inline JSON for streaming writer.
    try writer.writeAll("{\n  \"meta\": {\n");
    try writer.print("    \"sierra_version\": \"{s}\",\n", .{meta.sierra_version});
    try writer.print("    \"zig_version\": \"{s}\",\n", .{meta.zig_version});
    try writer.print("    \"optimize\": \"{s}\",\n", .{meta.optimize});
    try writer.print("    \"os\": \"{s}\",\n", .{meta.os});
    try writer.print("    \"arch\": \"{s}\"\n", .{meta.arch});
    try writer.writeAll("  },\n  \"results\": [\n");
    for (results, 0..) |r, i| {
        try writer.writeAll("    {\n");
        try writer.print("      \"name\": \"{s}\",\n", .{r.name});
        try writer.print("      \"estimator\": \"{s}\",\n", .{r.estimator});
        try writer.print("      \"median_ns\": {d},\n", .{r.summary.median});
        try writer.print("      \"mean_ns\": {d},\n", .{r.summary.mean});
        try writer.print("      \"stddev_ns\": {d},\n", .{r.summary.stddev});
        try writer.print("      \"mad_ns\": {d},\n", .{r.summary.mad});
        try writer.print("      \"min_ns\": {d},\n", .{r.summary.min});
        try writer.print("      \"max_ns\": {d},\n", .{r.summary.max});
        try writer.print("      \"p95_ns\": {d},\n", .{r.summary.p95});
        try writer.print("      \"ci_low_ns\": {d},\n", .{r.summary.ci_low});
        try writer.print("      \"ci_high_ns\": {d},\n", .{r.summary.ci_high});
        try writer.print("      \"sample_count\": {d},\n", .{r.sample_count});
        try writer.print("      \"iterations\": {d},\n", .{r.iterations});
        try writer.print("      \"batch_size\": {d}", .{r.batch_size});
        if (r.throughput_per_s) |t| try writer.print(",\n      \"throughput_per_s\": {d}", .{t});
        if (r.bytes_per_iter) |b| try writer.print(",\n      \"bytes_per_iter\": {d}", .{b});
        switch (r.allocation.availability) {
            .available => {
                try writer.print(",\n      \"alloc_calls\": {d}", .{r.allocation.metrics.alloc_calls});
                try writer.print(",\n      \"bytes_requested\": {d}", .{r.allocation.metrics.bytes_requested});
                try writer.print(",\n      \"bytes_peak\": {d}", .{r.allocation.metrics.bytes_peak});
            },
            .unavailable => {
                try writer.writeAll(",\n      \"allocation\": \"unavailable\"");
            },
        }
        try writer.writeAll("\n    }");
        if (i + 1 < results.len) try writer.writeAll(",");
        try writer.writeAll("\n");
    }
    try writer.writeAll("  ]\n}\n");
    _ = memory;
}

pub fn writeCsvHeader(writer: *Io.Writer) !void {
    try writer.writeAll("name,median_ns,mean_ns,stddev_ns,mad_ns,min_ns,max_ns,p95_ns,samples,batch,iterations,throughput_per_s\n");
}

pub fn writeCsvResult(writer: *Io.Writer, result: bench_mod.Result) !void {
    try writer.print("{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n", .{
        result.name,
        result.summary.median,
        result.summary.mean,
        result.summary.stddev,
        result.summary.mad,
        result.summary.min,
        result.summary.max,
        result.summary.p95,
        result.sample_count,
        result.batch_size,
        result.iterations,
        result.throughput_per_s orelse 0,
    });
}

pub fn toStored(result: bench_mod.Result) comparison.StoredResult {
    return .{
        .name = result.name,
        .median_ns = result.summary.median,
        .mean_ns = result.summary.mean,
        .stddev_ns = result.summary.stddev,
        .mad_ns = result.summary.mad,
        .min_ns = result.summary.min,
        .max_ns = result.summary.max,
        .sample_count = result.sample_count,
        .iterations = result.iterations,
        .batch_size = result.batch_size,
        .throughput_per_s = result.throughput_per_s,
        .bytes_per_iter = result.bytes_per_iter,
        .alloc_calls = switch (result.allocation.availability) {
            .available => result.allocation.metrics.alloc_calls,
            .unavailable => null,
        },
        .bytes_requested = switch (result.allocation.availability) {
            .available => result.allocation.metrics.bytes_requested,
            .unavailable => null,
        },
        .bytes_peak = switch (result.allocation.availability) {
            .available => result.allocation.metrics.bytes_peak,
            .unavailable => null,
        },
    };
}
