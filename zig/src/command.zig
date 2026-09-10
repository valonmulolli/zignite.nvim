const std = @import("std");
const builtin = @import("builtin");

const timeout_grace_ms: u64 = 100;

extern "kernel32" fn CreateJobObjectW(
    attributes: ?*std.os.windows.SECURITY_ATTRIBUTES,
    name: ?std.os.windows.LPCWSTR,
) callconv(.winapi) ?std.os.windows.HANDLE;

extern "kernel32" fn AssignProcessToJobObject(
    job: std.os.windows.HANDLE,
    process: std.os.windows.HANDLE,
) callconv(.winapi) std.os.windows.BOOL;

extern "kernel32" fn TerminateJobObject(
    job: std.os.windows.HANDLE,
    exit_code: std.os.windows.UINT,
) callconv(.winapi) std.os.windows.BOOL;

const ChildControl = struct {
    job: if (builtin.os.tag == .windows) ?std.os.windows.HANDLE else void,

    fn init(child_id: std.process.Child.Id) @This() {
        if (comptime builtin.os.tag == .windows) {
            const job = CreateJobObjectW(null, null) orelse return .{ .job = null };
            if (!AssignProcessToJobObject(job, child_id).toBool()) {
                std.os.windows.CloseHandle(job);
                return .{ .job = null };
            }
            return .{ .job = job };
        }
        return .{ .job = {} };
    }

    fn deinit(self: *@This()) void {
        if (comptime builtin.os.tag == .windows) {
            if (self.job) |job| {
                std.os.windows.CloseHandle(job);
                self.job = null;
            }
        }
    }
};

const SpawnedChild = struct {
    child: std.process.Child,
    control: ChildControl,

    fn spawn(io: std.Io, options: std.process.SpawnOptions) !@This() {
        var spawn_options = options;
        if (comptime builtin.os.tag == .windows) {
            spawn_options.start_suspended = true;
        }

        var child = try std.process.spawn(io, spawn_options);
        var control = ChildControl.init(child.id.?);
        errdefer {
            child.kill(io);
            control.deinit();
        }

        if (comptime builtin.os.tag == .windows) {
            const status = std.os.windows.ntdll.NtResumeThread(child.thread_handle, null);
            if (status != .SUCCESS) return error.Unexpected;
        }

        return .{ .child = child, .control = control };
    }
};

const ProcessWaitResult = union(enum) {
    child: std.process.Child.WaitError!std.process.Child.Term,
    timeout: std.Io.Cancelable!void,
    grace: std.Io.Cancelable!void,
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
        });
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
        });
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

fn waitForChild(io: std.Io, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
    return child.wait(io);
}

fn sleepFor(io: std.Io, duration_ms: u64) std.Io.Cancelable!void {
    const duration = std.math.cast(i64, duration_ms) orelse std.math.maxInt(i64);
    return std.Io.sleep(io, std.Io.Duration.fromMilliseconds(duration), .awake);
}

fn waitForChildWithTimeout(
    io: std.Io,
    child: *std.process.Child,
    control: *const ChildControl,
    timeout_ms: ?u64,
) !std.process.Child.Term {
    if (timeout_ms == null) return child.wait(io);

    var select_buffer: [3]ProcessWaitResult = undefined;
    var select = std.Io.Select(ProcessWaitResult).init(io, &select_buffer);
    select.async(.child, waitForChild, .{ io, child });
    select.async(.timeout, sleepFor, .{ io, timeout_ms.? });

    const child_id = child.id.?;
    const first = select.await() catch |err| {
        requestChildForceTermination(child_id, control);
        select.cancelDiscard();
        return err;
    };

    switch (first) {
        .child => |result| {
            select.cancelDiscard();
            return result;
        },
        .timeout => |result| {
            _ = result catch |err| {
                requestChildForceTermination(child_id, control);
                select.cancelDiscard();
                return err;
            };
        },
        .grace => unreachable,
    }

    requestChildTermination(child_id, control);
    writeTimeoutMessage(io, timeout_ms.?);

    select.async(.grace, sleepFor, .{ io, timeout_grace_ms });
    const second = select.await() catch |err| {
        requestChildForceTermination(child_id, control);
        select.cancelDiscard();
        return err;
    };

    switch (second) {
        .child => |result| {
            select.cancelDiscard();
            return result;
        },
        .grace => |result| {
            _ = result catch |err| {
                requestChildForceTermination(child_id, control);
                select.cancelDiscard();
                return err;
            };
            requestChildForceTermination(child_id, control);
            const final = select.await() catch |err| {
                select.cancelDiscard();
                return err;
            };
            switch (final) {
                .child => |child_result| return child_result,
                .timeout, .grace => unreachable,
            }
        },
        .timeout => unreachable,
    }
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

fn childProcessGroupId() ?std.posix.pid_t {
    return if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) null else 0;
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

fn requestChildForceTermination(child_id: std.process.Child.Id, control: *const ChildControl) void {
    switch (builtin.os.tag) {
        .windows => {
            if (control.job) |job| {
                if (TerminateJobObject(job, 1).toBool()) return;
            }
            _ = std.os.windows.ntdll.NtTerminateProcess(child_id, @enumFromInt(1));
        },
        .wasi => {},
        else => {
            _ = std.posix.kill(-child_id, .KILL) catch {
                _ = std.posix.kill(child_id, .KILL) catch {};
            };
        },
    }
}

fn requestChildTermination(child_id: std.process.Child.Id, control: *const ChildControl) void {
    _ = control;
    switch (builtin.os.tag) {
        .windows => {
            // Windows has no portable graceful process-tree signal. Terminate
            // the leader during the grace window and use the Job Object for
            // the forceful descendant cleanup if the grace period expires.
            _ = std.os.windows.ntdll.NtTerminateProcess(child_id, @enumFromInt(1));
        },
        .wasi => {},
        else => {
            // The runner can start a shell or a process tree. Signal the
            // dedicated group so descendants do not outlive the timeout.
            _ = std.posix.kill(-child_id, .TERM) catch {
                _ = std.posix.kill(child_id, .TERM) catch {};
            };
        },
    }
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
    }) catch |err| {
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
    });
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
    });
    defer spawned.control.deinit();
    const term = try waitForChildWithTimeout(std.testing.io, &spawned.child, &spawned.control, 50);
    switch (term) {
        .signal => |sig| try std.testing.expectEqual(std.posix.SIG.KILL, sig),
        else => return error.ProcessWasNotForceKilled,
    }
}
