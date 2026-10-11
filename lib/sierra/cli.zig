//! Command-line interface for Sierra benchmark executables.
const std = @import("std");
const Io = std.Io;
const sampling = @import("sampling.zig");
const report = @import("report.zig");

pub const Args = struct {
    list: bool = false,
    help: bool = false,
    filter: ?[]const u8 = null,
    warmup_ns: ?u64 = null,
    measure_ns: ?u64 = null,
    samples: ?u32 = null,
    baseline: ?[]const u8 = null,
    save_baseline: ?[]const u8 = null,
    format: report.Format = .text,
    output: ?[]const u8 = null,
    track_allocations: bool = false,
    seed: ?u64 = null,
    /// Extra positional arguments (e.g. file paths for yaml-zig).
    positionals: []const []const u8 = &.{},
};

pub fn printHelp(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\Sierra benchmark runner
        \\
        \\Usage: <bench-exe> [options] [--] [positionals...]
        \\
        \\Options:
        \\  --list                 List benchmarks and exit
        \\  --filter <substr>      Run benchmarks whose names contain <substr>
        \\  --warmup <duration>    Warmup budget (e.g. 100ms, 1s)
        \\  --time <duration>      Measurement budget (e.g. 500ms, 2s)
        \\  --samples <n>          Maximum independent samples
        \\  --baseline <path>      Compare against a saved baseline JSON
        \\  --save-baseline <path> Write results JSON as a baseline
        \\  --format <text|json|csv>
        \\  --output <path>        Write report to a file (default: stdout)
        \\  --benchmem             Enable Zig allocator tracking where supported
        \\  --seed <n>             RNG seed for shuffled execution order
        \\  -h, --help             Show this help
        \\
    );
}

pub fn parse(gpa: std.mem.Allocator, arg_iter: anytype) !Args {
    _ = arg_iter.next(); // skip argv0
    var args: Args = .{};
    var positionals: std.ArrayList([]const u8) = .empty;
    errdefer positionals.deinit(gpa);

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--")) {
            while (arg_iter.next()) |p| try positionals.append(gpa, p);
            break;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            args.help = true;
        } else if (std.mem.eql(u8, arg, "--list")) {
            args.list = true;
        } else if (std.mem.eql(u8, arg, "--benchmem")) {
            args.track_allocations = true;
        } else if (std.mem.eql(u8, arg, "--filter") or std.mem.eql(u8, arg, "-f")) {
            args.filter = try needValue(arg_iter, arg);
        } else if (std.mem.startsWith(u8, arg, "--filter=")) {
            args.filter = arg["--filter=".len..];
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            args.warmup_ns = try parseDuration(try needValue(arg_iter, arg));
        } else if (std.mem.startsWith(u8, arg, "--warmup=")) {
            args.warmup_ns = try parseDuration(arg["--warmup=".len..]);
        } else if (std.mem.eql(u8, arg, "--time")) {
            args.measure_ns = try parseDuration(try needValue(arg_iter, arg));
        } else if (std.mem.startsWith(u8, arg, "--time=")) {
            args.measure_ns = try parseDuration(arg["--time=".len..]);
        } else if (std.mem.eql(u8, arg, "--samples")) {
            args.samples = try std.fmt.parseInt(u32, try needValue(arg_iter, arg), 10);
        } else if (std.mem.startsWith(u8, arg, "--samples=")) {
            args.samples = try std.fmt.parseInt(u32, arg["--samples=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--baseline")) {
            args.baseline = try needValue(arg_iter, arg);
        } else if (std.mem.startsWith(u8, arg, "--baseline=")) {
            args.baseline = arg["--baseline=".len..];
        } else if (std.mem.eql(u8, arg, "--save-baseline")) {
            args.save_baseline = try needValue(arg_iter, arg);
        } else if (std.mem.startsWith(u8, arg, "--save-baseline=")) {
            args.save_baseline = arg["--save-baseline=".len..];
        } else if (std.mem.eql(u8, arg, "--format")) {
            args.format = try parseFormat(try needValue(arg_iter, arg));
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            args.format = try parseFormat(arg["--format=".len..]);
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            args.output = try needValue(arg_iter, arg);
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            args.output = arg["--output=".len..];
        } else if (std.mem.eql(u8, arg, "--seed")) {
            args.seed = try std.fmt.parseInt(u64, try needValue(arg_iter, arg), 10);
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            args.seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("error: unknown option '{s}'\n", .{arg});
            return error.UnknownOption;
        } else {
            try positionals.append(gpa, arg);
        }
    }

    args.positionals = try positionals.toOwnedSlice(gpa);
    return args;
}

fn needValue(arg_iter: anytype, flag: []const u8) ![]const u8 {
    return arg_iter.next() orelse {
        std.debug.print("error: {s} requires a value\n", .{flag});
        return error.MissingOptionValue;
    };
}

pub fn parseDuration(s: []const u8) !u64 {
    if (s.len == 0) return error.InvalidDuration;
    if (std.mem.endsWith(u8, s, "ms")) {
        const n = try std.fmt.parseFloat(f64, s[0 .. s.len - 2]);
        return @intFromFloat(n * @as(f64, @floatFromInt(std.time.ns_per_ms)));
    }
    if (std.mem.endsWith(u8, s, "us")) {
        const n = try std.fmt.parseFloat(f64, s[0 .. s.len - 2]);
        return @intFromFloat(n * @as(f64, @floatFromInt(std.time.ns_per_us)));
    }
    if (std.mem.endsWith(u8, s, "ns")) {
        return try std.fmt.parseInt(u64, s[0 .. s.len - 2], 10);
    }
    if (std.mem.endsWith(u8, s, "s")) {
        const n = try std.fmt.parseFloat(f64, s[0 .. s.len - 1]);
        return @intFromFloat(n * @as(f64, @floatFromInt(std.time.ns_per_s)));
    }
    // Bare integer: milliseconds
    const n = try std.fmt.parseFloat(f64, s);
    return @intFromFloat(n * @as(f64, @floatFromInt(std.time.ns_per_ms)));
}

fn parseFormat(s: []const u8) !report.Format {
    if (std.mem.eql(u8, s, "text")) return .text;
    if (std.mem.eql(u8, s, "json")) return .json;
    if (std.mem.eql(u8, s, "csv")) return .csv;
    std.debug.print("error: unknown format '{s}' (expected text|json|csv)\n", .{s});
    return error.InvalidFormat;
}

pub fn applyConfig(args: Args, base: sampling.Config) sampling.Config {
    var cfg = base;
    if (args.warmup_ns) |w| cfg.warmup_ns = w;
    if (args.measure_ns) |t| cfg.measure_ns = t;
    if (args.samples) |n| {
        cfg.max_samples = n;
        cfg.min_samples = @min(cfg.min_samples, n);
    }
    return cfg;
}

test "parseDuration" {
    try std.testing.expectEqual(@as(u64, 100 * std.time.ns_per_ms), try parseDuration("100ms"));
    try std.testing.expectEqual(@as(u64, 2 * std.time.ns_per_s), try parseDuration("2s"));
    try std.testing.expectEqual(@as(u64, 50 * std.time.ns_per_ms), try parseDuration("50"));
}
