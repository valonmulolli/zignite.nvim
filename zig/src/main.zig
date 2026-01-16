const std = @import("std");
const builtin = @import("builtin");

const TimeoutContext = struct {
    child_ptr: *std.process.Child,
    duration: u64,
    finished: *std.atomic.Value(bool),
};

pub fn main() !void {
    // Use GeneralPurposeAllocator for better memory management
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // --- Argument Parsing ---
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // We expect: zignite [--timeout=MS] <full command string>
    if (args.len < 2) {
        std.log.err("Usage: zignite [--timeout=MS] <full command string>", .{});
        std.process.exit(1);
    }

    var timeout_ms: ?u64 = null;
    var command_idx: usize = 1;

    // Check for optional flags before the command
    if (std.mem.startsWith(u8, args[1], "--timeout=")) {
        const value = args[1][10..];
        timeout_ms = try std.fmt.parseInt(u64, value, 10);
        command_idx = 2;

        if (args.len < 3) {
            std.log.err("Error: No command provided after timeout flag", .{});
            std.process.exit(1);
        }
    }

    // Get the shell to use
    // On Windows, default to cmd.exe if SHELL not set. On POSIX, /bin/sh.
    const is_windows = builtin.os.tag == .windows;
    const default_shell = if (is_windows) "cmd.exe" else "/bin/sh";
    const shell = std.posix.getenv("SHELL") orelse default_shell;

    // Use the remaining argument as the complete command string
    const full_command = args[command_idx];

    // Execute through shell with correct flag (-c or /c)
    const shell_flag = if (is_windows) "/C" else "-c";
    const shell_args = [_][]const u8{ shell, shell_flag, full_command };

    // --- Child Process Execution ---
    var child = std.process.Child.init(&shell_args, allocator);

    // Inherit stdin/stdout/stderr from parent process
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    // --- Timeout Handling ---
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

    // Signal that the process finished naturally
    finished.store(true, .release);

    // --- Exit with proper code ---
    const exit_code: u8 = switch (term) {
        .Exited => |code| blk: {
            break :blk if (code > 255) 255 else @as(u8, @intCast(code));
        },
        .Signal => |sig| blk: {
            const code = 128 + sig;
            break :blk if (code > 255) 255 else @as(u8, @intCast(code));
        },
        .Stopped => |sig| blk: {
            const code = 128 + sig;
            break :blk if (code > 255) 255 else @as(u8, @intCast(code));
        },
        .Unknown => |status| blk: {
            break :blk if (status > 255) 255 else @as(u8, @intCast(status));
        },
    };

    std.process.exit(exit_code);
}

fn timeoutWatcher(ctx: *TimeoutContext) void {
    // Cross-platform sleep (std.Thread.sleep takes nanoseconds)
    std.Thread.sleep(ctx.duration * 1_000_000);

    // Check if process finished already to avoid race condition
    if (ctx.finished.load(.acquire)) {
        return;
    }

    // If we wake up and process is meant to be killed
    _ = ctx.child_ptr.kill() catch |err| {
        std.log.err("Failed to kill process on timeout: {}", .{err});
    };

    // Print explicit timeout message
    std.debug.print("\n[Zignite] Process timed out after {d}ms\n", .{ctx.duration});
}
