const std = @import("std");
const builtin = @import("builtin");
const process_tree = @import("process_tree.zig");

const SpawnedChild = process_tree.SpawnedChild;
const childProcessGroupId = process_tree.childProcessGroupId;
const requestChildForceTermination = process_tree.requestChildForceTermination;
const requestChildTermination = process_tree.requestChildTermination;

pub fn run(io: std.Io, args: []const []const u8) !void {
    var timeout_ms: ?u64 = null;
    var cleanup_command: ?[]const u8 = null;
    var command_idx: usize = 1;
    var use_argv = false;

    while (command_idx < args.len) {
        const arg = args[command_idx];
        if (std.mem.startsWith(u8, arg, "--timeout=")) {
            timeout_ms = try std.fmt.parseInt(u64, arg[10..], 10);
            command_idx += 1;
        } else if (std.mem.startsWith(u8, arg, "--cleanup=")) {
            cleanup_command = arg["--cleanup=".len..];
            command_idx += 1;
        } else if (std.mem.eql(u8, arg, "--argv")) {
            use_argv = true;
            command_idx += 1;
            break;
        } else {
            break;
        }
    }

    if (command_idx >= args.len) {
        std.log.err("Error: No command provided", .{});
        std.process.exit(1);
    }

    const is_windows = builtin.os.tag == .windows;
    const shell = if (is_windows) "cmd.exe" else "/bin/sh";

    var spawned = if (use_argv) blk: {
        const child_args = args[command_idx..];
        if (child_args.len == 0) {
            std.log.err("Error: No argv payload provided after --argv", .{});
            std.process.exit(1);
        }
        break :blk try SpawnedChild.spawn(io, .{
            .argv = child_args,
            .pgid = childProcessGroupId(),
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        }, timeout_ms != null);
    } else blk: {
        const full_command = args[command_idx];
        const shell_flag = if (is_windows) "/C" else "-c";
        const shell_args = [_][]const u8{ shell, shell_flag, full_command };
        break :blk try SpawnedChild.spawn(io, .{
            .argv = &shell_args,
            .pgid = childProcessGroupId(),
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        }, timeout_ms != null);
    };
    defer spawned.control.deinit();

    const term = waitForChildWithTimeout(io, &spawned.child, &spawned.control, timeout_ms) catch |err| {
        // wait() failed (e.g. platform error). The child may still be alive;
        // kill it best-effort before propagating the error.
        if (spawned.child.id) |child_id| {
            requestChildTermination(child_id, &spawned.control);
            spawned.child.kill(io);
        }
        return err;
    };

    // Child finished normally or was terminated by the timeout coordinator.
    runCleanup(io, cleanup_command);
    std.process.exit(termToExitCode(term));
}

fn writeTimeoutMessage(io: std.Io, duration_ms: u64) void {
    var stderr_buffer: [128]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    stderr_writer.interface.print("\n[Zignite] Process timed out after {d}ms\n", .{duration_ms}) catch |err| {
        std.log.err("Failed to print timeout message: {}", .{err});
    };
    stderr_writer.interface.flush() catch |err| {
        std.log.err("Failed to flush timeout message: {}", .{err});
    };
}

fn waitForChildWithTimeout(
    io: std.Io,
    child: *std.process.Child,
    control: *const process_tree.ChildControl,
    timeout_ms: ?u64,
) !std.process.Child.Term {
    return process_tree.waitForChildWithTimeout(io, child, control, timeout_ms, true);
}

fn termToExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| if (code > 255) 255 else @as(u8, @intCast(code)),
        .signal => |sig| blk: {
            const code = 128 + @intFromEnum(sig);
            break :blk if (code > 255) 255 else @as(u8, @intCast(code));
        },
        .stopped => |sig| blk: {
            const code = 128 + @intFromEnum(sig);
            break :blk if (code > 255) 255 else @as(u8, @intCast(code));
        },
        .unknown => |status| if (status > 255) 255 else @as(u8, @intCast(status)),
    };
}

test "termToExitCode passes through small exit codes" {
    try std.testing.expectEqual(@as(u8, 0), termToExitCode(.{ .exited = 0 }));
    try std.testing.expectEqual(@as(u8, 1), termToExitCode(.{ .exited = 1 }));
    try std.testing.expectEqual(@as(u8, 127), termToExitCode(.{ .exited = 127 }));
    try std.testing.expectEqual(@as(u8, 255), termToExitCode(.{ .exited = 255 }));
}

test "termToExitCode clamps large unknown status to 255" {
    try std.testing.expectEqual(@as(u8, 255), termToExitCode(.{ .unknown = 9999 }));
}

test "termToExitCode encodes signals as 128 + signal number" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    try std.testing.expectEqual(@as(u8, 130), termToExitCode(.{ .signal = .INT }));
    try std.testing.expectEqual(@as(u8, 143), termToExitCode(.{ .signal = .TERM }));
    try std.testing.expectEqual(@as(u8, 137), termToExitCode(.{ .signal = .KILL }));
}

test "termToExitCode encodes stopped as 128 + signal number" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    try std.testing.expectEqual(@as(u8, 128 + @intFromEnum(std.posix.SIG.STOP)), termToExitCode(.{ .stopped = .STOP }));
}

test "termToExitCode treats unknown as raw status" {
    try std.testing.expectEqual(@as(u8, 42), termToExitCode(.{ .unknown = 42 }));
    try std.testing.expectEqual(@as(u8, 255), termToExitCode(.{ .unknown = 9999 }));
}

fn runCleanup(io: std.Io, cleanup_command: ?[]const u8) void {
    const cleanup = cleanup_command orelse return;
    if (std.mem.trim(u8, cleanup, " \t\r\n").len == 0) return;

    const is_windows = builtin.os.tag == .windows;
    const shell = if (is_windows) "cmd.exe" else "/bin/sh";
    const shell_flag = if (is_windows) "/C" else "-c";
    const shell_args = [_][]const u8{ shell, shell_flag, cleanup };

    var spawned = SpawnedChild.spawn(io, .{
        .argv = &shell_args,
        .pgid = childProcessGroupId(),
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }, true) catch |err| {
        std.log.warn("Failed to spawn cleanup command: {}", .{err});
        return;
    };
    defer spawned.control.deinit();

    _ = waitForChildWithTimeout(io, &spawned.child, &spawned.control, 30000) catch |err| {
        std.log.warn("Failed to wait for cleanup command: {}", .{err});
        if (spawned.child.id) |child_id| {
            requestChildTermination(child_id, &spawned.control);
            spawned.child.kill(io);
        }
    };
}

test "timeout termination includes descendant processes" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const marker = try std.fs.path.join(allocator, &.{ root, "marker" });
    defer allocator.free(marker);
    const script = try std.fmt.allocPrint(allocator, "(sleep 0.2; touch '{s}') & wait", .{marker});
    defer allocator.free(script);
    const shell_args = [_][]const u8{ "/bin/sh", "-c", script };

    var spawned = try SpawnedChild.spawn(std.testing.io, .{
        .argv = &shell_args,
        .pgid = childProcessGroupId(),
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }, true);
    defer spawned.control.deinit();
    requestChildTermination(spawned.child.id.?, &spawned.control);
    _ = try spawned.child.wait(std.testing.io);

    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(350), .awake) catch unreachable;
    if (tmp.dir.access(std.testing.io, "marker", .{})) |_| {
        return error.DescendantSurvivedTimeout;
    } else |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    }
}

test "timeout coordinator force-kills processes that ignore term" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const shell_args = [_][]const u8{ "/bin/sh", "-c", "trap '' TERM; sleep 5" };
    var spawned = try SpawnedChild.spawn(std.testing.io, .{
        .argv = &shell_args,
        .pgid = childProcessGroupId(),
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }, true);
    defer spawned.control.deinit();
    const term = try waitForChildWithTimeout(std.testing.io, &spawned.child, &spawned.control, 50);
    switch (term) {
        .signal => |sig| try std.testing.expectEqual(std.posix.SIG.KILL, sig),
        else => return error.ProcessWasNotForceKilled,
    }
}

test "windows timeout coordinator terminates a suspended child" {
    if (comptime builtin.os.tag != .windows) return;

    const shell_args = [_][]const u8{
        "cmd.exe",
        "/C",
        "ping.exe -n 6 127.0.0.1 > NUL",
    };
    var spawned = try SpawnedChild.spawn(std.testing.io, .{
        .argv = &shell_args,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }, true);
    defer spawned.control.deinit();

    const term = try waitForChildWithTimeout(std.testing.io, &spawned.child, &spawned.control, 50);
    switch (term) {
        .exited => |code| try std.testing.expect(code != 0),
        else => return error.UnexpectedWindowsTermination,
    }
}

test "windows timeout coordinator terminates descendants" {
    if (comptime builtin.os.tag != .windows) return;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "child.bat",
        .data = "@echo off\r\n" ++
            "echo started > parent.marker\r\n" ++
            "start \"\" /B cmd.exe /C \"ping.exe -n 6 127.0.0.1 > NUL & echo survived > descendant.marker\"\r\n" ++
            "ping.exe -n 6 127.0.0.1 > NUL\r\n",
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const shell_args = [_][]const u8{ "cmd.exe", "/C", "child.bat" };

    var spawned = try SpawnedChild.spawn(std.testing.io, .{
        .argv = &shell_args,
        .cwd = .{ .path = root },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }, true);
    defer spawned.control.deinit();

    var parent_started = false;
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        if (tmp.dir.access(std.testing.io, "parent.marker", .{})) |_| {
            parent_started = true;
            break;
        } else |_| {
            std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(20), .awake) catch unreachable;
        }
    }
    try std.testing.expect(parent_started);

    const term = try waitForChildWithTimeout(std.testing.io, &spawned.child, &spawned.control, 2000);
    switch (term) {
        .exited => |code| try std.testing.expect(code != 0),
        else => return error.UnexpectedWindowsTermination,
    }

    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(6500), .awake) catch unreachable;
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(std.testing.io, "descendant.marker", .{}),
    );
}
