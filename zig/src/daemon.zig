const std = @import("std");
const builtin = @import("builtin");
const build_action = @import("build/action.zig");
const build_resolve = @import("build/resolve.zig");
const config = @import("config.zig");
const detect = @import("detect.zig");
const frame = @import("protocol/frame.zig");
const protocol_stdio = @import("protocol/stdio.zig");
const project = @import("project.zig");
const quickfix = @import("quickfix.zig");
const run_resolve = @import("runtime/resolve.zig");

const DETECT_REQ_BEGIN = "@@ZDET_REQ_BEGIN";
const DETECT_RES_BEGIN = "@@ZDET_RES_BEGIN";
const DETECT_RES_END = "@@ZDET_RES_END";
const DETECT_RES_ERR = "@@ZDET_RES_ERR";

const PROJECT_REQ_BEGIN = "@@ZPRJ_REQ_BEGIN";
const PROJECT_RES_BEGIN = "@@ZPRJ_RES_BEGIN";
const PROJECT_RES_END = "@@ZPRJ_RES_END";
const PROJECT_RES_ERR = "@@ZPRJ_RES_ERR";

const CONFIG_REQ_BEGIN = "@@ZCFG_REQ_BEGIN";
const CONFIG_RES_BEGIN = "@@ZCFG_RES_BEGIN";
const CONFIG_RES_END = "@@ZCFG_RES_END";
const CONFIG_RES_ERR = "@@ZCFG_RES_ERR";

const BUILD_RESOLVE_REQ_BEGIN = "@@ZBR_REQ_BEGIN";
const BUILD_RESOLVE_RES_BEGIN = "@@ZBR_RES_BEGIN";
const BUILD_RESOLVE_RES_END = "@@ZBR_RES_END";
const BUILD_RESOLVE_RES_ERR = "@@ZBR_RES_ERR";

const BUILD_ACTION_REQ_BEGIN = "@@ZBA_REQ_BEGIN";
const BUILD_ACTION_RES_BEGIN = "@@ZBA_RES_BEGIN";
const BUILD_ACTION_RES_END = "@@ZBA_RES_END";
const BUILD_ACTION_RES_ERR = "@@ZBA_RES_ERR";

const RUN_RESOLVE_REQ_BEGIN = "@@ZRUN_REQ_BEGIN";
const RUN_RESOLVE_RES_BEGIN = "@@ZRUN_RES_BEGIN";
const RUN_RESOLVE_RES_END = "@@ZRUN_RES_END";
const RUN_RESOLVE_RES_ERR = "@@ZRUN_RES_ERR";

const QUICKFIX_REQ_BEGIN = "@@ZQF_BEGIN";
const FRAME_HEADER_MAX_LINE = 4096;
var shutdown_requested = std.atomic.Value(bool).init(false);
var signal_handlers_installed = false;

pub fn run(allocator: std.mem.Allocator, io: std.Io, environ_map: ?*const std.process.Environ.Map) !void {
    var stdin_ctx: protocol_stdio.Stdin = .{};
    stdin_ctx.init(io);
    const reader = stdin_ctx.io();
    var stdout_ctx: protocol_stdio.Stdout = .{};
    stdout_ctx.init(io);
    const stdout = stdout_ctx.io();

    try runWithIO(allocator, io, environ_map, reader, stdout);
}

pub fn runWithIO(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    reader: anytype,
    stdout: anytype,
) !void {
    installShutdownSignalHandlers();
    defer shutdown_requested.store(false, .seq_cst);

    while (true) {
        if (shutdown_requested.load(.acquire)) break;
        const maybe_line = try frame.readLineAlloc(allocator, reader, FRAME_HEADER_MAX_LINE);
        if (maybe_line == null) break;
        const line_owned = maybe_line.?;
        defer allocator.free(line_owned);
        const line = frame.stripTrailingCR(line_owned);
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, QUICKFIX_REQ_BEGIN)) {
            quickfix.handleDaemonFrame(allocator, reader, stdout, line) catch |err| {
                if (err == error.UnexpectedEof) return err;
                if (frame.parseRequestId(line, QUICKFIX_REQ_BEGIN)) |request_id| {
                    try quickfix.writeDaemonResponse(stdout, request_id, "", err);
                    try stdout.flush();
                }
            };
            continue;
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
            continue;
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
            continue;
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
            continue;
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
            continue;
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
            continue;
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
            continue;
        }
    }
}

fn installShutdownSignalHandlers() void {
    if (signal_handlers_installed) return;
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const posix = std.posix;
    const act: posix.Sigaction = .{
        .handler = .{ .handler = handleShutdownSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
    signal_handlers_installed = true;
}

fn handleShutdownSignal(_: std.posix.SIG) callconv(.c) void {
    shutdown_requested.store(true, .release);
}

const TestReader = frame.TestReader;

test "runWithIO writes quickfix error frame for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "@@ZQF_BEGIN 7 100 2048 2 50 0",
        "@@ZQF_END 7",
    } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try runWithIO(allocator, std.testing.io, null, &reader, &out.writer);

    try std.testing.expectEqualStrings(
        "@@ZQF_RES_BEGIN 7\n@@ZQF_RES_ERR 7 InvalidBoolean\n@@ZQF_RES_END 7\n",
        out.written(),
    );
}

test "runWithIO exits early when shutdown requested" {
    const allocator = std.testing.allocator;
    shutdown_requested.store(true, .seq_cst);
    defer shutdown_requested.store(false, .seq_cst);

    var reader = TestReader{ .lines = &.{
        "@@ZDET_REQ_BEGIN 9 cargo",
        "@@ZDET_REQ_END 9",
    } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try runWithIO(allocator, std.testing.io, null, &reader, &out.writer);
    try std.testing.expectEqualStrings("", out.written());
}

test "runWithIO writes detect error frame for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "@@ZDET_REQ_BEGIN 9 nope",
        "@@ZDET_REQ_END 9",
    } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try runWithIO(allocator, std.testing.io, null, &reader, &out.writer);

    try std.testing.expectEqualStrings(
        "@@ZDET_RES_BEGIN 9\n@@ZDET_RES_ERR 9 InvalidDetectTool\n@@ZDET_RES_END 9\n",
        out.written(),
    );
}

test "runWithIO writes config error frame for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "@@ZCFG_REQ_BEGIN 4 nope",
        "@@ZCFG_REQ_END 4",
    } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try runWithIO(allocator, std.testing.io, null, &reader, &out.writer);

    try std.testing.expectEqualStrings(
        "@@ZCFG_RES_BEGIN 4\n@@ZCFG_RES_ERR 4 InvalidCharacter\n@@ZCFG_RES_END 4\n",
        out.written(),
    );
}

test "runWithIO syncs config and resolves build commands through daemon" {
    const allocator = std.testing.allocator;
    defer @import("config/store.zig").reset();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "CMakeLists.txt", .data = "project(demo)\nadd_executable(demo main.cpp)\n" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "main.cpp" });
    defer allocator.free(filepath);

    const path_arg = try std.fmt.allocPrint(allocator, "\t--path={s}", .{filepath});
    defer allocator.free(path_arg);
    const root_arg = try std.fmt.allocPrint(allocator, "\t--project-root={s}", .{root});
    defer allocator.free(root_arg);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    try lines.appendSlice(allocator, &.{
        "@@ZCFG_REQ_BEGIN 1 11",
        "\t{\"build_commands\":{\"c\":{\"custom\":\"make custom\"}},\"detect\":{\"c_cpp_make\":true}}",
        "@@ZCFG_REQ_END 1",
        "@@ZBR_REQ_BEGIN 2",
        "\t--build-resolve",
        "\t--filetype=c",
    });
    try lines.append(allocator, path_arg);
    try lines.append(allocator, root_arg);
    try lines.append(allocator, "@@ZBR_REQ_END 2");

    var reader = TestReader{ .lines = try lines.toOwnedSlice(allocator) };
    defer allocator.free(reader.lines);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try runWithIO(allocator, std.testing.io, null, &reader, &out.writer);

    try std.testing.expect(std.mem.find(u8, out.written(), "@@ZCFG_RES_BEGIN 1\nREVISION\t11\n@@ZCFG_RES_END 1\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "@@ZBR_RES_BEGIN 2\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "CONFIG_REVISION\t11\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tcustom\tmake custom\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build\n") != null);
}

test "runWithIO writes project error frame for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "@@ZPRJ_REQ_BEGIN 3 notavalidmarker /path",
        "@@ZPRJ_REQ_END 3",
    } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try runWithIO(allocator, std.testing.io, null, &reader, &out.writer);

    try std.testing.expect(std.mem.find(u8, out.written(), "@@ZPRJ_RES_BEGIN 3\n@@ZPRJ_RES_ERR 3 InvalidProjectDaemonHeader\n@@ZPRJ_RES_END 3\n") != null);
}

test "runWithIO writes build_resolve error frame for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "@@ZBR_REQ_BEGIN 5",
        "@@ZBR_REQ_END 5",
    } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try runWithIO(allocator, std.testing.io, null, &reader, &out.writer);

    try std.testing.expect(std.mem.find(u8, out.written(), "@@ZBR_RES_BEGIN 5\n@@ZBR_RES_ERR 5 MissingBuildResolvePath\n@@ZBR_RES_END 5\n") != null);
}

test "runWithIO writes build_action error frame for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "@@ZBA_REQ_BEGIN 6",
        "@@ZBA_REQ_END 6",
    } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try runWithIO(allocator, std.testing.io, null, &reader, &out.writer);

    try std.testing.expect(std.mem.find(u8, out.written(), "@@ZBA_RES_BEGIN 6\n@@ZBA_RES_ERR 6") != null);
}

test "runWithIO writes run_resolve error frame for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "@@ZRUN_REQ_BEGIN 8",
        "@@ZRUN_REQ_END 8",
    } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try runWithIO(allocator, std.testing.io, null, &reader, &out.writer);

    try std.testing.expect(std.mem.find(u8, out.written(), "@@ZRUN_RES_BEGIN 8\n@@ZRUN_RES_ERR 8") != null);
}

test "runWithIO silently skips lines that match no dispatcher" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "garbage line with no marker",
        "@@ZDET_REQ_BEGIN 9 cargo",
        "@@ZDET_REQ_END 9",
    } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try runWithIO(allocator, std.testing.io, null, &reader, &out.writer);

    try std.testing.expect(std.mem.find(u8, out.written(), "garbage") == null);
    try std.testing.expect(std.mem.find(u8, out.written(), "@@ZDET_RES_BEGIN 9") != null);
}

test "runWithIO writes error when quickfix stream ends before close marker" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "@@ZQF_BEGIN 7 100 2048 2 50 0",
    } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try runWithIO(allocator, std.testing.io, null, &reader, &out.writer);

    try std.testing.expect(std.mem.find(u8, out.written(), "@@ZQF_RES_ERR 7") != null);
}

test "runWithIO does not error response when request id is unparseable" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "@@ZDET_REQ_BEGIN",
        "@@ZDET_REQ_END",
    } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try runWithIO(allocator, std.testing.io, null, &reader, &out.writer);

    try std.testing.expectEqualStrings("", out.written());
}
