# Sierra

Sierra is the benchmarking component of the `scz` package (Santa Cruz de la Sierra).
It is a **library-first** harness for Zig 0.17 with a dedicated runner executable.

## Philosophy

- Prefer a dedicated `zig build bench` executable over piggybacking on `zig test`.
- Explicit registration is canonical; optional `bench*` name discovery is available.
- Measure independent timed samples, not loop iterations inside a batch.
- Report a primary estimator (median) with variability and uncertainty.
- Keep allocation metrics separate from timing unless explicitly requested.
- When allocation data cannot be captured reliably, report **unavailable**, not zero.

## Basic usage

```zig
const sierra = @import("sierra");

pub fn benchAdd(b: *sierra.Bench) !void {
    while (try b.next()) {
        sierra.keepAlive(1 + 1);
    }
}

pub const benchmarks = .{
    .add = benchAdd,
};
```

Setup and teardown belong outside the `while (try b.next())` loop (or use
`b.pause()` / `b.resumeTiming()` sparingly).

## Build-system integration

From a consumer `build.zig` (including when `scz` is a Git submodule):

```zig
const scz = @import("dependencies/scz/build.zig");

const sierra_mod = b.createModule(.{
    .root_source_file = b.path("dependencies/scz/lib/sierra.root.zig"),
    .target = target,
    .optimize = .ReleaseFast,
});

const bench_root = b.createModule(.{
    .root_source_file = b.path("bench/parse.zig"),
    .target = target,
    .optimize = .ReleaseFast,
    .imports = &.{
        .{ .name = "sierra", .module = sierra_mod },
        // ... other imports
    },
});

const bench_exe = scz.addBenchmarkExecutable(b, .{
    .name = "bench",
    .root_module = bench_root,
    .sierra_module = sierra_mod,
    .optimize = .ReleaseFast,
    .target = target,
});
```

Sierra supplies the executable entry point; consumers do not write `main()`.

## Compile-time registration

Preferred:

```zig
pub const benchmarks = .{
    .parse_small = benchParseSmall,
    .parse_large = benchParseLarge,
};
```

Alternatively, public declarations named `bench*` / `Bench*` with signature
`fn (*sierra.Bench) anyerror!void` are discovered automatically.
Incompatible signatures are compile errors.

Optional hooks on the benchmark root module:

- `sierraPrepare(init, positionals)` — load fixtures before runs
- `sierraFinish(init, results)` — cleanup after runs

## Measurement lifecycle

1. Time-based warmup with growing probe batches
2. Calibrate batch size for the measurement budget
3. Collect independent timed samples (each sample = `batch_size` iterations)
4. Summarize per-operation estimates from those samples

`b.next()` returns `true` while more iterations are required. Adaptive batching
handles both nanosecond microbenchmarks and multi-millisecond operations.

## Statistical methodology

Per timed sample Sierra records nanoseconds/op. Summaries include:

- mean, median, min, max
- sample standard deviation
- median absolute deviation (MAD)
- selected percentiles (p25/p75/p95/p99)
- approximate 95% CI for the mean (normal approximation)

Iterations inside one timed batch are **not** treated as independent samples.
Baseline comparison reports relative median change; Welch-style significance is
available when comparing two measured summaries with variance.

## Timing limitations

- Uses the monotonic awake clock (`std.Io.Timestamp`).
- Timer pause/resume exists but adds overhead; prefer excluding setup outside the loop.
- Optimizer barriers (`keepAlive` / `blackBox`) discourage DCE but are not a
  guarantee that source-level operations execute exactly as written.

## Allocation instrumentation

`sierra.CountingAllocator` tracks Zig allocator `alloc` / `resize` / `remap` / `free`:

| Metric | Meaning |
| --- | --- |
| `alloc_calls` | Successful `alloc` calls |
| `bytes_requested` | Cumulative requested bytes (including growth) |
| `bytes_outstanding` | Currently unfreed requested bytes |
| `bytes_peak` | Peak outstanding requested bytes |

Requested bytes are not physical RSS. C libraries that bypass Zig allocators must
not be reported as zero-allocation; use unavailable metrics or an explicit C hook.

Enable tracking with `--benchmem` or `b.enableAllocationTracking()`.

## Baseline comparison

```text
--save-baseline path.json
--baseline path.json
```

Baselines store Sierra/Zig versions, optimize mode, OS/arch, and per-benchmark
summaries. Incompatible optimize/OS metadata produces warnings.

## CLI reference

```text
--list
--filter <substr>
--warmup <duration>     # e.g. 100ms, 1s
--time <duration>       # measurement budget
--samples <n>
--baseline <path>
--save-baseline <path>
--format <text|json|csv>
--output <path>
--benchmem
--seed <n>
-h, --help
```

## Examples

```sh
zig build bench-example -- --time=200ms --warmup=50ms --samples=8
zig build bench-example -- --filter=fib --format=json
```
