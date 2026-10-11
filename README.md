# Sierra

Benchmarking for Zig 0.17.

See [docs/sierra.md](docs/sierra.md) for architecture, CLI, statistics, and build integration.

## Quick start

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
zig build check
zig build bench-example -- --time=200ms --warmup=50ms
```

## References

Study-only checkouts under `references/` (Criterion, zBench, zig-benchmark, zmida).
Not linked into production builds.
