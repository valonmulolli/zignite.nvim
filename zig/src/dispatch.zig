const std = @import("std");
const build_action = @import("build/action.zig");
const build_resolve = @import("build/resolve.zig");
const config = @import("config.zig");
const daemon = @import("daemon.zig");
const detect = @import("detect.zig");
const frame = @import("protocol/frame.zig");
const project = @import("project.zig");
const quickfix = @import("quickfix.zig");
const run_resolve = @import("runtime/resolve.zig");

// ── Protocol marker constants ──────────────────────────
pub const DETECT_REQ_BEGIN = "@@ZDET_REQ_BEGIN";
pub const DETECT_RES_BEGIN = "@@ZDET_RES_BEGIN";
pub const DETECT_RES_END = "@@ZDET_RES_END";
pub const DETECT_RES_ERR = "@@ZDET_RES_ERR";

pub const PROJECT_REQ_BEGIN = "@@ZPRJ_REQ_BEGIN";
pub const PROJECT_RES_BEGIN = "@@ZPRJ_RES_BEGIN";
pub const PROJECT_RES_END = "@@ZPRJ_RES_END";
pub const PROJECT_RES_ERR = "@@ZPRJ_RES_ERR";

pub const CONFIG_REQ_BEGIN = "@@ZCFG_REQ_BEGIN";
pub const CONFIG_RES_BEGIN = "@@ZCFG_RES_BEGIN";
pub const CONFIG_RES_END = "@@ZCFG_RES_END";
pub const CONFIG_RES_ERR = "@@ZCFG_RES_ERR";

pub const BUILD_RESOLVE_REQ_BEGIN = "@@ZBR_REQ_BEGIN";
pub const BUILD_RESOLVE_RES_BEGIN = "@@ZBR_RES_BEGIN";
pub const BUILD_RESOLVE_RES_END = "@@ZBR_RES_END";
pub const BUILD_RESOLVE_RES_ERR = "@@ZBR_RES_ERR";

pub const BUILD_ACTION_REQ_BEGIN = "@@ZBA_REQ_BEGIN";
pub const BUILD_ACTION_RES_BEGIN = "@@ZBA_RES_BEGIN";
pub const BUILD_ACTION_RES_END = "@@ZBA_RES_END";
pub const BUILD_ACTION_RES_ERR = "@@ZBA_RES_ERR";

pub const RUN_RESOLVE_REQ_BEGIN = "@@ZRUN_REQ_BEGIN";
pub const RUN_RESOLVE_RES_BEGIN = "@@ZRUN_RES_BEGIN";
pub const RUN_RESOLVE_RES_END = "@@ZRUN_RES_END";
pub const RUN_RESOLVE_RES_ERR = "@@ZRUN_RES_ERR";

pub const QUICKFIX_REQ_BEGIN = "@@ZQF_BEGIN";
pub const HEALTH_REQ_BEGIN = "@@ZHLT_REQ_BEGIN";
pub const HEALTH_RES_BEGIN = "@@ZHLT_RES_BEGIN";
pub const HEALTH_RES_END = "@@ZHLT_RES_END";
pub const HEALTH_RES_ERR = "@@ZHLT_RES_ERR";

// ── CLI dispatch ───────────────────────────────────────
// Returns true when args matched a known flag and the CLI mode was
// dispatched (the caller should return).  Returns false when no flag
// matched, so the caller can fall back to command.run().

pub fn handleCliFlags(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    args: []const []const u8,
) !bool {
    if (hasFlag(args, "--daemon")) {
        try daemon.run(allocator, io, environ_map);
        return true;
    }
    if (hasFlag(args, "--config-sync")) {
        const options = config.parseArgs(args) catch |err| {
            std.log.err("Invalid config-sync options: {}", .{err});
            std.process.exit(1);
        };
        try config.runMode(allocator, io, options);
        return true;
    }
    if (hasFlag(args, "--quickfix-daemon")) {
        try quickfix.runDaemon(allocator, io);
        return true;
    }
    if (hasFlag(args, "--detect-daemon")) {
        try detect.runDaemon(allocator, io);
        return true;
    }
    if (hasFlag(args, "--project-parse-daemon")) {
        try project.runDaemon(allocator, io);
        return true;
    }
    if (hasFlag(args, "--quickfix")) {
        const options = quickfix.parseArgs(args) catch |err| {
            std.log.err("Invalid quickfix options: {}", .{err});
            std.process.exit(1);
        };
        try quickfix.runMode(allocator, io, options);
        return true;
    }
    if (hasFlag(args, "--detect")) {
        const options = detect.parseArgs(args) catch |err| {
            std.log.err("Invalid detect options: {}", .{err});
            std.process.exit(1);
        };
        try detect.runMode(allocator, io, options);
        return true;
    }
    if (hasFlag(args, "--project-parse")) {
        const options = project.parseArgs(args) catch |err| {
            std.log.err("Invalid project-parse options: {}", .{err});
            std.process.exit(1);
        };
        try project.runMode(allocator, io, options);
        return true;
    }
    if (hasFlag(args, "--build-resolve")) {
        const options = build_resolve.parseArgs(args) catch |err| {
            std.log.err("Invalid build-resolve options: {}", .{err});
            std.process.exit(1);
        };
        try build_resolve.runModeWithEnviron(allocator, io, environ_map, options);
        return true;
    }
    if (hasFlag(args, "--build-action")) {
        const options = build_action.parseArgs(args) catch |err| {
            std.log.err("Invalid build-action options: {}", .{err});
            std.process.exit(1);
        };
        try build_action.runModeWithEnviron(allocator, io, environ_map, options);
        return true;
    }
    if (hasFlag(args, "--run-resolve")) {
        const options = run_resolve.parseArgs(args) catch |err| {
            std.log.err("Invalid run-resolve options: {}", .{err});
            std.process.exit(1);
        };
        try run_resolve.runMode(allocator, io, environ_map, options);
        return true;
    }
    return false;
}

// ── Daemon dispatch ────────────────────────────────────
// Returns true when the incoming line matched a known protocol marker
// and was dispatched.  Returns false when the line is unrecognised.
// The caller owns the arena and should handle UnexpectedEof at the loop
// level if desired.

pub fn handleDaemonLine(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    reader: anytype,
    stdout: anytype,
    line: []const u8,
) !bool {
    if (std.mem.startsWith(u8, line, QUICKFIX_REQ_BEGIN)) {
        quickfix.handleDaemonFrame(allocator, reader, stdout, line) catch |err| {
            if (err == error.UnexpectedEof) return err;
            if (frame.parseRequestId(line, QUICKFIX_REQ_BEGIN)) |request_id| {
                try quickfix.writeDaemonResponse(stdout, request_id, "", err);
                try stdout.flush();
            }
        };
        return true;
    }
    if (std.mem.startsWith(u8, line, DETECT_REQ_BEGIN)) {
        detect.handleDaemonFrame(allocator, io, reader, stdout, line) catch |err| {
            try frame.handleDispatchError(
                err,
                stdout,
                line,
                DETECT_REQ_BEGIN,
                .{ .response_begin = DETECT_RES_BEGIN, .response_err = DETECT_RES_ERR, .response_end = DETECT_RES_END },
            );
        };
        return true;
    }
    if (std.mem.startsWith(u8, line, PROJECT_REQ_BEGIN)) {
        project.handleDaemonFrame(allocator, io, reader, stdout, line) catch |err| {
            try frame.handleDispatchError(
                err,
                stdout,
                line,
                PROJECT_REQ_BEGIN,
                .{ .response_begin = PROJECT_RES_BEGIN, .response_err = PROJECT_RES_ERR, .response_end = PROJECT_RES_END },
            );
        };
        return true;
    }
    if (std.mem.startsWith(u8, line, CONFIG_REQ_BEGIN)) {
        config.handleDaemonFrame(allocator, reader, stdout, line) catch |err| {
            try frame.handleDispatchError(
                err,
                stdout,
                line,
                CONFIG_REQ_BEGIN,
                .{ .response_begin = CONFIG_RES_BEGIN, .response_err = CONFIG_RES_ERR, .response_end = CONFIG_RES_END },
            );
        };
        return true;
    }
    if (std.mem.startsWith(u8, line, BUILD_RESOLVE_REQ_BEGIN)) {
        build_resolve.handleDaemonFrame(allocator, io, environ_map, reader, stdout, line) catch |err| {
            try frame.handleDispatchError(
                err,
                stdout,
                line,
                BUILD_RESOLVE_REQ_BEGIN,
                .{ .response_begin = BUILD_RESOLVE_RES_BEGIN, .response_err = BUILD_RESOLVE_RES_ERR, .response_end = BUILD_RESOLVE_RES_END },
            );
        };
        return true;
    }
    if (std.mem.startsWith(u8, line, BUILD_ACTION_REQ_BEGIN)) {
        build_action.handleDaemonFrame(allocator, io, environ_map, reader, stdout, line) catch |err| {
            try frame.handleDispatchError(
                err,
                stdout,
                line,
                BUILD_ACTION_REQ_BEGIN,
                .{ .response_begin = BUILD_ACTION_RES_BEGIN, .response_err = BUILD_ACTION_RES_ERR, .response_end = BUILD_ACTION_RES_END },
            );
        };
        return true;
    }
    if (std.mem.startsWith(u8, line, RUN_RESOLVE_REQ_BEGIN)) {
        run_resolve.handleDaemonFrame(allocator, io, environ_map, reader, stdout, line) catch |err| {
            try frame.handleDispatchError(
                err,
                stdout,
                line,
                RUN_RESOLVE_REQ_BEGIN,
                .{ .response_begin = RUN_RESOLVE_RES_BEGIN, .response_err = RUN_RESOLVE_RES_ERR, .response_end = RUN_RESOLVE_RES_END },
            );
        };
        return true;
    }
    if (std.mem.startsWith(u8, line, HEALTH_REQ_BEGIN)) {
        if (frame.parseRequestId(line, HEALTH_REQ_BEGIN)) |request_id| {
            try stdout.print("{s} {d}\n{s} {d}\n", .{
                HEALTH_RES_BEGIN, request_id,
                HEALTH_RES_END,   request_id,
            });
            try stdout.flush();
        }
        return true;
    }
    return false;
}

// ── Helpers ─────────────────────────────────────────────

fn hasFlag(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) {
            return true;
        }
    }
    return false;
}

// ── Tests ───────────────────────────────────────────────

const TestReader = frame.TestReader;

test "handleDaemonLine health endpoint responds to ping" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{} };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    _ = try handleDaemonLine(allocator, std.testing.io, null, &reader, &out.writer, "@@ZHLT_REQ_BEGIN 1");

    try std.testing.expect(std.mem.find(u8, out.written(), "@@ZHLT_RES_BEGIN 1\n@@ZHLT_RES_END 1\n") != null);
}

test "handleDaemonLine returns false for unrecognised lines" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{} };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const handled = try handleDaemonLine(allocator, std.testing.io, null, &reader, &out.writer, "garbage line");

    try std.testing.expect(!handled);
}

test "handleDaemonLine returns quickfix error for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{} };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    _ = try handleDaemonLine(allocator, std.testing.io, null, &reader, &out.writer, "@@ZQF_BEGIN 7 100 2048 2 50 0");

    try std.testing.expect(std.mem.find(u8, out.written(), "@@ZQF_RES_BEGIN 7") != null);
}

test "handleDaemonLine returns detect error for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{} };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    _ = try handleDaemonLine(allocator, std.testing.io, null, &reader, &out.writer, "@@ZDET_REQ_BEGIN 9 nope");

    try std.testing.expect(std.mem.find(u8, out.written(), "@@ZDET_RES_BEGIN 9\n@@ZDET_RES_ERR 9 InvalidDetectTool\n@@ZDET_RES_END 9\n") != null);
}

test "handleDaemonLine returns config error for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{} };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    _ = try handleDaemonLine(allocator, std.testing.io, null, &reader, &out.writer, "@@ZCFG_REQ_BEGIN 4 nope");

    try std.testing.expect(std.mem.find(u8, out.written(), "@@ZCFG_RES_BEGIN 4\n@@ZCFG_RES_ERR 4 InvalidCharacter\n@@ZCFG_RES_END 4\n") != null);
}

test "handleDaemonLine returns project error for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{} };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    _ = try handleDaemonLine(allocator, std.testing.io, null, &reader, &out.writer, "@@ZPRJ_REQ_BEGIN 3 notavalidmarker /path");

    try std.testing.expect(std.mem.find(u8, out.written(), "@@ZPRJ_RES_BEGIN 3\n@@ZPRJ_RES_ERR 3 InvalidProjectDaemonHeader\n@@ZPRJ_RES_END 3\n") != null);
}

test "handleDaemonLine returns build_resolve error for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "@@ZBR_REQ_END 5",
    } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    _ = try handleDaemonLine(allocator, std.testing.io, null, &reader, &out.writer, "@@ZBR_REQ_BEGIN 5");

    try std.testing.expect(std.mem.find(u8, out.written(), "@@ZBR_RES_BEGIN 5\n@@ZBR_RES_ERR 5 MissingBuildResolvePath\n@@ZBR_RES_END 5\n") != null);
}

test "handleDaemonLine returns build_action error for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "@@ZBA_REQ_END 6",
    } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    _ = try handleDaemonLine(allocator, std.testing.io, null, &reader, &out.writer, "@@ZBA_REQ_BEGIN 6");

    try std.testing.expect(std.mem.find(u8, out.written(), "@@ZBA_RES_BEGIN 6\n@@ZBA_RES_ERR 6") != null);
}

test "handleDaemonLine returns run_resolve error for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "@@ZRUN_REQ_END 8",
    } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    _ = try handleDaemonLine(allocator, std.testing.io, null, &reader, &out.writer, "@@ZRUN_REQ_BEGIN 8");

    try std.testing.expect(std.mem.find(u8, out.written(), "@@ZRUN_RES_BEGIN 8\n@@ZRUN_RES_ERR 8") != null);
}
