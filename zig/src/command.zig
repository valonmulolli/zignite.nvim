const std = @import("std");
const builtin = @import("builtin");

const TimeoutContext = struct {
    child_ptr: *std.process.Child,
    duration: u64,
    finished: *std.atomic.Value(bool),
};

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

    var child = if (use_argv) blk: {
        const child_args = args[command_idx..];
        if (child_args.len == 0) {
            std.log.err("Error: No argv payload provided after --argv", .{});
            std.process.exit(1);
        }
        break :blk try std.process.spawn(io, .{
            .argv = child_args,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        });
    } else blk: {
        const full_command = args[command_idx];
        const shell_flag = if (is_windows) "/C" else "-c";
        const shell_args = [_][]const u8{ shell, shell_flag, full_command };
        break :blk try std.process.spawn(io, .{
            .argv = &shell_args,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        });
    };

    var finished = std.atomic.Value(bool).init(false);
    var timeout_future: ?std.Io.Future(void) = null;
    var context: TimeoutContext = undefined;
    if (timeout_ms) |ms| {
        context = .{
            .child_ptr = &child,
            .duration = ms,
            .finished = &finished,
        };
        timeout_future = io.async(timeoutWatcher, .{ io, &context });
    }
    defer stopTimeoutWatcher(io, &finished, &timeout_future);

    const term = try child.wait(io);
    stopTimeoutWatcher(io, &finished, &timeout_future);
    runCleanup(io, cleanup_command);
    std.process.exit(termToExitCode(term));
}

fn stopTimeoutWatcher(io: std.Io, finished: *std.atomic.Value(bool), timeout_future: *?std.Io.Future(void)) void {
    finished.store(true, .release);
    if (timeout_future.*) |*future| {
        _ = future.cancel(io);
        timeout_future.* = null;
    }
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

fn timeoutWatcher(io: std.Io, ctx: *TimeoutContext) void {
    const clamped_duration = std.math.cast(u32, ctx.duration) orelse std.math.maxInt(u32);
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(clamped_duration), .awake) catch |err| switch (err) {
        error.Canceled => return,
    };
    if (ctx.finished.load(.acquire)) {
        return;
    }

    ctx.child_ptr.kill(io);

    var stderr_buffer: [128]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    stderr_writer.interface.print("\n[Zignite] Process timed out after {d}ms\n", .{ctx.duration}) catch |w_err| {
        std.log.err("Failed to print timeout message: {}", .{w_err});
    };
    stderr_writer.interface.flush() catch |f_err| {
        std.log.err("Failed to flush timeout message: {}", .{f_err});
    };
}

fn runCleanup(io: std.Io, cleanup_command: ?[]const u8) void {
    const cleanup = cleanup_command orelse return;
    if (std.mem.trim(u8, cleanup, " \t\r\n").len == 0) return;

    const is_windows = builtin.os.tag == .windows;
    const shell = if (is_windows) "cmd.exe" else "/bin/sh";
    const shell_flag = if (is_windows) "/C" else "-c";
    const shell_args = [_][]const u8{ shell, shell_flag, cleanup };

    var child = std.process.spawn(io, .{
        .argv = &shell_args,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        std.log.warn("Failed to spawn cleanup command: {}", .{err});
        return;
    };

    var finished = std.atomic.Value(bool).init(false);
    var context = TimeoutContext{
        .child_ptr = &child,
        .duration = 30000,
        .finished = &finished,
    };
    var timeout_future = io.async(timeoutWatcher, .{ io, &context });
    defer {
        finished.store(true, .release);
        _ = timeout_future.cancel(io);
    }

    _ = child.wait(io) catch |err| {
        std.log.warn("Failed to wait for cleanup command: {}", .{err});
    };
}
