//! Monotonic high-resolution elapsed-time clock.
const std = @import("std");
const Io = std.Io;

pub const Error = error{
    TimerUnsupported,
};

/// Monotonic timer backed by the awake clock.
pub const Clock = struct {
    io: Io,
    started: Io.Timestamp,

    pub fn start(io: Io) Clock {
        return .{
            .io = io,
            .started = .now(io, .awake),
        };
    }

    pub fn reset(self: *Clock) void {
        self.started = .now(self.io, .awake);
    }

    /// Elapsed nanoseconds since the last reset/start.
    pub fn readNs(self: *const Clock) u64 {
        const ns = self.started.durationTo(.now(self.io, .awake)).toNanoseconds();
        return if (ns <= 0) 0 else @intCast(ns);
    }

    /// Elapsed nanoseconds, floored to at least 1.
    pub fn readNsAtLeastOne(self: *const Clock) u64 {
        return @max(self.readNs(), 1);
    }
};

test "clock advances" {
    const io = std.testing.io;
    var clock = Clock.start(io);
    try io.sleep(.fromMilliseconds(1), .awake);
    try std.testing.expect(clock.readNs() >= 100_000);
}
