//! Benchmark context: iteration control, calibration, and optimization barriers.
const std = @import("std");
const Io = std.Io;
const clock_mod = @import("clock.zig");
const sampling = @import("sampling.zig");
const statistics = @import("statistics.zig");
const memory = @import("memory.zig");

pub const Config = sampling.Config;

pub const Options = struct {
    /// Bytes processed per iteration for throughput (e.g. input size).
    bytes_per_iter: ?u64 = null,
    /// Items processed per iteration for item throughput.
    items_per_iter: ?u64 = null,
    /// Track Zig allocator metrics (uses `b.allocator`).
    track_allocations: bool = false,
    /// Group / backend name for reporting (e.g. "yaml", "fy").
    group: ?[]const u8 = null,
    /// Human workload label for comparison tables (e.g. "synthetic-tiny", "bundle.yaml").
    label: ?[]const u8 = null,
};

pub const Result = struct {
    name: []const u8,
    group: ?[]const u8 = null,
    label: ?[]const u8 = null,
    summary: statistics.Summary,
    /// Primary estimator used in reports.
    estimator: []const u8 = "median",
    iterations: u64,
    batch_size: u64,
    sample_count: usize,
    throughput_per_s: ?f64 = null,
    bytes_per_iter: ?u64 = null,
    allocation: memory.Snapshot = .unavailable(),
    /// Per-sample ns/op observations (owned by runner allocator).
    samples_ns: []f64 = &.{},

    pub fn medianNs(self: Result) f64 {
        return self.summary.median;
    }

    pub fn opsPerSec(self: Result) f64 {
        if (self.summary.median <= 0) return 0;
        return 1e9 / self.summary.median;
    }
};

/// Opaque keep-alive / black-box helpers.
pub inline fn keepAlive(value: anytype) void {
    std.mem.doNotOptimizeAway(value);
}

pub inline fn blackBox(value: anytype) @TypeOf(value) {
    var runtime_value = value;
    std.mem.doNotOptimizeAway(&runtime_value);
    return runtime_value;
}

const Phase = enum { calibrate_warmup, calibrate_measure, measure };

/// Per-benchmark execution context.
pub const Bench = struct {
    io: Io,
    gpa: std.mem.Allocator,
    name: []const u8,
    config: Config,
    options: Options,

    counting: memory.CountingAllocator,
    allocator: std.mem.Allocator,

    phase: Phase = .calibrate_warmup,
    clock: clock_mod.Clock,
    batch_size: u64 = 1,
    remaining_in_batch: u64 = 0,
    samples_remaining: u32 = 0,
    total_iterations: u64 = 0,

    calibrate_elapsed_ns: u64 = 0,
    calibrate_iters: u64 = 0,
    warmup_elapsed_ns: u64 = 0,

    sample_ns: std.ArrayList(f64) = .empty,
    current_sample_started: bool = false,
    timer_paused: bool = false,
    paused_ns: u64 = 0,

    allocation_snapshot: memory.Snapshot = .unavailable(),
    failed: bool = false,
    skip: bool = false,

    pub fn init(
        io: Io,
        gpa: std.mem.Allocator,
        name: []const u8,
        config: Config,
        options: Options,
    ) Bench {
        var self: Bench = .{
            .io = io,
            .gpa = gpa,
            .name = name,
            .config = config,
            .options = options,
            .counting = .init(gpa),
            .allocator = gpa,
            .clock = .start(io),
        };
        if (options.track_allocations) {
            self.allocator = self.counting.allocator();
        }
        return self;
    }

    /// Enable allocator tracking after init (e.g. from inside a benchmark).
    pub fn enableAllocationTracking(self: *Bench) void {
        self.options.track_allocations = true;
        self.counting.reset();
        self.allocator = self.counting.allocator();
    }

    pub fn deinit(self: *Bench) void {
        self.sample_ns.deinit(self.gpa);
        self.* = undefined;
    }

    /// Drive the measured loop. Returns true while more iterations are needed.
    pub fn next(self: *Bench) !bool {
        if (self.failed or self.skip) return false;

        switch (self.phase) {
            .calibrate_warmup => {
                if (!self.current_sample_started) {
                    self.clock.reset();
                    self.current_sample_started = true;
                    self.remaining_in_batch = 1;
                }
                if (self.remaining_in_batch > 0) {
                    self.remaining_in_batch -= 1;
                    self.total_iterations += 1;
                    self.calibrate_iters += 1;
                    return true;
                }
                const elapsed = self.clock.readNsAtLeastOne();
                self.warmup_elapsed_ns += elapsed;
                self.calibrate_elapsed_ns += elapsed;
                self.current_sample_started = false;

                if (self.warmup_elapsed_ns < self.config.warmup_ns and self.calibrate_iters < self.config.max_batch) {
                    // Double batch for next warmup probe.
                    self.batch_size = @min(self.batch_size * 2, self.config.max_batch);
                    self.remaining_in_batch = self.batch_size;
                    self.clock.reset();
                    self.current_sample_started = true;
                    self.remaining_in_batch -= 1;
                    self.total_iterations += 1;
                    self.calibrate_iters += 1;
                    return true;
                }

                const cal = sampling.calibrateBatch(self.calibrate_elapsed_ns, self.calibrate_iters, self.config);
                self.batch_size = cal.batch_size;
                self.samples_remaining = sampling.sampleCount(self.config, self.batch_size, cal.estimated_ns_per_op);
                try self.sample_ns.ensureTotalCapacity(self.gpa, self.samples_remaining);
                self.phase = .measure;
                self.counting.reset();
                self.remaining_in_batch = self.batch_size;
                self.clock.reset();
                self.current_sample_started = true;
                if (self.remaining_in_batch > 0) {
                    self.remaining_in_batch -= 1;
                    self.total_iterations += 1;
                    return true;
                }
                return false;
            },
            .calibrate_measure => unreachable,
            .measure => {
                if (self.remaining_in_batch > 0) {
                    self.remaining_in_batch -= 1;
                    self.total_iterations += 1;
                    return true;
                }

                // Finished one timed sample.
                var elapsed = self.clock.readNs();
                if (self.paused_ns > 0 and elapsed > self.paused_ns) elapsed -= self.paused_ns;
                self.paused_ns = 0;
                const ns_per_op = @as(f64, @floatFromInt(@max(elapsed, 1))) / @as(f64, @floatFromInt(self.batch_size));
                try self.sample_ns.append(self.gpa, ns_per_op);
                self.samples_remaining -= 1;
                self.current_sample_started = false;

                if (self.samples_remaining == 0) {
                    if (self.options.track_allocations) {
                        self.allocation_snapshot = self.counting.snapshot();
                    }
                    return false;
                }

                self.remaining_in_batch = self.batch_size;
                self.clock.reset();
                self.current_sample_started = true;
                self.remaining_in_batch -= 1;
                self.total_iterations += 1;
                return true;
            },
        }
    }

    /// Pause timing (setup/teardown inside the loop). Prefer excluding work
    /// outside `next()` when possible — pause/resume has timer overhead.
    pub fn pause(self: *Bench) void {
        if (!self.timer_paused and self.current_sample_started) {
            self.paused_ns += self.clock.readNs();
            self.timer_paused = true;
        }
    }

    pub fn resumeTiming(self: *Bench) void {
        if (self.timer_paused) {
            self.clock.reset();
            self.timer_paused = false;
        }
    }

    pub fn setBytes(self: *Bench, bytes: u64) void {
        self.options.bytes_per_iter = bytes;
    }

    pub fn markFailed(self: *Bench) void {
        self.failed = true;
    }

    pub fn markSkipped(self: *Bench) void {
        self.skip = true;
    }

    pub fn finish(self: *Bench) !Result {
        if (self.failed) return error.BenchmarkFailed;
        if (self.skip) return error.BenchmarkSkipped;

        const summary = statistics.summarize(self.sample_ns.items);
        var throughput: ?f64 = null;
        if (self.options.bytes_per_iter) |bytes| {
            if (summary.median > 0) {
                const bytes_f: f64 = @floatFromInt(bytes);
                throughput = (bytes_f / summary.median) * 1e9;
            }
        } else if (self.options.items_per_iter) |items| {
            if (summary.median > 0) {
                const items_f: f64 = @floatFromInt(items);
                throughput = (items_f / summary.median) * 1e9;
            }
        }

        return .{
            .name = self.name,
            .group = self.options.group,
            .label = self.options.label,
            .summary = summary,
            .iterations = self.total_iterations,
            .batch_size = self.batch_size,
            .sample_count = self.sample_ns.items.len,
            .throughput_per_s = throughput,
            .bytes_per_iter = self.options.bytes_per_iter,
            .allocation = self.allocation_snapshot,
            .samples_ns = try self.gpa.dupe(f64, self.sample_ns.items),
        };
    }
};
