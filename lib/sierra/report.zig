//! Terminal, markdown, JSON, and CSV reporters.
const std = @import("std");
const Io = std.Io;
const bench_mod = @import("bench.zig");
const comparison = @import("comparison.zig");
const memory = @import("memory.zig");

pub const Format = enum { text, json, csv };

pub fn formatDuration(ns: f64, buf: []u8) []const u8 {
    if (ns >= std.time.ns_per_s) {
        return std.fmt.bufPrint(buf, "{d:.2} s", .{ns / std.time.ns_per_s}) catch "?";
    }
    if (ns >= std.time.ns_per_ms) {
        return std.fmt.bufPrint(buf, "{d:.2} ms", .{ns / std.time.ns_per_ms}) catch "?";
    }
    if (ns >= std.time.ns_per_us) {
        return std.fmt.bufPrint(buf, "{d:.1} us", .{ns / std.time.ns_per_us}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d:.0} ns", .{ns}) catch "?";
}

pub fn formatSize(bytes: u64, buf: []u8) []const u8 {
    const kib = @as(f64, @floatFromInt(bytes)) / 1024.0;
    if (kib < 1024.0) {
        return std.fmt.bufPrint(buf, "{d:.1} KiB", .{kib}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d:.2} MiB", .{kib / 1024.0}) catch "?";
}

pub fn formatThroughput(bytes_per_s: f64, buf: []u8) []const u8 {
    const mib = bytes_per_s / (1024.0 * 1024.0);
    return std.fmt.bufPrint(buf, "{d:.1} MiB/s", .{mib}) catch "?";
}

pub const DisplayRow = struct {
    workload: []const u8,
    backend: []const u8,
    result: bench_mod.Result,
};

/// Derive backend + workload for table display.
pub fn splitDisplay(result: bench_mod.Result, workload_buf: []u8) struct { backend: []const u8, workload: []const u8 } {
    if (result.group) |g| {
        const workload = result.label orelse deriveWorkload(result.name, workload_buf);
        return .{ .backend = g, .workload = workload };
    }
    if (std.mem.startsWith(u8, result.name, "yaml_")) {
        return .{
            .backend = "yaml",
            .workload = result.label orelse underscoreToHyphen(result.name["yaml_".len..], workload_buf),
        };
    }
    if (std.mem.startsWith(u8, result.name, "fy_")) {
        return .{
            .backend = "fy",
            .workload = result.label orelse underscoreToHyphen(result.name["fy_".len..], workload_buf),
        };
    }
    return .{
        .backend = result.group orelse "-",
        .workload = result.label orelse result.name,
    };
}

fn deriveWorkload(name: []const u8, buf: []u8) []const u8 {
    if (std.mem.startsWith(u8, name, "yaml_")) return underscoreToHyphen(name["yaml_".len..], buf);
    if (std.mem.startsWith(u8, name, "fy_")) return underscoreToHyphen(name["fy_".len..], buf);
    return name;
}

fn underscoreToHyphen(src: []const u8, buf: []u8) []const u8 {
    const n = @min(src.len, buf.len);
    for (src[0..n], 0..) |c, i| {
        buf[i] = if (c == '_') '-' else c;
    }
    return buf[0..n];
}

fn allocsPerOp(result: bench_mod.Result) ?u64 {
    if (result.allocation.availability != .available) return null;
    const measure_iters = @max(result.sample_count * @as(usize, @intCast(result.batch_size)), 1);
    return result.allocation.metrics.alloc_calls / measure_iters;
}

fn bytesPerOp(result: bench_mod.Result) ?u64 {
    if (result.allocation.availability != .available) return null;
    const measure_iters = @max(result.sample_count * @as(usize, @intCast(result.batch_size)), 1);
    return result.allocation.metrics.bytes_requested / measure_iters;
}

fn backendRank(backend: []const u8) u8 {
    if (std.mem.eql(u8, backend, "yaml")) return 0;
    if (std.mem.eql(u8, backend, "fy")) return 1;
    return 2;
}

fn lessDisplay(ctx: void, a: DisplayRow, b: DisplayRow) bool {
    _ = ctx;
    const cmp = std.mem.order(u8, a.workload, b.workload);
    if (cmp != .eq) return cmp == .lt;
    const ra = backendRank(a.backend);
    const rb = backendRank(b.backend);
    if (ra != rb) return ra < rb;
    return std.mem.order(u8, a.backend, b.backend) == .lt;
}

pub fn buildDisplayRows(gpa: std.mem.Allocator, results: []const bench_mod.Result) ![]DisplayRow {
    var rows: std.ArrayList(DisplayRow) = .empty;
    errdefer rows.deinit(gpa);
    try rows.ensureTotalCapacity(gpa, results.len);

    // Temporary buffers for derived workload names — store owned copies.
    for (results) |r| {
        var tmp: [256]u8 = undefined;
        const parts = splitDisplay(r, &tmp);
        const workload = try gpa.dupe(u8, parts.workload);
        const backend = try gpa.dupe(u8, parts.backend);
        try rows.append(gpa, .{
            .workload = workload,
            .backend = backend,
            .result = r,
        });
    }
    std.sort.pdq(DisplayRow, rows.items, {}, lessDisplay);
    return try rows.toOwnedSlice(gpa);
}

pub fn freeDisplayRows(gpa: std.mem.Allocator, rows: []DisplayRow) void {
    for (rows) |row| {
        gpa.free(row.workload);
        gpa.free(row.backend);
    }
    gpa.free(rows);
}

pub fn writeComparisonHeader(
    writer: *Io.Writer,
    meta: comparison.Meta,
    seed: ?u64,
) !void {
    try writer.print("Parse benchmark (`{s}`)\n", .{meta.optimize});
    try writer.print("sierra {s}  zig {s}  {s}/{s}", .{
        meta.sierra_version,
        meta.zig_version,
        meta.os,
        meta.arch,
    });
    if (seed) |s| try writer.print("  seed={d}", .{s});
    try writer.writeAll("\n\n");
    try writer.writeAll(
        \\Workload                  Size       Backend   Median       p95        Throughput    Allocs/op    Bytes/op
        \\------------------------- ---------- --------- ------------ ---------- ------------- ------------ ----------
        \\
    );
}

pub fn writeComparisonRow(writer: *Io.Writer, row: DisplayRow) !void {
    var size_buf: [32]u8 = undefined;
    var med_buf: [32]u8 = undefined;
    var p95_buf: [32]u8 = undefined;
    var thr_buf: [32]u8 = undefined;

    const size = if (row.result.bytes_per_iter) |b|
        formatSize(b, &size_buf)
    else
        "-";
    const med = formatDuration(row.result.summary.median, &med_buf);
    const p95 = formatDuration(row.result.summary.p95, &p95_buf);
    const thr = if (row.result.throughput_per_s) |t|
        formatThroughput(t, &thr_buf)
    else blk: {
        break :blk std.fmt.bufPrint(&thr_buf, "{d:.0} ops/s", .{row.result.opsPerSec()}) catch "?";
    };

    const allocs = allocsPerOp(row.result);
    const bytes = bytesPerOp(row.result);

    try writer.print("{s:<25} {s:>10} {s:<9} {s:>10} {s:>10} {s:>11} ", .{
        row.workload,
        size,
        row.backend,
        med,
        p95,
        thr,
    });
    if (allocs) |a| {
        try writer.print("{d:>10} ", .{a});
    } else {
        try writer.writeAll("       n/a ");
    }
    if (bytes) |b| {
        try writer.print("{d:>10}\n", .{b});
    } else {
        try writer.writeAll("       n/a\n");
    }
}

pub fn writeVsFooter(writer: *Io.Writer, rows: []const DisplayRow) !void {
    // Pair yaml vs fy by workload label.
    var i: usize = 0;
    var wrote_any = false;
    while (i < rows.len) {
        const w = rows[i].workload;
        var yaml_med: ?f64 = null;
        var fy_med: ?f64 = null;
        while (i < rows.len and std.mem.eql(u8, rows[i].workload, w)) : (i += 1) {
            if (std.mem.eql(u8, rows[i].backend, "yaml")) yaml_med = rows[i].result.summary.median;
            if (std.mem.eql(u8, rows[i].backend, "fy")) fy_med = rows[i].result.summary.median;
        }
        if (yaml_med == null or fy_med == null) continue;
        if (!wrote_any) {
            try writer.writeAll("\nvs fy (median): ");
            wrote_any = true;
        } else {
            try writer.writeAll(" | ");
        }
        const ratio = yaml_med.? / fy_med.?;
        if (ratio < 1.0) {
            const faster = (1.0 - ratio) * 100.0;
            try writer.print("{s} yaml {d:.0}% faster", .{ w, faster });
        } else if (ratio > 1.0) {
            const slower = (ratio - 1.0) * 100.0;
            try writer.print("{s} yaml {d:.0}% slower", .{ w, slower });
        } else {
            try writer.print("{s} tied", .{w});
        }
    }
    if (wrote_any) try writer.writeAll("\n");
}

pub fn writeVerboseResult(writer: *Io.Writer, result: bench_mod.Result) !void {
    var med_buf: [32]u8 = undefined;
    var mad_buf: [32]u8 = undefined;
    try writer.print("  {s}: estimator=median mean={s} mad={s} batch={d} samples={d} iters={d}\n", .{
        result.name,
        formatDuration(result.summary.mean, &med_buf),
        formatDuration(result.summary.mad, &mad_buf),
        result.batch_size,
        result.sample_count,
        result.iterations,
    });
    if (result.summary.sample_count >= 2) {
        try writer.print("    mean 95% CI [{s}, {s}]\n", .{
            formatDuration(result.summary.ci_low, &med_buf),
            formatDuration(result.summary.ci_high, &mad_buf),
        });
    }
}

// Legacy single-result helpers kept for CSV/JSON paths.
pub fn writeCsvHeader(writer: *Io.Writer) !void {
    try writer.writeAll("name,workload,backend,median_ns,mean_ns,stddev_ns,mad_ns,min_ns,max_ns,p95_ns,samples,batch,iterations,throughput_per_s\n");
}

pub fn writeCsvResult(writer: *Io.Writer, result: bench_mod.Result) !void {
    var tmp: [256]u8 = undefined;
    const parts = splitDisplay(result, &tmp);
    try writer.print("{s},{s},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n", .{
        result.name,
        parts.workload,
        parts.backend,
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

pub fn writeJsonResults(
    gpa: std.mem.Allocator,
    writer: *Io.Writer,
    meta: comparison.Meta,
    results: []const bench_mod.Result,
) !void {
    _ = gpa;
    try writer.writeAll("{\n  \"meta\": {\n");
    try writer.print("    \"sierra_version\": \"{s}\",\n", .{meta.sierra_version});
    try writer.print("    \"zig_version\": \"{s}\",\n", .{meta.zig_version});
    try writer.print("    \"optimize\": \"{s}\",\n", .{meta.optimize});
    try writer.print("    \"os\": \"{s}\",\n", .{meta.os});
    try writer.print("    \"arch\": \"{s}\"\n", .{meta.arch});
    try writer.writeAll("  },\n  \"results\": [\n");
    for (results, 0..) |r, i| {
        var tmp: [256]u8 = undefined;
        const parts = splitDisplay(r, &tmp);
        try writer.writeAll("    {\n");
        try writer.print("      \"name\": \"{s}\",\n", .{r.name});
        try writer.print("      \"workload\": \"{s}\",\n", .{parts.workload});
        try writer.print("      \"backend\": \"{s}\",\n", .{parts.backend});
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

pub fn appendGithubStepSummary(
    io: Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    meta: comparison.Meta,
    rows: []const DisplayRow,
) !void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try appendMarkdownTable(gpa, &list, meta, rows);
    try appendVsFooterMarkdown(gpa, &list, rows);

    const file = Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try Io.Dir.createFileAbsolute(io, path, .{}),
        else => return err,
    };
    defer file.close(io);
    const end = try file.length(io);
    try file.writePositionalAll(io, list.items, end);
}

fn appendMarkdownTable(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(u8),
    meta: comparison.Meta,
    rows: []const DisplayRow,
) !void {
    try list.print(gpa, "## Parse benchmark (`{s}`)\n\n", .{meta.optimize});
    try list.appendSlice(gpa,
        \\| Workload | Size | Backend | Median | p95 | Throughput | Allocs/op | Bytes/op |
        \\| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: |
        \\
    );
    for (rows) |row| {
        var size_buf: [32]u8 = undefined;
        var med_buf: [32]u8 = undefined;
        var p95_buf: [32]u8 = undefined;
        var thr_buf: [32]u8 = undefined;
        const size = if (row.result.bytes_per_iter) |b| formatSize(b, &size_buf) else "-";
        const med = formatDuration(row.result.summary.median, &med_buf);
        const p95 = formatDuration(row.result.summary.p95, &p95_buf);
        const thr = if (row.result.throughput_per_s) |t|
            formatThroughput(t, &thr_buf)
        else
            std.fmt.bufPrint(&thr_buf, "{d:.0} ops/s", .{row.result.opsPerSec()}) catch "?";
        const allocs = allocsPerOp(row.result);
        const bytes = bytesPerOp(row.result);
        try list.print(gpa, "| `{s}` | {s} | `{s}` | {s} | {s} | {s} | ", .{
            row.workload,
            size,
            row.backend,
            med,
            p95,
            thr,
        });
        if (allocs) |a| try list.print(gpa, "{d}", .{a}) else try list.appendSlice(gpa, "n/a");
        try list.appendSlice(gpa, " | ");
        if (bytes) |b| try list.print(gpa, "{d}", .{b}) else try list.appendSlice(gpa, "n/a");
        try list.appendSlice(gpa, " |\n");
    }
    try list.appendSlice(gpa, "\n");
}

fn appendVsFooterMarkdown(gpa: std.mem.Allocator, list: *std.ArrayList(u8), rows: []const DisplayRow) !void {
    var i: usize = 0;
    var first = true;
    while (i < rows.len) {
        const w = rows[i].workload;
        var yaml_med: ?f64 = null;
        var fy_med: ?f64 = null;
        while (i < rows.len and std.mem.eql(u8, rows[i].workload, w)) : (i += 1) {
            if (std.mem.eql(u8, rows[i].backend, "yaml")) yaml_med = rows[i].result.summary.median;
            if (std.mem.eql(u8, rows[i].backend, "fy")) fy_med = rows[i].result.summary.median;
        }
        if (yaml_med == null or fy_med == null) continue;
        if (first) {
            try list.appendSlice(gpa, "**vs fy (median):** ");
            first = false;
        } else try list.appendSlice(gpa, " · ");
        const ratio = yaml_med.? / fy_med.?;
        if (ratio < 1.0) {
            try list.print(gpa, "`{s}` yaml **{d:.0}% faster**", .{ w, (1.0 - ratio) * 100.0 });
        } else if (ratio > 1.0) {
            try list.print(gpa, "`{s}` yaml **{d:.0}% slower**", .{ w, (ratio - 1.0) * 100.0 });
        } else {
            try list.print(gpa, "`{s}` tied", .{w});
        }
    }
    if (!first) try list.appendSlice(gpa, "\n");
}
