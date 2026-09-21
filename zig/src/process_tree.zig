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

pub const ChildControl = struct {
    job: if (builtin.os.tag == .windows) ?std.os.windows.HANDLE else void,

    pub fn empty() @This() {
        return .{ .job = if (comptime builtin.os.tag == .windows) null else {} };
    }

    pub fn init(child_id: std.process.Child.Id) !@This() {
        if (comptime builtin.os.tag == .windows) {
            const job = CreateJobObjectW(null, null) orelse return error.WindowsJobObjectUnavailable;
            if (!AssignProcessToJobObject(job, child_id).toBool()) {
                std.os.windows.CloseHandle(job);
                return error.WindowsJobObjectUnavailable;
            }
            return .{ .job = job };
        }
        return .{ .job = {} };
    }

    pub fn deinit(self: *@This()) void {
        if (comptime builtin.os.tag == .windows) {
            if (self.job) |job| {
                std.os.windows.CloseHandle(job);
                self.job = null;
            }
        }
    }
};

pub const SpawnedChild = struct {
    child: std.process.Child,
    control: ChildControl,

    pub fn spawn(io: std.Io, options: std.process.SpawnOptions, require_process_tree: bool) !@This() {
        var spawn_options = options;
        if (comptime builtin.os.tag == .windows) {
            if (require_process_tree) spawn_options.start_suspended = true;
        }

        var child = try std.process.spawn(io, spawn_options);
        var control = if (require_process_tree)
            ChildControl.init(child.id.?) catch |err| {
                terminateSpawnedChild(io, &child, spawn_options.start_suspended);
                return err;
            }
        else
            ChildControl.empty();
        errdefer {
            terminateSpawnedChild(io, &child, spawn_options.start_suspended);
            control.deinit();
        }

        if (comptime builtin.os.tag == .windows) {
            const status = std.os.windows.ntdll.NtResumeThread(child.thread_handle, null);
            if (status != .SUCCESS) return error.Unexpected;
        }

        return .{ .child = child, .control = control };
    }
};

fn terminateSpawnedChild(io: std.Io, child: *std.process.Child, was_suspended: bool) void {
    if (comptime builtin.os.tag == .windows) {
        if (was_suspended) {
            // Child.kill reports a silent process exit before terminating the
            // process. Reap a suspended child directly when setup fails.
            _ = std.os.windows.ntdll.NtTerminateProcess(child.id.?, @enumFromInt(1));
            _ = child.wait(io) catch {};
            return;
        }
    }
    child.kill(io);
}

const ProcessWaitResult = union(enum) {
    child: std.process.Child.WaitError!std.process.Child.Term,
    timeout: std.Io.Cancelable!void,
    grace: std.Io.Cancelable!void,
};

pub fn waitForChildWithTimeout(
    io: std.Io,
    child: *std.process.Child,
    control: *const ChildControl,
    timeout_ms: ?u64,
    emit_timeout_message: bool,
) !std.process.Child.Term {
    if (timeout_ms == null) return child.wait(io);
    if (comptime builtin.os.tag == .windows) {
        return waitForChildWithTimeoutWindows(io, child, control, timeout_ms.?, emit_timeout_message);
    }

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
    if (emit_timeout_message) writeTimeoutMessage(io, timeout_ms.?);

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

fn waitForChildWithTimeoutWindows(
    io: std.Io,
    child: *std.process.Child,
    control: *const ChildControl,
    timeout_ms: u64,
    emit_timeout_message: bool,
) !std.process.Child.Term {
    // Keep Windows timeout coordination on the process handle. An Io.Select
    // child-wait task can remain blocked while Job Object termination races
    // with the alertable wait, preventing the coordinator from completing.
    var remaining_ms = timeout_ms;
    while (remaining_ms > 0) {
        if (try childExitedWindows(child.id.?)) return child.wait(io);

        const sleep_ms = @min(remaining_ms, 20);
        try sleepFor(io, sleep_ms);
        remaining_ms -= sleep_ms;
    }

    if (try childExitedWindows(child.id.?)) return child.wait(io);

    const child_id = child.id.?;
    requestChildTermination(child_id, control);
    if (emit_timeout_message) writeTimeoutMessage(io, timeout_ms);

    if (!(try childExitedWindows(child_id))) {
        requestChildForceTermination(child_id, control);
    }
    return child.wait(io);
}

fn childExitedWindows(child_id: std.os.windows.HANDLE) !bool {
    var no_wait: std.os.windows.LARGE_INTEGER = 0;
    return switch (std.os.windows.ntdll.NtWaitForSingleObject(child_id, .FALSE, &no_wait)) {
        .WAIT_0 => true,
        .TIMEOUT => false,
        else => |status| std.os.windows.unexpectedStatus(status),
    };
}

fn waitForChild(io: std.Io, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
    return child.wait(io);
}

fn sleepFor(io: std.Io, duration_ms: u64) std.Io.Cancelable!void {
    const duration = std.math.cast(i64, duration_ms) orelse std.math.maxInt(i64);
    return std.Io.sleep(io, std.Io.Duration.fromMilliseconds(duration), .awake);
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

fn readChildStdout(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    max_bytes: usize,
) std.Io.Reader.LimitedAllocError![]u8 {
    var reader = stdout.readerStreaming(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes));
}

pub const CapturedStdout = struct {
    term: std.process.Child.Term,
    stdout: []u8,
};

pub fn runCapturedStdout(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: std.process.Child.Cwd,
    timeout_ms: ?u64,
    max_bytes: usize,
) !CapturedStdout {
    var spawned = try SpawnedChild.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = childProcessGroupId(),
    }, timeout_ms != null);
    defer spawned.control.deinit();

    const WaitResult = union(enum) {
        stdout: std.Io.Reader.LimitedAllocError![]u8,
        stderr: std.Io.Reader.LimitedAllocError![]u8,
        timeout: std.Io.Cancelable!void,
    };
    var select_buffer: [3]WaitResult = undefined;
    var select = std.Io.Select(WaitResult).init(io, &select_buffer);
    select.async(.stdout, readChildStdout, .{ allocator, io, spawned.child.stdout.?, max_bytes });
    select.async(.stderr, readChildStdout, .{ allocator, io, spawned.child.stderr.?, max_bytes });
    if (timeout_ms) |ms| select.async(.timeout, sleepFor, .{ io, ms });

    var stdout: ?[]u8 = null;
    var completed_streams: usize = 0;
    while (completed_streams < 2) {
        const result = select.await() catch |err| {
            requestChildForceTermination(spawned.child.id.?, &spawned.control);
            select.cancelDiscard();
            _ = spawned.child.wait(io) catch {};
            return err;
        };

        switch (result) {
            .stdout => |output| {
                stdout = output catch |err| {
                    requestChildForceTermination(spawned.child.id.?, &spawned.control);
                    select.cancelDiscard();
                    _ = spawned.child.wait(io) catch {};
                    return err;
                };
                completed_streams += 1;
            },
            .stderr => |output| {
                _ = output catch |err| {
                    requestChildForceTermination(spawned.child.id.?, &spawned.control);
                    select.cancelDiscard();
                    _ = spawned.child.wait(io) catch {};
                    return err;
                };
                completed_streams += 1;
            },
            .timeout => |timeout_result| {
                _ = timeout_result catch |err| {
                    requestChildForceTermination(spawned.child.id.?, &spawned.control);
                    select.cancelDiscard();
                    _ = spawned.child.wait(io) catch {};
                    return err;
                };
                requestChildForceTermination(spawned.child.id.?, &spawned.control);
                select.cancelDiscard();
                _ = spawned.child.wait(io) catch {};
                return error.Timeout;
            },
        }
    }

    select.cancelDiscard();
    const term = try spawned.child.wait(io);
    return .{ .term = term, .stdout = stdout.? };
}

pub fn childProcessGroupId() ?std.posix.pid_t {
    return if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) null else 0;
}

pub fn requestChildForceTermination(child_id: std.process.Child.Id, control: *const ChildControl) void {
    switch (builtin.os.tag) {
        .windows => {
            if (control.job) |job| {
                _ = TerminateJobObject(job, 1);
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

pub fn requestChildTermination(child_id: std.process.Child.Id, control: *const ChildControl) void {
    switch (builtin.os.tag) {
        .windows => {
            // Windows has no portable graceful process-tree signal. Terminate
            // the Job Object immediately so descendants cannot outlive a leader
            // that exits before the coordinator's grace window expires.
            if (control.job) |job| {
                _ = TerminateJobObject(job, 1);
            }
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
