const std = @import("std");
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

const RUN_RESOLVE_REQ_BEGIN = "@@ZRUN_REQ_BEGIN";
const RUN_RESOLVE_RES_BEGIN = "@@ZRUN_RES_BEGIN";
const RUN_RESOLVE_RES_END = "@@ZRUN_RES_END";
const RUN_RESOLVE_RES_ERR = "@@ZRUN_RES_ERR";

const QUICKFIX_REQ_BEGIN = "@@ZQF_BEGIN";
const QUICKFIX_MAX_LINE = 16 * 1024 * 1024;

pub fn run(allocator: std.mem.Allocator) !void {
    var stdin_ctx: protocol_stdio.Stdin = .{};
    stdin_ctx.init();
    const reader = stdin_ctx.io();
    var stdout_ctx: protocol_stdio.Stdout = .{};
    stdout_ctx.init();
    const stdout = stdout_ctx.io();

    try runWithIO(allocator, reader, stdout);
}

fn runWithIO(
    allocator: std.mem.Allocator,
    reader: anytype,
    stdout: anytype,
) !void {
    while (true) {
        const maybe_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', QUICKFIX_MAX_LINE);
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
            detect.handleDaemonFrame(allocator, reader, stdout, line) catch |err| {
                if (err == error.UnexpectedEof) return err;
                if (frame.parseRequestId(line, DETECT_REQ_BEGIN)) |request_id| {
                    try frame.writeErrorResponse(
                        stdout,
                        DETECT_RES_BEGIN,
                        DETECT_RES_ERR,
                        DETECT_RES_END,
                        request_id,
                        @errorName(err),
                    );
                    try stdout.flush();
                }
            };
            continue;
        }
        if (std.mem.startsWith(u8, line, PROJECT_REQ_BEGIN)) {
            project.handleDaemonFrame(allocator, reader, stdout, line) catch |err| {
                if (err == error.UnexpectedEof) return err;
                if (frame.parseRequestId(line, PROJECT_REQ_BEGIN)) |request_id| {
                    try frame.writeErrorResponse(
                        stdout,
                        PROJECT_RES_BEGIN,
                        PROJECT_RES_ERR,
                        PROJECT_RES_END,
                        request_id,
                        @errorName(err),
                    );
                    try stdout.flush();
                }
            };
            continue;
        }
        if (std.mem.startsWith(u8, line, CONFIG_REQ_BEGIN)) {
            config.handleDaemonFrame(allocator, reader, stdout, line) catch |err| {
                if (err == error.UnexpectedEof) return err;
                if (frame.parseRequestId(line, CONFIG_REQ_BEGIN)) |request_id| {
                    try frame.writeErrorResponse(
                        stdout,
                        CONFIG_RES_BEGIN,
                        CONFIG_RES_ERR,
                        CONFIG_RES_END,
                        request_id,
                        @errorName(err),
                    );
                    try stdout.flush();
                }
            };
            continue;
        }
        if (std.mem.startsWith(u8, line, BUILD_RESOLVE_REQ_BEGIN)) {
            build_resolve.handleDaemonFrame(allocator, reader, stdout, line) catch |err| {
                if (err == error.UnexpectedEof) return err;
                if (frame.parseRequestId(line, BUILD_RESOLVE_REQ_BEGIN)) |request_id| {
                    try frame.writeErrorResponse(
                        stdout,
                        BUILD_RESOLVE_RES_BEGIN,
                        BUILD_RESOLVE_RES_ERR,
                        BUILD_RESOLVE_RES_END,
                        request_id,
                        @errorName(err),
                    );
                    try stdout.flush();
                }
            };
            continue;
        }
        if (std.mem.startsWith(u8, line, RUN_RESOLVE_REQ_BEGIN)) {
            run_resolve.handleDaemonFrame(allocator, reader, stdout, line) catch |err| {
                if (err == error.UnexpectedEof) return err;
                if (frame.parseRequestId(line, RUN_RESOLVE_REQ_BEGIN)) |request_id| {
                    try frame.writeErrorResponse(
                        stdout,
                        RUN_RESOLVE_RES_BEGIN,
                        RUN_RESOLVE_RES_ERR,
                        RUN_RESOLVE_RES_END,
                        request_id,
                        @errorName(err),
                    );
                    try stdout.flush();
                }
            };
            continue;
        }
    }
}

const TestReader = struct {
    lines: []const []const u8,
    index: usize = 0,

    fn readUntilDelimiterOrEofAlloc(
        self: *TestReader,
        allocator: std.mem.Allocator,
        delimiter: u8,
        max_line: usize,
    ) !?[]u8 {
        _ = delimiter;
        if (self.index >= self.lines.len) return null;
        const line = self.lines[self.index];
        self.index += 1;
        if (line.len > max_line) return error.StreamTooLong;
        return try allocator.dupe(u8, line);
    }
};

test "runWithIO writes quickfix error frame for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "@@ZQF_BEGIN 7 100 2048 2 50 0",
        "@@ZQF_END 7",
    } };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try runWithIO(allocator, &reader, out.writer(allocator));

    try std.testing.expectEqualStrings(
        "@@ZQF_RES_BEGIN 7\n@@ZQF_RES_ERR 7 InvalidBoolean\n@@ZQF_RES_END 7\n",
        out.items,
    );
}

test "runWithIO writes detect error frame for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "@@ZDET_REQ_BEGIN 9 nope",
        "@@ZDET_REQ_END 9",
    } };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try runWithIO(allocator, &reader, out.writer(allocator));

    try std.testing.expectEqualStrings(
        "@@ZDET_RES_BEGIN 9\n@@ZDET_RES_ERR 9 InvalidDetectTool\n@@ZDET_RES_END 9\n",
        out.items,
    );
}

test "runWithIO writes config error frame for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "@@ZCFG_REQ_BEGIN 4 nope",
        "@@ZCFG_REQ_END 4",
    } };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try runWithIO(allocator, &reader, out.writer(allocator));

    try std.testing.expectEqualStrings(
        "@@ZCFG_RES_BEGIN 4\n@@ZCFG_RES_ERR 4 InvalidCharacter\n@@ZCFG_RES_END 4\n",
        out.items,
    );
}

test "runWithIO syncs config and resolves build commands through daemon" {
    const allocator = std.testing.allocator;
    defer @import("config/store.zig").reset();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "CMakeLists.txt", .data = "project(demo)\nadd_executable(demo main.cpp)\n" });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
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

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try runWithIO(allocator, &reader, out.writer(allocator));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "@@ZCFG_RES_BEGIN 1\nREVISION\t11\n@@ZCFG_RES_END 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "@@ZBR_RES_BEGIN 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "CONFIG_REVISION\t11\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tcustom\tmake custom\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbuild\tcmake --build build\n") != null);
}
