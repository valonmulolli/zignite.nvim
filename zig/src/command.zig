const std = @import("std");
const builtin = @import("builtin");

const TimeoutContext = struct {
    child_ptr: *std.process.Child,
    duration: u64,
    finished: *std.atomic.Value(bool),
};

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var timeout_ms: ?u64 = null;
    var command_idx: usize = 1;
    var use_argv = false;

    while (command_idx < args.len) {
        const arg = args[command_idx];
        if (std.mem.startsWith(u8, arg, "--timeout=")) {
            timeout_ms = try std.fmt.parseInt(u64, arg[10..], 10);
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
        break :blk std.process.Child.init(child_args, allocator);
    } else blk: {
        const full_command = args[command_idx];
        const shell_flag = if (is_windows) "/C" else "-c";
        const shell_args = [_][]const u8{ shell, shell_flag, full_command };
        break :blk std.process.Child.init(&shell_args, allocator);
    };

    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    var finished = std.atomic.Value(bool).init(false);
    var context: TimeoutContext = undefined;
    if (timeout_ms) |ms| {
        context = .{
            .child_ptr = &child,
            .duration = ms,
            .finished = &finished,
        };
        const thread = try std.Thread.spawn(.{}, timeoutWatcher, .{&context});
        thread.detach();
    }

    const term = try child.wait();
    finished.store(true, .release);
    std.process.exit(termToExitCode(term));
}

fn termToExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |code| if (code > 255) 255 else @as(u8, @intCast(code)),
        .Signal => |sig| blk: {
            const code = 128 + sig;
            break :blk if (code > 255) 255 else @as(u8, @intCast(code));
        },
        .Stopped => |sig| blk: {
            const code = 128 + sig;
            break :blk if (code > 255) 255 else @as(u8, @intCast(code));
        },
        .Unknown => |status| if (status > 255) 255 else @as(u8, @intCast(status)),
    };
}

fn timeoutWatcher(ctx: *TimeoutContext) void {
    std.Thread.sleep(ctx.duration * 1_000_000);
    if (ctx.finished.load(.acquire)) {
        return;
    }

    _ = ctx.child_ptr.kill() catch |err| {
        std.log.err("Failed to kill process on timeout: {}", .{err});
    };
    std.debug.print("\n[Zignite] Process timed out after {d}ms\n", .{ctx.duration});
}
