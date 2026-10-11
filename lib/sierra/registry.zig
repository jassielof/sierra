//! Compile-time benchmark discovery and validation.
const std = @import("std");
const bench_mod = @import("bench.zig");

pub const BenchFn = *const fn (*bench_mod.Bench) anyerror!void;

pub const Spec = struct {
    name: []const u8,
    func: BenchFn,
    options: bench_mod.Options = .{},
};

fn isBenchName(comptime name: []const u8) bool {
    return std.mem.startsWith(u8, name, "bench") or std.mem.startsWith(u8, name, "Bench");
}

fn isBenchFunction(comptime value: anytype) bool {
    const info = @typeInfo(@TypeOf(value));
    const fn_info = switch (info) {
        .@"fn" => |fn_info| fn_info,
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => |fn_info| fn_info,
            else => return false,
        },
        else => return false,
    };
    if (fn_info.param_types.len != 1) return false;
    if (fn_info.param_types[0] != *bench_mod.Bench) return false;
    const return_type = fn_info.return_type orelse return false;
    return @typeInfo(return_type) == .error_union and
        @typeInfo(return_type).error_union.payload == void;
}

fn validateBenchFunction(comptime name: []const u8, comptime value: anytype) void {
    if (!isBenchFunction(value)) {
        @compileError(std.fmt.comptimePrint(
            "Sierra: '{s}' is not a valid benchmark. Expected `fn (*sierra.Bench) anyerror!void`.",
            .{name},
        ));
    }
}

fn normalizedName(comptime name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "bench") and name.len > 5) {
        return name[5..];
    }
    if (std.mem.startsWith(u8, name, "Bench") and name.len > 5) {
        return name[5..];
    }
    return name;
}

fn countFromBenchmarksDecl(comptime root: type) comptime_int {
    if (!@hasDecl(root, "benchmarks")) return 0;
    const b = root.benchmarks;
    return switch (@typeInfo(@TypeOf(b))) {
        .@"struct" => |info| info.field_names.len,
        else => @compileError("Sierra: `benchmarks` must be a struct/tuple of benchmark functions"),
    };
}

fn countFromNamedDecls(comptime root: type) comptime_int {
    if (@hasDecl(root, "benchmarks")) return 0;
    var count: comptime_int = 0;
    for (@typeInfo(root).@"struct".decl_names) |decl_name| {
        if (isBenchName(decl_name) and isBenchFunction(@field(root, decl_name))) {
            count += 1;
        } else if (isBenchName(decl_name)) {
            validateBenchFunction(decl_name, @field(root, decl_name));
        }
    }
    return count;
}

pub fn countBenchmarks(comptime root: type) comptime_int {
    const from_decl = countFromBenchmarksDecl(root);
    if (from_decl > 0) return from_decl;
    return countFromNamedDecls(root);
}

pub fn collectBenchmarks(comptime root: type) [countBenchmarks(root)]Spec {
    @setEvalBranchQuota(100_000);
    var out: [countBenchmarks(root)]Spec = undefined;
    var i: usize = 0;

    if (@hasDecl(root, "benchmarks")) {
        const b = root.benchmarks;
        const names = @typeInfo(@TypeOf(b)).@"struct".field_names;
        inline for (names) |field_name| {
            const func = @field(b, field_name);
            validateBenchFunction(field_name, func);
            out[i] = .{
                .name = field_name,
                .func = func,
            };
            i += 1;
        }
        return out;
    }

    inline for (@typeInfo(root).@"struct".decl_names) |decl_name| {
        if (comptime isBenchName(decl_name)) {
            const func = @field(root, decl_name);
            validateBenchFunction(decl_name, func);
            out[i] = .{
                .name = normalizedName(decl_name),
                .func = func,
            };
            i += 1;
        }
    }
    return out;
}

/// Explicit registration helper for manual suites.
pub const Suite = struct {
    specs: std.ArrayList(Spec),
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Suite {
        return .{ .specs = .empty, .gpa = gpa };
    }

    pub fn deinit(self: *Suite) void {
        self.specs.deinit(self.gpa);
    }

    pub fn add(self: *Suite, name: []const u8, func: BenchFn, options: bench_mod.Options) !void {
        try self.specs.append(self.gpa, .{
            .name = name,
            .func = func,
            .options = options,
        });
    }
};
