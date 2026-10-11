//! Sierra — statistically reliable benchmarking for Zig.
//!
//! Sierra is a component of the `scz` package (Santa Cruz de la Sierra).
//! Import with `@import("sierra")`.
//!
//! ## Quick start
//!
//! ```zig
//! const sierra = @import("sierra");
//!
//! pub fn benchAdd(b: *sierra.Bench) !void {
//!     while (try b.next()) {
//!         sierra.keepAlive(1 + 1);
//!     }
//! }
//!
//! pub const benchmarks = .{
//!     .add = benchAdd,
//! };
//! ```
//!
//! Build with `sierra.addBenchmarkExecutable` from scz's `build.zig`.
const std = @import("std");

pub const clock = @import("clock.zig");
pub const sampling = @import("sampling.zig");
pub const statistics = @import("statistics.zig");
pub const memory = @import("memory.zig");
pub const comparison = @import("comparison.zig");
pub const report = @import("report.zig");
pub const cli = @import("cli.zig");
pub const registry = @import("registry.zig");
pub const runner = @import("runner.zig");
pub const bench = @import("bench.zig");

pub const Bench = bench.Bench;
pub const Result = bench.Result;
pub const Options = bench.Options;
pub const Config = bench.Config;
pub const keepAlive = bench.keepAlive;
pub const blackBox = bench.blackBox;

pub const CountingAllocator = memory.CountingAllocator;
pub const Suite = registry.Suite;
pub const Spec = registry.Spec;
pub const version = runner.version;

pub const runModule = runner.runModule;
pub const collectBenchmarks = registry.collectBenchmarks;

test {
    std.testing.refAllDecls(@This());
}
