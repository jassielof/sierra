//! Zig allocator instrumentation for allocation-focused measurements.
//!
//! Metrics distinguish requested bytes from physical heap usage. Peak and
//! outstanding bytes refer to the sum of requested allocation sizes that have
//! not yet been freed through this wrapper.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Metrics = struct {
    /// Number of successful `alloc` calls.
    alloc_calls: u64 = 0,
    /// Number of successful `resize` calls.
    resize_calls: u64 = 0,
    /// Number of successful `remap` calls.
    remap_calls: u64 = 0,
    /// Number of `free` calls.
    free_calls: u64 = 0,
    /// Cumulative requested bytes from alloc + growth via resize/remap.
    bytes_requested: u64 = 0,
    /// Currently outstanding requested bytes.
    bytes_outstanding: u64 = 0,
    /// Peak outstanding requested bytes.
    bytes_peak: u64 = 0,
    /// Failed allocation attempts (null returns from alloc/remap).
    alloc_failures: u64 = 0,

    pub fn reset(self: *Metrics) void {
        self.* = .{};
    }
};

/// Unavailable allocation data — distinct from a measured zero-allocation run.
pub const Availability = enum {
    available,
    unavailable,
};

pub const Snapshot = struct {
    availability: Availability,
    metrics: Metrics = .{},

    pub fn unavailable() Snapshot {
        return .{ .availability = .unavailable };
    }

    pub fn fromMetrics(metrics: Metrics) Snapshot {
        return .{ .availability = .available, .metrics = metrics };
    }
};

/// Allocator wrapper that records allocation activity.
pub const CountingAllocator = struct {
    parent: Allocator,
    metrics: Metrics = .{},
    fail_after: ?u64 = null,

    pub fn init(parent: Allocator) CountingAllocator {
        return .{ .parent = parent };
    }

    pub fn allocator(self: *CountingAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn reset(self: *CountingAllocator) void {
        self.metrics.reset();
    }

    pub fn snapshot(self: *const CountingAllocator) Snapshot {
        return .fromMetrics(self.metrics);
    }

    fn recordGrowth(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            const delta: u64 = @intCast(new_len - old_len);
            self.metrics.bytes_requested += delta;
            self.metrics.bytes_outstanding += delta;
            self.metrics.bytes_peak = @max(self.metrics.bytes_peak, self.metrics.bytes_outstanding);
        } else if (new_len < old_len) {
            self.metrics.bytes_outstanding -= @intCast(old_len - new_len);
        }
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (self.fail_after) |n| {
            if (self.metrics.alloc_calls >= n) {
                self.metrics.alloc_failures += 1;
                return null;
            }
        }
        const ptr = self.parent.rawAlloc(len, alignment, ret_addr) orelse {
            self.metrics.alloc_failures += 1;
            return null;
        };
        self.metrics.alloc_calls += 1;
        self.metrics.bytes_requested += len;
        self.metrics.bytes_outstanding += len;
        self.metrics.bytes_peak = @max(self.metrics.bytes_peak, self.metrics.bytes_outstanding);
        return ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.parent.rawResize(buf, alignment, new_len, ret_addr)) return false;
        self.metrics.resize_calls += 1;
        self.recordGrowth(buf.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawRemap(buf, alignment, new_len, ret_addr) orelse {
            self.metrics.alloc_failures += 1;
            return null;
        };
        self.metrics.remap_calls += 1;
        self.recordGrowth(buf.len, new_len);
        return ptr;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(buf, alignment, ret_addr);
        self.metrics.free_calls += 1;
        self.metrics.bytes_outstanding -= buf.len;
    }
};
