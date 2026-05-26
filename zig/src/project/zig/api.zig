const std = @import("std");
const pathing = @import("../../pathing.zig");
const project_io = @import("../core/io.zig");

pub const Step = struct {
    name: []u8,
    is_default: bool,
};

const detect_steps_timeout_ms: u64 = 5000;

pub fn freeOwnedSteps(allocator: std.mem.Allocator, steps: []Step) void {
    for (steps) |step| {
        allocator.free(step.name);
    }
    allocator.free(steps);
}

pub fn findBuildRootAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_up: usize,
) !?[]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return findBuildRootAllocWithIO(threaded.io(), allocator, path, max_up);
}

pub fn findBuildRootAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_up: usize,
) !?[]u8 {
    const build_file = try project_io.findParentFileAllocWithIO(io, allocator, path, "build.zig", max_up) orelse return null;
    defer allocator.free(build_file);
    return @as(?[]u8, try allocator.dupe(u8, pathing.dirOrDot(build_file)));
}

pub fn detectSteps(allocator: std.mem.Allocator, build_root: []const u8) ![]Step {
    if (comptime @import("builtin").is_test) {
        return detectStepsWithIO(std.testing.io, allocator, build_root);
    }
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    return detectStepsWithIO(threaded.io(), allocator, build_root);
}

pub fn detectStepsWithIO(io: std.Io, allocator: std.mem.Allocator, build_root: []const u8) ![]Step {
    return detectStepsWithTimeoutWithIO(io, allocator, build_root, detect_steps_timeout_ms);
}

fn detectStepsWithTimeout(
    allocator: std.mem.Allocator,
    build_root: []const u8,
    timeout_ms: ?u64,
) ![]Step {
    if (comptime @import("builtin").is_test) {
        return detectStepsWithTimeoutWithIO(std.testing.io, allocator, build_root, timeout_ms);
    }
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    return detectStepsWithTimeoutWithIO(threaded.io(), allocator, build_root, timeout_ms);
}

fn detectStepsWithTimeoutWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    build_root: []const u8,
    timeout_ms: ?u64,
) ![]Step {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "zig", "build", "-l" },
        .cwd = .{ .path = build_root },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
        .timeout = if (timeout_ms) |ms|
            .{ .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)),
                .clock = .awake,
            } }
        else
            .none,
    }) catch |err| switch (err) {
        error.Timeout => return error.ZigBuildListStepsFailed,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.ZigBuildListStepsFailed,
        else => return error.ZigBuildListStepsFailed,
    }

    return parseListStepsOutput(allocator, result.stdout);
}

pub fn parseListStepsOutput(allocator: std.mem.Allocator, output: []const u8) ![]Step {
    var steps: std.ArrayList(Step) = .empty;
    errdefer {
        for (steps.items) |step| {
            allocator.free(step.name);
        }
        steps.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = trimLine(raw_line);
        if (line.len == 0) continue;

        const step_name = extractStepName(line) orelse continue;
        if (containsStep(steps.items, step_name)) continue;

        const owned_name = try allocator.dupe(u8, step_name);
        steps.append(allocator, .{
            .name = owned_name,
            .is_default = std.mem.find(u8, line, "(default)") != null,
        }) catch |err| {
            allocator.free(owned_name);
            return err;
        };
    }

    return steps.toOwnedSlice(allocator);
}

fn containsStep(steps: []const Step, needle: []const u8) bool {
    for (steps) |step| {
        if (std.mem.eql(u8, step.name, needle)) return true;
    }
    return false;
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn extractStepName(line: []const u8) ?[]const u8 {
    if (line.len == 0) return null;
    if (std.mem.startsWith(u8, line, "Usage:")) return null;
    if (line[0] == '-') return null;

    var end: usize = 0;
    while (end < line.len and !std.ascii.isWhitespace(line[end])) : (end += 1) {}
    if (end == 0) return null;

    const token = line[0..end];
    for (token) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) return null;
    }
    return token;
}

test "parseListStepsOutput extracts zig build steps" {
    const allocator = std.testing.allocator;
    const steps = try parseListStepsOutput(allocator,
        \\  install (default)            Copy build artifacts to prefix path
        \\  run                          Run the app
        \\  bench-fast                   Run a fast benchmark
        \\  smoke_test                   Run smoke checks
    );
    defer freeOwnedSteps(allocator, steps);

    try std.testing.expectEqual(@as(usize, 4), steps.len);
    try std.testing.expectEqualStrings("install", steps[0].name);
    try std.testing.expect(steps[0].is_default);
    try std.testing.expectEqualStrings("run", steps[1].name);
    try std.testing.expectEqualStrings("bench-fast", steps[2].name);
    try std.testing.expectEqualStrings("smoke_test", steps[3].name);
}

test "detectSteps reads custom steps from build root" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/main.zig", .data =
        \\pub fn main() void {}
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data =
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\    const module = b.createModule(.{
        \\        .root_source_file = b.path("src/main.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\    const exe = b.addExecutable(.{
        \\        .name = "demo",
        \\        .root_module = module,
        \\    });
        \\    b.installArtifact(exe);
        \\
        \\    const run_cmd = b.addRunArtifact(exe);
        \\    const run_step = b.step("run", "Run the app");
        \\    run_step.dependOn(&run_cmd.step);
        \\
        \\    const smoke_step = b.step("smoke", "Run smoke checks");
        \\    smoke_step.dependOn(&run_cmd.step);
        \\}
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);

    const steps = try detectSteps(allocator, root);
    defer freeOwnedSteps(allocator, steps);

    try std.testing.expect(containsStep(steps, "install"));
    try std.testing.expect(containsStep(steps, "run"));
    try std.testing.expect(containsStep(steps, "smoke"));
}

test "detectSteps fails fast when zig build -l exceeds timeout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data =
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    _ = b;
        \\    var threaded: std.Io.Threaded = .init_single_threaded;
        \\    std.Io.sleep(threaded.io(), std.Io.Duration.fromSeconds(2), .awake) catch unreachable;
        \\}
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);

    const started = std.Io.Timestamp.now(io, .awake);
    try std.testing.expectError(
        error.ZigBuildListStepsFailed,
        detectStepsWithTimeoutWithIO(io, allocator, root, 10),
    );
    const elapsed_ms = started.untilNow(io, .awake).toMilliseconds();
    try std.testing.expect(elapsed_ms < 1000);
}

test "detectSteps cleans up timeout watcher when output collection fails" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data =
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    _ = b;
        \\    var i: usize = 0;
        \\    while (i < 300_000) : (i += 1) {
        \\        std.debug.print("x", .{});
        \\    }
        \\}
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);

    const started = std.Io.Timestamp.now(io, .awake);
    try std.testing.expectError(
        error.StreamTooLong,
        detectStepsWithTimeoutWithIO(io, allocator, root, 5000),
    );
    const elapsed_ms = started.untilNow(io, .awake).toMilliseconds();
    try std.testing.expect(elapsed_ms < 10_000);
}

test "findBuildRootAlloc walks parents from relative path" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/build.zig", .data = "pub fn build(b: *std.Build) void { _ = b; }\n" });

    const repo_relative = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/repo", .{tmp.sub_path[0..]});
    defer allocator.free(repo_relative);
    const filepath_relative = try std.fmt.allocPrint(allocator, "{s}/src/main.zig", .{repo_relative});
    defer allocator.free(filepath_relative);

    const root = try findBuildRootAlloc(allocator, filepath_relative, 12);
    defer if (root) |value| allocator.free(value);

    try std.testing.expect(root != null);
    try std.testing.expectEqualStrings(repo_relative, root.?);
}
