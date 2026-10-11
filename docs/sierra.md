# Sierra

Sierra is a **library-first** benchmarking harness for Zig 0.17 with a dedicated
runner executable. Import with `@import("sierra")`.

## Philosophy

- Prefer a dedicated `zig build bench` executable over piggybacking on `zig test`.
- Explicit registration is canonical; optional `bench*` name discovery is available.
- Measure independent timed samples, not loop iterations inside a batch.
- Report a primary estimator (median) with variability and uncertainty.
- Keep allocation metrics separate from timing unless explicitly requested.
- When allocation data cannot be captured reliably, report **n/a**, not zero.
- Default text output is a compact comparison table (sorted by workload).

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

For paired backend comparisons, set `b.options.group` (`"yaml"` / `"fy"`) and
`b.options.label` (workload name) so the table can pair and sort rows.

Setup and teardown belong outside the `while (try b.next())` loop.

## Build-system integration

```zig
const sierra_build = @import("sierra"); // package build.zig

const sierra_mod = b.dependency("sierra", .{
    .target = target,
    .optimize = .ReleaseFast,
}).module("sierra");

const bench_root = b.createModule(.{
    .root_source_file = b.path("bench/parse.zig"),
    .target = target,
    .optimize = .ReleaseFast,
    .imports = &.{
        .{ .name = "sierra", .module = sierra_mod },
    },
});

const bench_exe = sierra_build.addBenchmarkExecutable(b, .{
    .name = "bench",
    .root_module = bench_root,
    .sierra_module = sierra_mod,
    .optimize = .ReleaseFast,
    .target = target,
});
```

Always compile the Sierra module used by benches as **ReleaseFast** so the
report header does not claim Debug.

## CLI

```text
--list
--filter <substr>
--warmup <duration>
--time <duration>
--samples <n>
--baseline <path>
--save-baseline <path>
--format <text|json|csv>
--output <path>
--benchmem
--seed <n>
--verbose
-h, --help
```

When `GITHUB_STEP_SUMMARY` is set, Sierra appends a markdown comparison table
(same columns as the terminal report).

## Examples

```sh
zig build test
zig build check
zig build bench-example -- --time=200ms --warmup=50ms
```
