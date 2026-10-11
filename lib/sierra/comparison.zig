//! Baseline save/load and relative performance comparison.
const std = @import("std");
const Io = std.Io;
const statistics = @import("statistics.zig");
const memory = @import("memory.zig");

pub const Meta = struct {
    sierra_version: []const u8 = "0.1.0",
    zig_version: []const u8 = "",
    optimize: []const u8 = "",
    os: []const u8 = "",
    arch: []const u8 = "",
    git_commit: ?[]const u8 = null,
};

pub const StoredResult = struct {
    name: []const u8,
    median_ns: f64,
    mean_ns: f64,
    stddev_ns: f64,
    mad_ns: f64,
    min_ns: f64,
    max_ns: f64,
    sample_count: usize,
    iterations: u64,
    batch_size: u64,
    throughput_per_s: ?f64 = null,
    bytes_per_iter: ?u64 = null,
    alloc_calls: ?u64 = null,
    bytes_requested: ?u64 = null,
    bytes_peak: ?u64 = null,
};

pub const BaselineFile = struct {
    meta: Meta,
    results: []StoredResult,
};

pub const CompareOutcome = struct {
    name: []const u8,
    current_median_ns: f64,
    baseline_median_ns: f64,
    relative_change: f64,
    significant: bool,
};

pub fn relativeChange(current: f64, baseline: f64) f64 {
    if (baseline == 0) return 0;
    return (current - baseline) / baseline;
}

pub fn compareMedians(current: statistics.Summary, baseline_median: f64) CompareOutcome {
    // Without baseline sample variance, significance is unavailable.
    return .{
        .name = "",
        .current_median_ns = current.median,
        .baseline_median_ns = baseline_median,
        .relative_change = relativeChange(current.median, baseline_median),
        .significant = false,
    };
}

pub fn writeJson(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    meta: Meta,
    results: []const StoredResult,
) !void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    try list.appendSlice(gpa, "{\n  \"meta\": {\n");
    try appendJsonString(gpa, &list, "    \"sierra_version\": ", meta.sierra_version);
    try list.appendSlice(gpa, ",\n");
    try appendJsonString(gpa, &list, "    \"zig_version\": ", meta.zig_version);
    try list.appendSlice(gpa, ",\n");
    try appendJsonString(gpa, &list, "    \"optimize\": ", meta.optimize);
    try list.appendSlice(gpa, ",\n");
    try appendJsonString(gpa, &list, "    \"os\": ", meta.os);
    try list.appendSlice(gpa, ",\n");
    try appendJsonString(gpa, &list, "    \"arch\": ", meta.arch);
    if (meta.git_commit) |commit| {
        try list.appendSlice(gpa, ",\n");
        try appendJsonString(gpa, &list, "    \"git_commit\": ", commit);
    }
    try list.appendSlice(gpa, "\n  },\n  \"results\": [\n");

    for (results, 0..) |r, i| {
        try list.appendSlice(gpa, "    {\n");
        try appendJsonString(gpa, &list, "      \"name\": ", r.name);
        try list.appendSlice(gpa, ",\n");
        try list.print(gpa, "      \"median_ns\": {d},\n", .{r.median_ns});
        try list.print(gpa, "      \"mean_ns\": {d},\n", .{r.mean_ns});
        try list.print(gpa, "      \"stddev_ns\": {d},\n", .{r.stddev_ns});
        try list.print(gpa, "      \"mad_ns\": {d},\n", .{r.mad_ns});
        try list.print(gpa, "      \"min_ns\": {d},\n", .{r.min_ns});
        try list.print(gpa, "      \"max_ns\": {d},\n", .{r.max_ns});
        try list.print(gpa, "      \"sample_count\": {d},\n", .{r.sample_count});
        try list.print(gpa, "      \"iterations\": {d},\n", .{r.iterations});
        try list.print(gpa, "      \"batch_size\": {d}", .{r.batch_size});
        if (r.throughput_per_s) |t| try list.print(gpa, ",\n      \"throughput_per_s\": {d}", .{t});
        if (r.bytes_per_iter) |b| try list.print(gpa, ",\n      \"bytes_per_iter\": {d}", .{b});
        if (r.alloc_calls) |a| try list.print(gpa, ",\n      \"alloc_calls\": {d}", .{a});
        if (r.bytes_requested) |b| try list.print(gpa, ",\n      \"bytes_requested\": {d}", .{b});
        if (r.bytes_peak) |p| try list.print(gpa, ",\n      \"bytes_peak\": {d}", .{p});
        try list.appendSlice(gpa, "\n    }");
        if (i + 1 < results.len) try list.appendSlice(gpa, ",");
        try list.appendSlice(gpa, "\n");
    }
    try list.appendSlice(gpa, "  ]\n}\n");

    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = list.items,
    });
}

fn appendJsonString(gpa: std.mem.Allocator, list: *std.ArrayList(u8), prefix: []const u8, value: []const u8) !void {
    try list.appendSlice(gpa, prefix);
    try list.append(gpa, '"');
    for (value) |c| {
        switch (c) {
            '\\' => try list.appendSlice(gpa, "\\\\"),
            '"' => try list.appendSlice(gpa, "\\\""),
            '\n' => try list.appendSlice(gpa, "\\n"),
            '\r' => try list.appendSlice(gpa, "\\r"),
            '\t' => try list.appendSlice(gpa, "\\t"),
            else => try list.append(gpa, c),
        }
    }
    try list.append(gpa, '"');
}

pub fn loadBaseline(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
) !struct { meta: Meta, results: []StoredResult, raw: []u8 } {
    const raw = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
    errdefer gpa.free(raw);

    // Minimal JSON extraction for Sierra baseline files we write ourselves.
    var results: std.ArrayList(StoredResult) = .empty;
    errdefer {
        for (results.items) |r| gpa.free(r.name);
        results.deinit(gpa);
    }

    var meta: Meta = .{};
    if (extractString(raw, "sierra_version")) |v| meta.sierra_version = v;
    if (extractString(raw, "zig_version")) |v| meta.zig_version = v;
    if (extractString(raw, "optimize")) |v| meta.optimize = v;
    if (extractString(raw, "os")) |v| meta.os = v;
    if (extractString(raw, "arch")) |v| meta.arch = v;

    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, raw, search_from, "\"name\"")) |name_key| {
        const name = extractStringFrom(raw, name_key) orelse break;
        const name_owned = try gpa.dupe(u8, name);
        const median = extractNumberAfter(raw, name_key, "median_ns") orelse 0;
        const mean = extractNumberAfter(raw, name_key, "mean_ns") orelse median;
        const stddev = extractNumberAfter(raw, name_key, "stddev_ns") orelse 0;
        const mad = extractNumberAfter(raw, name_key, "mad_ns") orelse 0;
        const min_ns = extractNumberAfter(raw, name_key, "min_ns") orelse 0;
        const max_ns = extractNumberAfter(raw, name_key, "max_ns") orelse 0;
        const sample_count: usize = @intFromFloat(extractNumberAfter(raw, name_key, "sample_count") orelse 0);
        const iterations: u64 = @intFromFloat(extractNumberAfter(raw, name_key, "iterations") orelse 0);
        const batch_size: u64 = @intFromFloat(extractNumberAfter(raw, name_key, "batch_size") orelse 1);
        try results.append(gpa, .{
            .name = name_owned,
            .median_ns = median,
            .mean_ns = mean,
            .stddev_ns = stddev,
            .mad_ns = mad,
            .min_ns = min_ns,
            .max_ns = max_ns,
            .sample_count = sample_count,
            .iterations = iterations,
            .batch_size = batch_size,
        });
        search_from = name_key + 6;
    }

    return .{
        .meta = meta,
        .results = try results.toOwnedSlice(gpa),
        .raw = raw,
    };
}

fn extractString(raw: []const u8, key: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, raw, needle) orelse return null;
    return extractStringFrom(raw, idx);
}

fn extractStringFrom(raw: []const u8, key_idx: usize) ?[]const u8 {
    const colon = std.mem.indexOfPos(u8, raw, key_idx, ":") orelse return null;
    const first_quote = std.mem.indexOfPos(u8, raw, colon + 1, "\"") orelse return null;
    const second_quote = std.mem.indexOfPos(u8, raw, first_quote + 1, "\"") orelse return null;
    return raw[first_quote + 1 .. second_quote];
}

fn extractNumberAfter(raw: []const u8, from: usize, key: []const u8) ?f64 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\"", .{key}) catch return null;
    const idx = std.mem.indexOfPos(u8, raw, from, needle) orelse return null;
    const colon = std.mem.indexOfPos(u8, raw, idx, ":") orelse return null;
    var i = colon + 1;
    while (i < raw.len and (raw[i] == ' ' or raw[i] == '\n' or raw[i] == '\r' or raw[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < raw.len and ((raw[i] >= '0' and raw[i] <= '9') or raw[i] == '.' or raw[i] == '-' or raw[i] == '+' or raw[i] == 'e' or raw[i] == 'E')) : (i += 1) {}
    if (start == i) return null;
    return std.fmt.parseFloat(f64, raw[start..i]) catch null;
}

pub fn findResult(results: []const StoredResult, name: []const u8) ?StoredResult {
    for (results) |r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

pub fn warnIncompatible(meta: Meta, current: Meta, writer: *Io.Writer) !void {
    if (!std.mem.eql(u8, meta.optimize, current.optimize) and meta.optimize.len > 0 and current.optimize.len > 0) {
        try writer.print("warning: baseline optimize={s} differs from current={s}\n", .{ meta.optimize, current.optimize });
    }
    if (!std.mem.eql(u8, meta.os, current.os) and meta.os.len > 0 and current.os.len > 0) {
        try writer.print("warning: baseline os={s} differs from current={s}\n", .{ meta.os, current.os });
    }
    _ = memory;
}
