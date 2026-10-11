//! Benchmark execution orchestration.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const bench_mod = @import("bench.zig");
const registry = @import("registry.zig");
const report = @import("report.zig");
const comparison = @import("comparison.zig");
const cli = @import("cli.zig");

pub const version = "0.1.0";

pub fn runModule(comptime root: type, init: std.process.Init) !u8 {
    const specs = comptime registry.collectBenchmarks(root);
    return runSpecs(root, &specs, init);
}

pub fn runSpecs(comptime root: type, specs: []const registry.Spec, init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arg_iter = try init.minimal.args.iterateAllocator(gpa);
    defer arg_iter.deinit();
    const args = cli.parse(gpa, &arg_iter) catch |err| {
        std.debug.print("Sierra: failed to parse arguments: {s}\n", .{@errorName(err)});
        return 2;
    };
    defer gpa.free(args.positionals);

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    if (args.help) {
        try cli.printHelp(stdout);
        try stdout.flush();
        return 0;
    }

    if (args.list) {
        for (specs) |spec| {
            try stdout.print("{s}\n", .{spec.name});
        }
        try stdout.flush();
        return 0;
    }

    var selected: std.ArrayList(registry.Spec) = .empty;
    defer selected.deinit(gpa);
    for (specs) |spec| {
        if (args.filter) |f| {
            if (std.mem.indexOf(u8, spec.name, f) == null) continue;
        }
        try selected.append(gpa, spec);
    }
    if (selected.items.len == 0) {
        try stdout.writeAll("No benchmarks selected.\n");
        try stdout.flush();
        return 1;
    }

    if (args.seed) |seed| {
        shuffleSpecs(selected.items, seed);
    }

    const config = cli.applyConfig(args, .{});
    const meta = currentMeta();

    var baseline_results: []comparison.StoredResult = &.{};
    var baseline_raw: ?[]u8 = null;
    defer if (baseline_raw) |raw| gpa.free(raw);
    defer {
        for (baseline_results) |r| gpa.free(r.name);
        gpa.free(baseline_results);
    }

    if (args.baseline) |path| {
        const loaded = comparison.loadBaseline(gpa, io, path) catch |err| {
            std.debug.print("Sierra: failed to load baseline '{s}': {s}\n", .{ path, @errorName(err) });
            return 2;
        };
        baseline_results = loaded.results;
        baseline_raw = loaded.raw;
        try comparison.warnIncompatible(loaded.meta, meta, stdout);
    }

    var results: std.ArrayList(bench_mod.Result) = .empty;
    defer {
        for (results.items) |*r| {
            if (r.samples_ns.len > 0) gpa.free(r.samples_ns);
        }
        results.deinit(gpa);
    }

    if (@hasDecl(root, "sierraPrepare")) {
        try root.sierraPrepare(init, args.positionals);
    }

    for (selected.items) |spec| {
        try stderr.print("running {s}...\n", .{spec.name});
        try stderr.flush();

        var options = spec.options;
        if (args.track_allocations) options.track_allocations = true;

        var b = bench_mod.Bench.init(io, gpa, spec.name, config, options);
        if (options.track_allocations) {
            b.allocator = b.counting.allocator();
        }
        defer b.deinit();

        try spec.func(&b);

        const result = b.finish() catch |err| switch (err) {
            error.BenchmarkSkipped => {
                try stderr.print("  skipped {s}\n", .{spec.name});
                try stderr.flush();
                continue;
            },
            else => {
                std.debug.print("benchmark '{s}' finish failed: {s}\n", .{ spec.name, @errorName(err) });
                return 1;
            },
        };
        try results.append(gpa, result);
    }

    const rows = try report.buildDisplayRows(gpa, results.items);
    defer report.freeDisplayRows(gpa, rows);

    switch (args.format) {
        .text => {
            try report.writeComparisonHeader(stdout, meta, args.seed);
            for (rows) |row| try report.writeComparisonRow(stdout, row);
            try report.writeVsFooter(stdout, rows);
            if (args.verbose) {
                try stdout.writeAll("\n");
                for (results.items) |r| {
                    try report.writeVerboseResult(stdout, r);
                    if (comparison.findResult(baseline_results, r.name)) |base| {
                        const rel = comparison.relativeChange(r.summary.median, base.median_ns);
                        try stdout.print("    vs baseline {s}{d:.1}%\n", .{
                            if (rel >= 0) "+" else "",
                            rel * 100.0,
                        });
                    }
                }
            }
            try stdout.flush();
        },
        .csv => {
            try report.writeCsvHeader(stdout);
            for (results.items) |r| try report.writeCsvResult(stdout, r);
            try stdout.flush();
        },
        .json => {
            try report.writeJsonResults(gpa, stdout, meta, results.items);
            try stdout.flush();
        },
    }

    if (init.environ_map.get("GITHUB_STEP_SUMMARY")) |summary_path| {
        try report.appendGithubStepSummary(io, gpa, summary_path, meta, rows);
    }

    if (args.save_baseline) |path| {
        var stored: std.ArrayList(comparison.StoredResult) = .empty;
        defer stored.deinit(gpa);
        for (results.items) |r| try stored.append(gpa, report.toStored(r));
        try comparison.writeJson(gpa, io, path, meta, stored.items);
        try stdout.print("saved baseline: {s}\n", .{path});
        try stdout.flush();
    }

    if (args.output) |path| {
        if (args.format == .json) {
            var stored: std.ArrayList(comparison.StoredResult) = .empty;
            defer stored.deinit(gpa);
            for (results.items) |r| try stored.append(gpa, report.toStored(r));
            try comparison.writeJson(gpa, io, path, meta, stored.items);
        }
    }

    if (@hasDecl(root, "sierraFinish")) {
        try root.sierraFinish(init, results.items);
    }

    return 0;
}

fn shuffleSpecs(specs: []registry.Spec, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var i: usize = specs.len;
    while (i > 1) {
        i -= 1;
        const j = random.uintLessThan(usize, i + 1);
        const tmp = specs[i];
        specs[i] = specs[j];
        specs[j] = tmp;
    }
}

fn currentMeta() comparison.Meta {
    return .{
        .sierra_version = version,
        .zig_version = builtin.zig_version_string,
        .optimize = switch (builtin.mode) {
            .Debug => "Debug",
            .ReleaseSafe => "ReleaseSafe",
            .ReleaseFast => "ReleaseFast",
            .ReleaseSmall => "ReleaseSmall",
        },
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
    };
}
