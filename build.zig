const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const santa_cruz = b.addModule("santa-cruz", .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sierra = b.addModule("sierra", .{
        .root_source_file = b.path("lib/sierra.root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Preserve the historical package module name for existing consumers.
    _ = b.addModule("santa_cruz_de_la_sierra", .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "scz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "santa-cruz", .module = santa_cruz },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the scz CLI");
    run_step.dependOn(&run_cmd.step);

    const santa_tests = b.addTest(.{
        .root_module = santa_cruz,
    });
    const sierra_tests = b.addTest(.{
        .root_module = sierra,
    });
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const stats_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sierra/statistics_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sierra", .module = sierra },
            },
        }),
    });

    const memory_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sierra/memory_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sierra", .module = sierra },
            },
        }),
    });

    const test_step = b.step("test", "Run Santa Cruz and Sierra tests");
    test_step.dependOn(&b.addRunArtifact(santa_tests).step);
    test_step.dependOn(&b.addRunArtifact(sierra_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(stats_tests).step);
    test_step.dependOn(&b.addRunArtifact(memory_tests).step);

    const sierra_fast = b.createModule(.{
        .root_source_file = b.path("lib/sierra.root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/sierra/basic.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const example_exe = addBenchmarkExecutable(b, .{
        .name = "sierra-example",
        .root_module = example_mod,
        .sierra_module = sierra_fast,
        .optimize = .ReleaseFast,
        .target = target,
    });
    const example_run = b.addRunArtifact(example_exe);
    example_run.addPassthruArgs();
    const example_step = b.step("bench-example", "Run the Sierra basic example benchmarks");
    example_step.dependOn(&example_run.step);

    const check_step = b.step("check", "Compile checks without running");
    check_step.dependOn(&santa_tests.step);
    check_step.dependOn(&sierra_tests.step);
    check_step.dependOn(&exe_tests.step);
    check_step.dependOn(&stats_tests.step);
    check_step.dependOn(&memory_tests.step);
    check_step.dependOn(&example_exe.step);
}

pub const BenchmarkOptions = struct {
    name: []const u8 = "sierra-bench",
    root_module: *std.Build.Module,
    sierra_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode = .ReleaseFast,
};

/// Create a benchmark executable that uses Sierra's generic entry point.
/// The consumer module must expose `pub const benchmarks = .{ ... };` and/or
/// public `bench*` functions.
pub fn addBenchmarkExecutable(b: *std.Build, options: BenchmarkOptions) *std.Build.Step.Compile {
    const write_files = b.addWriteFiles();
    const main_source = write_files.add("sierra_main.zig", @embedFile("tools/sierra_main.zig"));

    options.root_module.addImport("sierra", options.sierra_module);

    const exe = b.addExecutable(.{
        .name = options.name,
        .root_module = b.createModule(.{
            .root_source_file = main_source,
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{
                .{ .name = "sierra", .module = options.sierra_module },
                .{ .name = "sierra_root", .module = options.root_module },
            },
        }),
    });
    return exe;
}
