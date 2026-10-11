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

    if (args.format == .text) {
        try stdout.print("Sierra {s}  zig {s}  optimize={s}  {s}/{s}\n", .{
            meta.sierra_version,
            meta.zig_version,
            meta.optimize,
            meta.os,
            meta.arch,
        });
        try report.writeTextHeader(stdout);
    } else if (args.format == .csv) {
        try report.writeCsvHeader(stdout);
    }

    for (selected.items) |spec| {
        var options = spec.options;
        if (args.track_allocations) options.track_allocations = true;

        var b = bench_mod.Bench.init(io, gpa, spec.name, config, options);
        if (options.track_allocations) {
            b.allocator = b.counting.allocator();
        }
        defer b.deinit();

        // The benchmark function owns the iteration loop via `while (try b.next())`.
        try spec.func(&b);

        const result = b.finish() catch |err| switch (err) {
            error.BenchmarkSkipped => {
                if (args.format == .text) {
                    try stdout.print("{s:<31} skipped\n", .{spec.name});
                    try stdout.flush();
                }
                continue;
            },
            else => {
                std.debug.print("benchmark '{s}' finish failed: {s}\n", .{ spec.name, @errorName(err) });
                return 1;
            },
        };
        try results.append(gpa, result);

        const baseline = comparison.findResult(baseline_results, result.name);
        switch (args.format) {
            .text => try report.writeTextResult(stdout, result, baseline),
            .csv => try report.writeCsvResult(stdout, result),
            .json => {},
        }
        try stdout.flush();
    }

    if (args.format == .json) {
        try report.writeJsonResults(gpa, stdout, meta, results.items);
        try stdout.flush();
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
        .optimize = @tagName(builtin.mode),
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
    };
}
