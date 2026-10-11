# Sierra

Benchmarking for Zig.

See [docs/sierra.md](docs/sierra.md) for architecture, CLI, statistics, and build integration.

## Quick start (Sierra)

```zig
const sierra = @import("sierra");

pub fn benchNop(b: *sierra.Bench) !void {
    while (try b.next()) {
        sierra.keepAlive(0);
    }
}

pub const benchmarks = .{ .nop = benchNop };
```

```sh
zig build test
zig build bench-example -- --time=200ms --warmup=50ms
```
