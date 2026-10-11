const sierra = @import("sierra");

fn fib(n: u64) u64 {
    if (n < 2) return n;
    var a: u64 = 0;
    var b: u64 = 1;
    var i: u64 = 2;
    while (i <= n) : (i += 1) {
        const next = a + b;
        a = b;
        b = next;
    }
    return b;
}

pub fn benchNop(b: *sierra.Bench) !void {
    while (try b.next()) {
        sierra.keepAlive(0);
    }
}

pub fn benchFib20(b: *sierra.Bench) !void {
    while (try b.next()) {
        sierra.keepAlive(fib(20));
    }
}

pub fn benchAlloc(b: *sierra.Bench) !void {
    b.enableAllocationTracking();
    while (try b.next()) {
        const buf = try b.allocator.alloc(u8, 64);
        defer b.allocator.free(buf);
        @memset(buf, 0xAB);
        sierra.keepAlive(buf[0]);
    }
}

pub const benchmarks = .{
    .nop = benchNop,
    .fib20 = benchFib20,
    .alloc = benchAlloc,
};
