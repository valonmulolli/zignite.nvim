const std = @import("std");
const config_store = @import("../config/store.zig");
const protocol_args = @import("../protocol/args.zig");
const fixtures = @import("../test_support/fixtures.zig");
const frame = @import("../protocol/frame.zig");
const protocol_stdio = @import("../protocol/stdio.zig");
const protocol = @import("resolve/protocol.zig");
const runner = @import("resolve/runner.zig");
const serialize = @import("resolve/serialize.zig");
const source = @import("source.zig");
const types = @import("resolve/types.zig");

pub const Options = types.Options;
pub const ResolvedRunner = types.ResolvedRunner;
pub const resolveRunner = runner.resolveRunner;

pub const RUN_RESOLVE_REQ_BEGIN = protocol.RUN_RESOLVE_REQ_BEGIN;
pub const RUN_RESOLVE_REQ_PAYLOAD_BEGIN = protocol.RUN_RESOLVE_REQ_PAYLOAD_BEGIN;
pub const RUN_RESOLVE_REQ_PAYLOAD_END = protocol.RUN_RESOLVE_REQ_PAYLOAD_END;
pub const RUN_RESOLVE_REQ_END = protocol.RUN_RESOLVE_REQ_END;
pub const RUN_RESOLVE_RES_BEGIN = protocol.RUN_RESOLVE_RES_BEGIN;
pub const RUN_RESOLVE_RES_END = protocol.RUN_RESOLVE_RES_END;
pub const RUN_RESOLVE_RES_ERR = protocol.RUN_RESOLVE_RES_ERR;

pub fn parseArgs(args: []const []const u8) !Options {
    return parseArgsWithPayload(args, null);
}

fn parseArgsWithPayload(args: []const []const u8, selection_text: ?[]const u8) !Options {
    var common: protocol_args.CommonPathArgs = .{};
    var context_path: ?[]const u8 = null;
    var buffer_id: ?u32 = null;
    var input_kind: ?source.InputKind = null;

    for (args) |arg| {
        if (try protocol_args.parseCommonPathArg(&common, arg, "--run-resolve")) {
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--context-path=")) {
            context_path = arg["--context-path=".len..];
        } else if (std.mem.startsWith(u8, arg, "--buffer-id=")) {
            buffer_id = try std.fmt.parseInt(u32, arg["--buffer-id=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--input-kind=file")) {
            input_kind = .file;
        } else if (std.mem.eql(u8, arg, "--input-kind=selection")) {
            input_kind = .selection;
        } else if (std.mem.eql(u8, arg, "--input-kind=buffer")) {
            input_kind = .buffer;
        } else {
            return error.InvalidRunResolveFlag;
        }
    }

    const effective_input_kind = input_kind orelse blk: {
        if (selection_text != null) {
            const request_path = common.path orelse @as([]const u8, "");
            break :blk if (request_path.len == 0) source.InputKind.buffer else source.InputKind.selection;
        }
        break :blk source.InputKind.file;
    };

    switch (effective_input_kind) {
        .file => {
            if (selection_text != null) return error.UnexpectedRunResolvePayload;
        },
        .selection, .buffer => {
            const text = selection_text orelse return error.MissingSelectionPayload;
            if (text.len == 0) return error.MissingSelectionPayload;
        },
    }

    return .{
        .path = common.path orelse return error.MissingRunResolvePath,
        .filetype = common.filetype orelse return error.MissingRunResolveFiletype,
        .context_path = context_path,
        .project_root = common.project_root,
        .buffer_id = buffer_id,
        .input_kind = effective_input_kind,
        .selection_text = selection_text,
    };
}

pub fn runMode(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    options: Options,
) !void {
    var stdout_ctx: protocol_stdio.Stdout = .{};
    stdout_ctx.init(io);
    const stdout = stdout_ctx.io();
    try writeResolvedOutput(stdout, allocator, io, environ_map, options);
    try stdout.flush();
}

pub fn handleDaemonFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    reader: anytype,
    stdout: anytype,
    begin_line: []const u8,
) !void {
    const header = protocol.parseResolveDaemonBegin(begin_line) catch |err| {
        if (frame.parseRequestId(begin_line, RUN_RESOLVE_REQ_BEGIN)) |request_id| {
            try frame.writeErrorResponse(
                stdout,
                RUN_RESOLVE_RES_BEGIN,
                RUN_RESOLVE_RES_ERR,
                RUN_RESOLVE_RES_END,
                request_id,
                @errorName(err),
            );
            try stdout.flush();
            return;
        }
        return err;
    };

    const request = try collectRunResolveRequest(
        allocator,
        reader,
        header.request_id,
    );
    const request_args = request.args;
    defer {
        for (request_args) |arg| allocator.free(arg);
        allocator.free(request_args);
        if (request.selection_text) |selection_text| allocator.free(selection_text);
    }

    try stdout.print("{s} {d}\n", .{ RUN_RESOLVE_RES_BEGIN, header.request_id });
    const options = parseArgsWithPayload(request_args, request.selection_text);
    if (options) |parsed| {
        writeResolvedOutput(stdout, allocator, io, environ_map, parsed) catch |err| {
            try stdout.print("{s} {d} {s}\n", .{ RUN_RESOLVE_RES_ERR, header.request_id, @errorName(err) });
        };
    } else |err| {
        try stdout.print("{s} {d} {s}\n", .{ RUN_RESOLVE_RES_ERR, header.request_id, @errorName(err) });
    }
    try stdout.print("{s} {d}\n", .{ RUN_RESOLVE_RES_END, header.request_id });
    try stdout.flush();
}

fn writeResolvedOutput(
    stdout: anytype,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    options: Options,
) !void {
    var resolved = try resolveRunner(io, allocator, environ_map, options);
    defer resolved.deinit(allocator);

    const resolved_filetype = resolved.filetype orelse options.filetype;
    try serialize.writeResolvedOutputJson(stdout, allocator, io, resolved, resolved_filetype);
    try serialize.writeResolvedOutputLegacy(stdout, resolved, resolved_filetype);
}

const CollectedRunResolveRequest = struct {
    args: [][]u8,
    selection_text: ?[]u8 = null,
};

fn collectRunResolveRequest(
    allocator: std.mem.Allocator,
    reader: anytype,
    request_id: u64,
) !CollectedRunResolveRequest {
    var args: std.ArrayList([]u8) = .empty;
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }

    var payload_lines: std.ArrayList([]u8) = .empty;
    errdefer {
        for (payload_lines.items) |line| allocator.free(line);
        payload_lines.deinit(allocator);
    }

    var payload_started = false;
    var payload_completed = false;

    while (true) {
        const maybe_line = try frame.readLineAlloc(allocator, reader, protocol.RUN_RESOLVE_MAX_LINE);
        if (maybe_line == null) return error.UnexpectedEof;

        const line_owned = maybe_line.?;
        defer allocator.free(line_owned);
        const line = frame.stripTrailingCR(line_owned);

        if (frame.isFrameEndLine(line, RUN_RESOLVE_REQ_END, request_id)) {
            if (payload_started and !payload_completed) return error.InvalidRunResolvePayload;
            break;
        }
        if (frame.isFrameEndLine(line, RUN_RESOLVE_REQ_PAYLOAD_BEGIN, request_id)) {
            if (payload_started or payload_completed) return error.InvalidRunResolvePayload;
            payload_started = true;
            continue;
        }
        if (frame.isFrameEndLine(line, RUN_RESOLVE_REQ_PAYLOAD_END, request_id)) {
            if (!payload_started or payload_completed) return error.InvalidRunResolvePayload;
            payload_completed = true;
            continue;
        }

        const value = if (line.len > 0 and line[0] == '\t') line[1..] else line;
        if (payload_started and !payload_completed) {
            const owned_line = try allocator.dupe(u8, value);
            payload_lines.append(allocator, owned_line) catch |err| {
                allocator.free(owned_line);
                return err;
            };
            continue;
        }
        if (value.len == 0) continue;
        const owned_arg = try allocator.dupe(u8, value);
        args.append(allocator, owned_arg) catch |err| {
            allocator.free(owned_arg);
            return err;
        };
    }

    const args_slice = try args.toOwnedSlice(allocator);
    args = .empty;
    errdefer {
        for (args_slice) |arg| allocator.free(arg);
        allocator.free(args_slice);
    }

    var selection_text: ?[]u8 = null;
    if (payload_started) {
        selection_text = try joinLines(allocator, payload_lines.items);
    }
    for (payload_lines.items) |line| allocator.free(line);
    payload_lines.deinit(allocator);

    return .{
        .args = args_slice,
        .selection_text = selection_text,
    };
}

fn joinLines(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    if (lines.len == 0) return allocator.dupe(u8, "");

    var total_len: usize = lines.len - 1;
    for (lines) |line| total_len += line.len;

    var out = try allocator.alloc(u8, total_len);
    var index: usize = 0;
    for (lines, 0..) |line, line_index| {
        @memcpy(out[index .. index + line.len], line);
        index += line.len;
        if (line_index + 1 < lines.len) {
            out[index] = '\n';
            index += 1;
        }
    }
    return out;
}

const TestReader = struct {
    lines: []const []const u8,
    index: usize = 0,

    pub fn readUntilDelimiterOrEofAlloc(
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

test "parseArgsWithPayload validates explicit and inferred inline input kinds" {
    const options = try parseArgsWithPayload(&.{
        "--run-resolve",
        "--path=/tmp/example/main.zig",
        "--filetype=zig",
        "--buffer-id=7",
        "--input-kind=selection",
    }, "pub fn main() void {}\n");

    try std.testing.expectEqualStrings("/tmp/example/main.zig", options.path);
    try std.testing.expectEqual(@as(?u32, 7), options.buffer_id);
    try std.testing.expectEqual(@import("source.zig").InputKind.selection, options.input_kind);
    try std.testing.expectEqualStrings("pub fn main() void {}\n", options.selection_text.?);
    const unsaved_selection = try parseArgsWithPayload(&.{
        "--run-resolve",
        "--path=",
        "--filetype=zig",
        "--buffer-id=77",
        "--input-kind=selection",
    }, "pub fn main() void {}\n");
    try std.testing.expectEqualStrings("", unsaved_selection.path);
    try std.testing.expectEqual(@as(?u32, 77), unsaved_selection.buffer_id);
    const inferred_selection = try parseArgsWithPayload(&.{
        "--run-resolve",
        "--path=/tmp/example/main.zig",
        "--filetype=zig",
    }, "pub fn main() void {}\n");
    try std.testing.expectEqual(@import("source.zig").InputKind.selection, inferred_selection.input_kind);
    const unsaved_buffer = try parseArgsWithPayload(&.{
        "--run-resolve",
        "--path=",
        "--filetype=zig",
        "--buffer-id=99",
    }, "pub fn main() void {}\n");
    try std.testing.expectEqualStrings("", unsaved_buffer.path);
    try std.testing.expectEqual(@as(?u32, 99), unsaved_buffer.buffer_id);
    try std.testing.expectEqual(@import("source.zig").InputKind.buffer, unsaved_buffer.input_kind);
    try std.testing.expectError(
        error.MissingSelectionPayload,
        parseArgsWithPayload(&.{
            "--run-resolve",
            "--path=/tmp/example/main.zig",
            "--filetype=zig",
            "--input-kind=selection",
        }, null),
    );
}

test "collectRunResolveRequest preserves selection payload lines" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "\t--run-resolve",
        "\t--path=/tmp/example/main.zig",
        "\t--filetype=zig",
        "\t--input-kind=selection",
        "@@ZRUN_REQ_PAYLOAD_BEGIN 41",
        "\tpub fn main() void {",
        "\t",
        "\t}",
        "@@ZRUN_REQ_PAYLOAD_END 41",
        "@@ZRUN_REQ_END 41",
    } };

    const request = try collectRunResolveRequest(allocator, &reader, 41);
    defer {
        for (request.args) |arg| allocator.free(arg);
        allocator.free(request.args);
        if (request.selection_text) |selection_text| allocator.free(selection_text);
    }

    try std.testing.expectEqual(@as(usize, 4), request.args.len);
    try std.testing.expectEqualStrings("pub fn main() void {\n\n}", request.selection_text.?);
}

test "resolveRunner returns configured filetype runner" {
    const allocator = std.testing.allocator;
    defer config_store.reset();

    try config_store.setSyncedConfigJson(
        "{" ++
            "\"runners\":{" ++
            "\"python\":\"python3 -u $file\"" ++
            "}," ++
            "\"build_commands\":{}," ++
            "\"detect\":{}," ++
            "\"revision\":1" ++
            "}",
        1,
    );

    var resolved = try resolveRunner(std.testing.io, allocator, null, .{
        .path = "/tmp/test.py",
        .filetype = "python",
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("filetype", resolved.source);
    try std.testing.expectEqualStrings("/tmp/test.py", resolved.execution_path.?);
    try std.testing.expectEqualStrings("python3 -u '/tmp/test.py'", resolved.command.?);
    try std.testing.expectEqualStrings("python3", resolved.argv.items[0]);
    try std.testing.expectEqualStrings("-u", resolved.argv.items[1]);
    try std.testing.expectEqualStrings("/tmp/test.py", resolved.argv.items[2]);
}

test "resolveRunner returns builtin filetype runner without configured override" {
    const allocator = std.testing.allocator;
    defer config_store.reset();

    try config_store.setSyncedConfigJson(
        "{" ++
            "\"runners\":{}," ++
            "\"build_commands\":{}," ++
            "\"detect\":{}," ++
            "\"revision\":31" ++
            "}",
        31,
    );

    var resolved = try resolveRunner(std.testing.io, allocator, null, .{
        .path = "/tmp/test.py",
        .filetype = "python",
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("filetype", resolved.source);
    try std.testing.expectEqualStrings("/tmp/test.py", resolved.execution_path.?);
    try std.testing.expectEqualStrings("python3 -u '/tmp/test.py'", resolved.command.?);
    try std.testing.expectEqualStrings("python3", resolved.argv.items[0]);
    try std.testing.expectEqualStrings("-u", resolved.argv.items[1]);
    try std.testing.expectEqualStrings("/tmp/test.py", resolved.argv.items[2]);
}

test "handleDaemonFrame writes run resolve error frame for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{} };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try handleDaemonFrame(
        allocator,
        std.testing.io,
        null,
        &reader,
        &out.writer,
        "@@ZRUN_REQ_BEGIN 7 extra",
    );

    try std.testing.expectEqualStrings(
        "@@ZRUN_RES_BEGIN 7\n@@ZRUN_RES_ERR 7 InvalidRunResolveDaemonHeader\n@@ZRUN_RES_END 7\n",
        out.written(),
    );
}

test "resolveRunner keeps configured zig single-file runner when build.zig exists" {
    const allocator = std.testing.allocator;
    defer config_store.reset();

    try config_store.setSyncedConfigJson(
        "{" ++
            "\"runners\":{" ++
            "\"zig\":\"zig run $file\"" ++
            "}," ++
            "\"build_commands\":{}," ++
            "\"detect\":{}," ++
            "\"revision\":3" ++
            "}",
        3,
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data = "pub fn build(b: *std.Build) void { _ = b; }\n" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.zig" });
    defer allocator.free(filepath);

    var resolved = try resolveRunner(std.testing.io, allocator, null, .{
        .path = filepath,
        .filetype = "zig",
        .project_root = root,
    });
    defer resolved.deinit(allocator);

    const expected_command = try std.fmt.allocPrint(allocator, "zig run '{s}'", .{filepath});
    defer allocator.free(expected_command);

    try std.testing.expectEqualStrings("filetype", resolved.source);
    try std.testing.expectEqualStrings(filepath, resolved.execution_path.?);
    try std.testing.expectEqualStrings(expected_command, resolved.command.?);
    try std.testing.expectEqualStrings("zig", resolved.argv.items[0]);
    try std.testing.expectEqualStrings("run", resolved.argv.items[1]);
    try std.testing.expectEqualStrings(filepath, resolved.argv.items[2]);
    try std.testing.expect(resolved.cwd == null);
    try std.testing.expectEqualStrings("zig", resolved.name.?);
}

test "resolveRunner keeps builtin zig single-file runner when build.zig exists" {
    const allocator = std.testing.allocator;
    defer config_store.reset();

    try config_store.setSyncedConfigJson(
        "{" ++
            "\"runners\":{}," ++
            "\"build_commands\":{}," ++
            "\"detect\":{}," ++
            "\"revision\":32" ++
            "}",
        32,
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data = "pub fn build(b: *std.Build) void { _ = b; }\n" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.zig" });
    defer allocator.free(filepath);

    var resolved = try resolveRunner(std.testing.io, allocator, null, .{
        .path = filepath,
        .filetype = "zig",
        .project_root = root,
    });
    defer resolved.deinit(allocator);

    const expected_command = try std.fmt.allocPrint(allocator, "zig run '{s}'", .{filepath});
    defer allocator.free(expected_command);

    try std.testing.expectEqualStrings("filetype", resolved.source);
    try std.testing.expectEqualStrings(filepath, resolved.execution_path.?);
    try std.testing.expectEqualStrings(expected_command, resolved.command.?);
    try std.testing.expectEqualStrings("zig", resolved.argv.items[0]);
    try std.testing.expectEqualStrings("run", resolved.argv.items[1]);
    try std.testing.expectEqualStrings(filepath, resolved.argv.items[2]);
    try std.testing.expect(resolved.cwd == null);
    try std.testing.expectEqualStrings("zig", resolved.name.?);
}

test "resolveRunner prefers zig project run when source imports build-defined module" {
    const allocator = std.testing.allocator;
    defer config_store.reset();

    try config_store.setSyncedConfigJson(
        "{" ++
            "\"runners\":{" ++
            "\"zig\":\"zig run $file\"" ++
            "}," ++
            "\"build_commands\":{}," ++
            "\"detect\":{}," ++
            "\"revision\":7" ++
            "}",
        7,
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data = "pub fn build(b: *std.Build) void { _ = b; }\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/main.zig", .data =
        \\const zig = @import("zig");
        \\pub fn main() void { _ = zig; }
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.zig" });
    defer allocator.free(filepath);

    var resolved = try resolveRunner(std.testing.io, allocator, null, .{
        .path = filepath,
        .filetype = "zig",
        .project_root = root,
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("project", resolved.source);
    try std.testing.expectEqualStrings(filepath, resolved.execution_path.?);
    try std.testing.expectEqualStrings("zig build run", resolved.command.?);
    try std.testing.expectEqualStrings(root, resolved.cwd.?);
    try std.testing.expectEqualStrings("Zig Project", resolved.name.?);
}

test "resolveRunner ignores commented and quoted zig imports when choosing project runner" {
    const allocator = std.testing.allocator;
    defer config_store.reset();

    try config_store.setSyncedConfigJson(
        "{" ++
            "\"runners\":{" ++
            "\"zig\":\"zig run $file\"" ++
            "}," ++
            "\"build_commands\":{}," ++
            "\"detect\":{}," ++
            "\"revision\":33" ++
            "}",
        33,
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data = "pub fn build(b: *std.Build) void { _ = b; }\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/main.zig", .data =
        \\// @import("zig")
        \\const text = "@import(\"zig\")";
        \\const multi =
        \\    \\@import("zig")
        \\;
        \\pub fn main() void {
        \\    _ = text;
        \\    _ = multi;
        \\}
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.zig" });
    defer allocator.free(filepath);

    var resolved = try resolveRunner(std.testing.io, allocator, null, .{
        .path = filepath,
        .filetype = "zig",
        .project_root = root,
    });
    defer resolved.deinit(allocator);

    const expected_command = try std.fmt.allocPrint(allocator, "zig run '{s}'", .{filepath});
    defer allocator.free(expected_command);

    try std.testing.expectEqualStrings("filetype", resolved.source);
    try std.testing.expectEqualStrings(filepath, resolved.execution_path.?);
    try std.testing.expectEqualStrings(expected_command, resolved.command.?);
    try std.testing.expectEqualStrings(filepath, resolved.argv.items[2]);
    try std.testing.expect(resolved.cwd == null);
}

test "resolveRunner prefers conda project run over generic python runner" {
    const allocator = std.testing.allocator;
    defer config_store.reset();

    try config_store.setSyncedConfigJson(
        "{" ++
            "\"runners\":{" ++
            "\"python\":\"python3 -u $file\"" ++
            "}," ++
            "\"build_commands\":{}," ++
            "\"detect\":{}," ++
            "\"revision\":4" ++
            "}",
        4,
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writePythonCondaProject(tmp.dir);

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try tmp.dir.realPathFileAlloc(std.testing.io, "app/main.py", allocator);
    defer allocator.free(filepath);

    var resolved = try resolveRunner(std.testing.io, allocator, null, .{
        .path = filepath,
        .filetype = "python",
        .project_root = root,
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("filetype", resolved.source);
    try std.testing.expectEqualStrings(filepath, resolved.execution_path.?);
    try std.testing.expectEqualStrings("conda run -n demo-conda python -m main", resolved.command.?);
    try std.testing.expectEqualStrings("conda", resolved.argv.items[0]);
    try std.testing.expectEqualStrings("run", resolved.argv.items[1]);
    try std.testing.expectEqualStrings("-n", resolved.argv.items[2]);
    try std.testing.expectEqualStrings("demo-conda", resolved.argv.items[3]);
}

test "resolveRunner prefers unnamed conda project run over generic python runner" {
    const allocator = std.testing.allocator;
    defer config_store.reset();

    try config_store.setSyncedConfigJson(
        "{" ++
            "\"runners\":{" ++
            "\"python\":\"python3 -u $file\"" ++
            "}," ++
            "\"build_commands\":{}," ++
            "\"detect\":{}," ++
            "\"revision\":5" ++
            "}",
        5,
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "environment.yml", .data =
        \\dependencies:
        \\  - python=3.12
        \\  - pytest
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/main.py", .data =
        \\def main():
        \\    print("hello")
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try tmp.dir.realPathFileAlloc(std.testing.io, "app/main.py", allocator);
    defer allocator.free(filepath);

    var resolved = try resolveRunner(std.testing.io, allocator, null, .{
        .path = filepath,
        .filetype = "python",
        .project_root = root,
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("filetype", resolved.source);
    try std.testing.expectEqualStrings(filepath, resolved.execution_path.?);
    try std.testing.expectEqualStrings("conda run python -m main", resolved.command.?);
    try std.testing.expectEqualStrings("conda", resolved.argv.items[0]);
    try std.testing.expectEqualStrings("run", resolved.argv.items[1]);
    try std.testing.expectEqualStrings("python", resolved.argv.items[2]);
}

test "resolveRunner keeps single-file go runner even inside go module" {
    const allocator = std.testing.allocator;
    defer config_store.reset();

    try config_store.setSyncedConfigJson(
        "{" ++
            "\"runners\":{" ++
            "\"go\":\"go run $file\"" ++
            "}," ++
            "\"build_commands\":{}," ++
            "\"detect\":{}," ++
            "\"revision\":6" ++
            "}",
        6,
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writeGoProject(tmp.dir);

    const filepath = try tmp.dir.realPathFileAlloc(std.testing.io, "cmd/api/main.go", allocator);
    defer allocator.free(filepath);

    var resolved = try resolveRunner(std.testing.io, allocator, null, .{
        .path = filepath,
        .filetype = "go",
    });
    defer resolved.deinit(allocator);

    const expected_command = try std.fmt.allocPrint(allocator, "go run '{s}'", .{filepath});
    defer allocator.free(expected_command);

    try std.testing.expectEqualStrings("filetype", resolved.source);
    try std.testing.expectEqualStrings(filepath, resolved.execution_path.?);
    try std.testing.expectEqualStrings(expected_command, resolved.command.?);
    try std.testing.expectEqualStrings("go", resolved.argv.items[0]);
    try std.testing.expectEqualStrings("run", resolved.argv.items[1]);
    try std.testing.expectEqualStrings(filepath, resolved.argv.items[2]);
}
