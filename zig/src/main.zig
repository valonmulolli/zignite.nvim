const std = @import("std");
const builtin = @import("builtin");

const TimeoutContext = struct {
    child_ptr: *std.process.Child,
    duration: u64,
    finished: *std.atomic.Value(bool),
};

const QuickfixOptions = struct {
    max_lines: usize = 1000,
    max_bytes: usize = 262_144,
    strip_ansi: bool = true,
    strip_max_lines: usize = 400,
    parse_diagnostics: bool = true,
};

const DaemonRequestHeader = struct {
    request_id: u64,
    options: QuickfixOptions,
};

const DAEMON_REQ_BEGIN = "@@ZQF_BEGIN";
const DAEMON_REQ_END = "@@ZQF_END";
const DAEMON_RES_BEGIN = "@@ZQF_RES_BEGIN";
const DAEMON_RES_END = "@@ZQF_RES_END";
const DAEMON_MAX_LINE = 16 * 1024 * 1024;

const LineRing = struct {
    allocator: std.mem.Allocator,
    slots: []?[]u8,
    max_lines: usize,
    len: usize = 0,
    write_index: usize = 0,
    total_seen: usize = 0,

    fn init(allocator: std.mem.Allocator, max_lines: usize) !LineRing {
        const safe_max = if (max_lines == 0) 1 else max_lines;
        const slots = try allocator.alloc(?[]u8, safe_max);
        for (slots) |*slot| {
            slot.* = null;
        }
        return .{
            .allocator = allocator,
            .slots = slots,
            .max_lines = safe_max,
        };
    }

    fn deinit(self: *LineRing) void {
        for (self.slots) |slot| {
            if (slot) |line| {
                self.allocator.free(line);
            }
        }
        self.allocator.free(self.slots);
    }

    fn push(self: *LineRing, line: []const u8) !void {
        self.total_seen += 1;
        const dup = try self.allocator.dupe(u8, line);
        if (self.slots[self.write_index]) |old| {
            self.allocator.free(old);
        }
        self.slots[self.write_index] = dup;
        self.write_index = (self.write_index + 1) % self.max_lines;
        if (self.len < self.max_lines) {
            self.len += 1;
        }
    }

    fn at(self: LineRing, idx: usize) []const u8 {
        const start_idx = if (self.len == self.max_lines) self.write_index else 0;
        const slot_idx = (start_idx + idx) % self.max_lines;
        return self.slots[slot_idx].?;
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    if (hasFlag(args[1..], "--quickfix-daemon")) {
        try runQuickfixDaemon(allocator);
        return;
    }

    if (hasFlag(args[1..], "--quickfix")) {
        const options = parseQuickfixArgs(args[1..]) catch |err| {
            std.log.err("Invalid quickfix options: {}", .{err});
            std.process.exit(1);
        };
        try runQuickfixMode(allocator, options);
        return;
    }

    try runCommandMode(allocator, args);
}

fn printUsage() void {
    std.log.err(
        \\Usage:
        \\  zignite [--timeout=MS] <full command string>
        \\  zignite [--timeout=MS] --argv <program> [args...]
        \\  zignite --quickfix [--max-lines=N] [--max-bytes=N] [--strip-ansi=0|1]
        \\                    [--strip-max-lines=N] [--parse-diagnostics=0|1]
        \\  zignite --quickfix-daemon
    , .{});
}

fn hasFlag(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) {
            return true;
        }
    }
    return false;
}

fn runCommandMode(allocator: std.mem.Allocator, args: []const []const u8) !void {
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

fn runQuickfixMode(allocator: std.mem.Allocator, options: QuickfixOptions) !void {
    var truncated = false;
    const input = try readStdinCapped(allocator, options.max_bytes, &truncated);
    defer allocator.free(input);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try processQuickfixPayload(allocator, input, options, truncated, stdout);
}

fn runQuickfixDaemon(allocator: std.mem.Allocator) !void {
    var reader = std.fs.File.stdin().deprecatedReader();
    var stdout = std.fs.File.stdout().deprecatedWriter();

    while (true) {
        const maybe_begin = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', DAEMON_MAX_LINE);
        if (maybe_begin == null) {
            break;
        }

        const begin_owned = maybe_begin.?;
        defer allocator.free(begin_owned);
        const begin_line = stripTrailingCR(begin_owned);

        if (!std.mem.startsWith(u8, begin_line, DAEMON_REQ_BEGIN)) {
            continue;
        }

        const header = parseDaemonBegin(begin_line) catch continue;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(allocator);
        var payload_writer = payload.writer(allocator);
        var completed = false;

        while (true) {
            const maybe_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', DAEMON_MAX_LINE);
            if (maybe_line == null) {
                break;
            }

            const line_owned = maybe_line.?;
            defer allocator.free(line_owned);
            const line = stripTrailingCR(line_owned);

            if (isDaemonEndLine(line, header.request_id)) {
                completed = true;
                break;
            }

            const content = if (line.len > 0 and line[0] == '\t') line[1..] else line;
            try payload_writer.writeAll(content);
            try payload_writer.writeByte('\n');
        }

        if (!completed) {
            break;
        }

        var out_buf: std.ArrayList(u8) = .empty;
        defer out_buf.deinit(allocator);
        const out_writer = out_buf.writer(allocator);
        try processQuickfixPayload(allocator, payload.items, header.options, false, out_writer);

        try stdout.print("{s} {d}\n", .{ DAEMON_RES_BEGIN, header.request_id });
        var split = std.mem.splitScalar(u8, out_buf.items, '\n');
        while (split.next()) |line| {
            if (line.len == 0) {
                continue;
            }
            try stdout.writeByte('\t');
            try stdout.writeAll(line);
            try stdout.writeByte('\n');
        }
        try stdout.print("{s} {d}\n", .{ DAEMON_RES_END, header.request_id });
    }
}

fn processQuickfixPayload(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: QuickfixOptions,
    already_truncated: bool,
    writer: anytype,
) !void {
    var truncated = already_truncated;
    var effective_input = input;
    if (effective_input.len > options.max_bytes) {
        effective_input = effective_input[0..options.max_bytes];
        truncated = true;
    }

    var ring = try LineRing.init(allocator, options.max_lines);
    defer ring.deinit();

    try splitLinesIntoRing(&ring, effective_input);

    const overflow_lines = ring.total_seen > options.max_lines;
    const is_truncated = truncated or overflow_lines;

    if (is_truncated) {
        try writer.writeAll("[zignite] quickfix output truncated\n");
    }

    const strip_enabled = options.strip_ansi and options.strip_max_lines > 0;
    var strip_from_idx: usize = ring.len;
    if (strip_enabled) {
        strip_from_idx = if (options.strip_max_lines >= ring.len) 0 else ring.len - options.strip_max_lines;
    }

    var i: usize = 0;
    while (i < ring.len) : (i += 1) {
        const original_line = ring.at(i);
        var tmp_line: ?[]u8 = null;
        var line_view: []const u8 = original_line;

        if (strip_enabled and i >= strip_from_idx) {
            tmp_line = try stripAnsiAlloc(allocator, original_line);
            line_view = tmp_line.?;
        }

        const maybe_diag = if (options.parse_diagnostics) try canonicalizeDiagnostic(allocator, line_view) else null;
        if (maybe_diag) |diag| {
            try writer.writeAll(diag);
            try writer.writeByte('\n');
            allocator.free(diag);
        } else {
            try writer.writeAll(line_view);
            try writer.writeByte('\n');
        }

        if (tmp_line) |owned| {
            allocator.free(owned);
        }
    }
}

fn parseDaemonBegin(line: []const u8) !DaemonRequestHeader {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return error.InvalidDaemonHeader;
    if (!std.mem.eql(u8, marker, DAEMON_REQ_BEGIN)) {
        return error.InvalidDaemonHeader;
    }

    const request_id = try std.fmt.parseInt(u64, it.next() orelse return error.InvalidDaemonHeader, 10);
    const max_lines = try parseNonZeroInt(it.next() orelse return error.InvalidDaemonHeader);
    const max_bytes = try parseNonZeroInt(it.next() orelse return error.InvalidDaemonHeader);
    const strip_ansi = try parseBool(it.next() orelse return error.InvalidDaemonHeader);
    const strip_max_lines = try parseNonZeroInt(it.next() orelse return error.InvalidDaemonHeader);
    const parse_diagnostics = try parseBool(it.next() orelse return error.InvalidDaemonHeader);
    if (it.next() != null) {
        return error.InvalidDaemonHeader;
    }

    return .{
        .request_id = request_id,
        .options = .{
            .max_lines = max_lines,
            .max_bytes = max_bytes,
            .strip_ansi = strip_ansi,
            .strip_max_lines = strip_max_lines,
            .parse_diagnostics = parse_diagnostics,
        },
    };
}

fn isDaemonEndLine(line: []const u8, request_id: u64) bool {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return false;
    if (!std.mem.eql(u8, marker, DAEMON_REQ_END)) {
        return false;
    }

    const raw_id = it.next() orelse return false;
    if (it.next() != null) {
        return false;
    }
    const parsed = std.fmt.parseInt(u64, raw_id, 10) catch return false;
    return parsed == request_id;
}

fn stripTrailingCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

fn parseQuickfixArgs(args: []const []const u8) !QuickfixOptions {
    var options = QuickfixOptions{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--quickfix")) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "--max-lines=")) {
            options.max_lines = try parseNonZeroInt(arg["--max-lines=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--max-bytes=")) {
            options.max_bytes = try parseNonZeroInt(arg["--max-bytes=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--strip-ansi=")) {
            options.strip_ansi = try parseBool(arg["--strip-ansi=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--strip-max-lines=")) {
            options.strip_max_lines = try parseNonZeroInt(arg["--strip-max-lines=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--parse-diagnostics=")) {
            options.parse_diagnostics = try parseBool(arg["--parse-diagnostics=".len..]);
        } else {
            return error.InvalidQuickfixFlag;
        }
    }

    return options;
}

fn parseNonZeroInt(value: []const u8) !usize {
    const parsed = try std.fmt.parseInt(usize, value, 10);
    return if (parsed == 0) 1 else parsed;
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true")) {
        return true;
    }
    if (std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false")) {
        return false;
    }
    return error.InvalidBoolean;
}

fn readStdinCapped(allocator: std.mem.Allocator, max_bytes: usize, truncated: *bool) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    var reader = std.fs.File.stdin().deprecatedReader();
    var buf: [8192]u8 = undefined;

    while (true) {
        const n = try reader.read(&buf);
        if (n == 0) {
            break;
        }

        if (list.items.len < max_bytes) {
            const remaining = max_bytes - list.items.len;
            const take = @min(remaining, n);
            try list.appendSlice(allocator, buf[0..take]);
            if (take < n) {
                truncated.* = true;
            }
        } else {
            truncated.* = true;
        }
    }

    return try list.toOwnedSlice(allocator);
}

fn splitLinesIntoRing(ring: *LineRing, input: []const u8) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\n') {
            var line = input[start..i];
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }
            if (line.len > 0) {
                try ring.push(line);
            }
            start = i + 1;
        }
    }

    if (start < input.len) {
        var tail = input[start..];
        if (tail.len > 0 and tail[tail.len - 1] == '\r') {
            tail = tail[0 .. tail.len - 1];
        }
        if (tail.len > 0) {
            try ring.push(tail);
        }
    }
}

fn stripAnsiAlloc(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            i += 2;
            while (i < line.len) : (i += 1) {
                const ch = line[i];
                if (ch >= 0x40 and ch <= 0x7e) {
                    i += 1;
                    break;
                }
            }
            continue;
        }

        try out.append(allocator, line[i]);
        i += 1;
    }

    return try out.toOwnedSlice(allocator);
}

fn canonicalizeDiagnostic(allocator: std.mem.Allocator, line: []const u8) !?[]u8 {
    var trimmed = trimSpaces(line);
    if (trimmed.len == 0) {
        return null;
    }

    if (std.mem.startsWith(u8, trimmed, "-->")) {
        trimmed = trimSpaces(trimmed[3..]);
    }

    if (try parseParenDiagnostic(allocator, trimmed)) |diag| {
        return diag;
    }
    if (try parseColonDiagnostic(allocator, trimmed)) |diag| {
        return diag;
    }

    return null;
}

fn parseColonDiagnostic(allocator: std.mem.Allocator, line: []const u8) !?[]u8 {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != ':') {
            continue;
        }

        const line_start = i + 1;
        var j = line_start;
        while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) {}
        if (j == line_start or j >= line.len or line[j] != ':') {
            continue;
        }

        const line_no = std.fmt.parseInt(usize, line[line_start..j], 10) catch continue;
        const path = trimSpaces(line[0..i]);
        if (path.len == 0 or std.mem.indexOfAny(u8, path, "/\\.") == null) {
            continue;
        }

        const after_line = j + 1;
        var k = after_line;
        while (k < line.len and std.ascii.isDigit(line[k])) : (k += 1) {}

        var col_no: usize = 1;
        var msg_start = after_line;
        if (k > after_line and k < line.len and line[k] == ':') {
            col_no = std.fmt.parseInt(usize, line[after_line..k], 10) catch 1;
            msg_start = k + 1;
        }

        const msg = trimSpaces(line[msg_start..]);
        const normalized_msg = if (msg.len == 0) "diagnostic" else msg;
        return try std.fmt.allocPrint(allocator, "{s}:{d}:{d}: {s}", .{ path, line_no, col_no, normalized_msg });
    }
    return null;
}

fn parseParenDiagnostic(allocator: std.mem.Allocator, line: []const u8) !?[]u8 {
    const open_idx = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const colon_idx = std.mem.indexOfScalarPos(u8, line, open_idx + 1, ':') orelse return null;
    const close_idx = std.mem.indexOfScalarPos(u8, line, colon_idx + 1, ')') orelse return null;

    const path = trimSpaces(line[0..open_idx]);
    if (path.len == 0 or std.mem.indexOfAny(u8, path, "/\\.") == null) {
        return null;
    }

    const line_no = std.fmt.parseInt(usize, line[open_idx + 1 .. colon_idx], 10) catch return null;
    const col_no = std.fmt.parseInt(usize, line[colon_idx + 1 .. close_idx], 10) catch return null;
    const msg = trimSpaces(line[close_idx + 1 ..]);
    const normalized_msg = if (msg.len == 0) "diagnostic" else msg;

    return try std.fmt.allocPrint(allocator, "{s}:{d}:{d}: {s}", .{ path, line_no, col_no, normalized_msg });
}

fn trimSpaces(input: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = input.len;
    while (start < end and std.ascii.isWhitespace(input[start])) : (start += 1) {}
    while (end > start and std.ascii.isWhitespace(input[end - 1])) : (end -= 1) {}
    return input[start..end];
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
