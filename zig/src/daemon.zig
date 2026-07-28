const std = @import("std");
const builtin = @import("builtin");
const dispatch = @import("dispatch.zig");
const frame = @import("protocol/frame.zig");
const protocol_stdio = @import("protocol/stdio.zig");

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

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    while (true) {
        defer _ = arena.reset(.retain_capacity);
        const arena_alloc = arena.allocator();

        if (shutdown_requested.load(.acquire)) break;
        const maybe_line = try frame.readLineAlloc(arena_alloc, reader, FRAME_HEADER_MAX_LINE);
        if (maybe_line == null) break;
        const line_owned = maybe_line.?;
        const line = frame.stripTrailingCR(line_owned);
        if (line.len == 0) continue;

        if (try dispatch.handleDaemonLine(arena_alloc, io, environ_map, reader, stdout, line)) {
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

test "runWithIO health endpoint responds to ping" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "@@ZHLT_REQ_BEGIN 1",
        "@@ZHLT_REQ_END 1",
    } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try runWithIO(allocator, std.testing.io, null, &reader, &out.writer);

    try std.testing.expect(std.mem.find(u8, out.written(), "@@ZHLT_RES_BEGIN 1\n@@ZHLT_RES_END 1\n") != null);
}

test "runWithIO health endpoint returns correct request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "@@ZHLT_REQ_BEGIN 42",
        "@@ZHLT_REQ_END 42",
    } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try runWithIO(allocator, std.testing.io, null, &reader, &out.writer);

    try std.testing.expect(std.mem.find(u8, out.written(), "@@ZHLT_RES_BEGIN 42\n") != null);
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
