const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zignite",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_unit_tests = b.addTest(.{
        .name = "zignite-tests",
        .root_module = test_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const check_step = b.step("check", "Compile the app and tests without running them");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&exe_unit_tests.step);

    const bench_step = b.step("bench", "Run the benchmark harness against the built backend");
    bench_step.dependOn(&addBenchmarkRun(b, exe, "3000", false).step);

    const bench_fast_step = b.step("bench-fast", "Run a fast benchmark pass against the built backend");
    bench_fast_step.dependOn(&addBenchmarkRun(b, exe, "1000", false).step);

    const bench_ci_step = b.step("bench-ci", "Run the benchmark harness with hard-fail guardrails");
    bench_ci_step.dependOn(&addBenchmarkRun(b, exe, "3000", true).step);
}

fn addBenchmarkRun(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    default_iterations: []const u8,
    hard_fail: bool,
) *std.Build.Step.Run {
    const bench_cmd = b.addSystemCommand(&.{"lua"});
    bench_cmd.addFileArg(b.path("../test/benchmark.lua"));
    bench_cmd.addDirectoryArg(b.path(".."));
    bench_cmd.step.dependOn(b.getInstallStep());
    bench_cmd.step.dependOn(&exe.step);

    if (hard_fail) {
        bench_cmd.setEnvironmentVariable("ZIGNITE_BENCH_HARD_FAIL", "1");
    }

    if (b.args) |args| {
        bench_cmd.addArgs(args);
    } else {
        bench_cmd.addArg(default_iterations);
    }

    return bench_cmd;
}
