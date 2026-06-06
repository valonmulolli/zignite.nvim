const std = @import("std");
const config_view = @import("config/view.zig");
const config_store = @import("config/store.zig");

pub fn buildSystemArgv(
    allocator: std.mem.Allocator,
    command_text: []const u8,
    argv: []const []const u8,
    cleanup_command: ?[]const u8,
) !std.ArrayList([]u8) {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return buildSystemArgvWithIO(threaded.io(), allocator, command_text, argv, cleanup_command);
}

pub fn buildSystemArgvWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    command_text: []const u8,
    argv: []const []const u8,
    cleanup_command: ?[]const u8,
) !std.ArrayList([]u8) {
    if (argv.len == 0 and command_text.len == 0) {
        return error.MissingSystemCommandPayload;
    }

    var system_argv: std.ArrayList([]u8) = .empty;
    errdefer deinitOwnedArgv(allocator, &system_argv);

    const timeout_ms = config_view.executionTimeoutMs();
    if (timeout_ms == null and cleanup_command == null and argv.len > 0) {
        try system_argv.ensureTotalCapacity(allocator, argv.len);
        for (argv) |arg| {
            system_argv.appendAssumeCapacity(try allocator.dupe(u8, arg));
        }
        return system_argv;
    }

    const exe_path = try selfExePathAllocWithIO(io, allocator);
    defer allocator.free(exe_path);

    var capacity: usize = 1;
    if (timeout_ms != null) capacity += 1;
    if (cleanup_command) |_| capacity += 1;
    if (argv.len > 0) {
        capacity += 1 + argv.len;
    } else {
        capacity += 1;
    }

    try system_argv.ensureTotalCapacity(allocator, capacity);
    system_argv.appendAssumeCapacity(try allocator.dupe(u8, exe_path));
    if (timeout_ms) |ms| {
        system_argv.appendAssumeCapacity(try std.fmt.allocPrint(allocator, "--timeout={d}", .{ms}));
    }
    if (cleanup_command) |cleanup| {
        system_argv.appendAssumeCapacity(try std.fmt.allocPrint(allocator, "--cleanup={s}", .{cleanup}));
    }
    if (argv.len > 0) {
        system_argv.appendAssumeCapacity(try allocator.dupe(u8, "--argv"));
        for (argv) |arg| {
            system_argv.appendAssumeCapacity(try allocator.dupe(u8, arg));
        }
    } else {
        system_argv.appendAssumeCapacity(try allocator.dupe(u8, command_text));
    }

    return system_argv;
}

pub fn deinitOwnedArgv(allocator: std.mem.Allocator, argv: *std.ArrayList([]u8)) void {
    for (argv.items) |arg| allocator.free(arg);
    argv.deinit(allocator);
}

fn selfExePathAllocWithIO(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.process.executablePath(io, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

test "buildSystemArgv returns direct argv when no timeout is configured" {
    const allocator = std.testing.allocator;
    defer config_store.reset();

    var system_argv = try buildSystemArgv(allocator, "zig build run", &.{ "zig", "build", "run" }, null);
    defer deinitOwnedArgv(allocator, &system_argv);

    try std.testing.expectEqual(@as(usize, 3), system_argv.items.len);
    try std.testing.expectEqualStrings("zig", system_argv.items[0]);
    try std.testing.expectEqualStrings("build", system_argv.items[1]);
    try std.testing.expectEqualStrings("run", system_argv.items[2]);
}

test "buildSystemArgv wraps argv payload when timeout is configured" {
    const allocator = std.testing.allocator;
    defer config_store.reset();
    try config_store.setSyncedConfigJson(
        \\{"runners":{},"build_commands":{},"detect":{},"timeout":1500,"revision":1}
    , 1);

    var system_argv = try buildSystemArgv(allocator, "zig build run", &.{ "zig", "build", "run" }, null);
    defer deinitOwnedArgv(allocator, &system_argv);

    try std.testing.expect(system_argv.items.len >= 6);
    try std.testing.expectEqualStrings("--timeout=1500", system_argv.items[1]);
    try std.testing.expectEqualStrings("--argv", system_argv.items[2]);
    try std.testing.expectEqualStrings("zig", system_argv.items[3]);
    try std.testing.expectEqualStrings("build", system_argv.items[4]);
    try std.testing.expectEqualStrings("run", system_argv.items[5]);
}

test "buildSystemArgv includes synced timeout" {
    const allocator = std.testing.allocator;
    defer config_store.reset();
    try config_store.setSyncedConfigJson(
        \\{"runners":{},"build_commands":{},"detect":{},"timeout":1500,"revision":1}
    , 1);

    var system_argv = try buildSystemArgv(allocator, "echo hi", &.{}, null);
    defer deinitOwnedArgv(allocator, &system_argv);

    try std.testing.expect(system_argv.items.len >= 3);
    try std.testing.expectEqualStrings("--timeout=1500", system_argv.items[1]);
    try std.testing.expectEqualStrings("echo hi", system_argv.items[2]);
}

test "buildSystemArgv wraps argv payload when cleanup is configured" {
    const allocator = std.testing.allocator;
    defer config_store.reset();

    var system_argv = try buildSystemArgv(
        allocator,
        "javac Demo.java && java Demo",
        &.{ "javac", "Demo.java" },
        "rm -f Demo.class",
    );
    defer deinitOwnedArgv(allocator, &system_argv);

    try std.testing.expect(system_argv.items.len >= 5);
    try std.testing.expectEqualStrings("--cleanup=rm -f Demo.class", system_argv.items[1]);
    try std.testing.expectEqualStrings("--argv", system_argv.items[2]);
    try std.testing.expectEqualStrings("javac", system_argv.items[3]);
    try std.testing.expectEqualStrings("Demo.java", system_argv.items[4]);
}
