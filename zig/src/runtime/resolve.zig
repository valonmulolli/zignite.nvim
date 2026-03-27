const std = @import("std");
const config = @import("../config.zig");
const config_store = @import("../config/store.zig");
const frame = @import("../protocol/frame.zig");
const protocol_stdio = @import("../protocol/stdio.zig");
const runner = @import("resolve/runner.zig");
const types = @import("resolve/types.zig");

pub const Options = types.Options;
pub const ResolvedRunner = types.ResolvedRunner;
pub const resolveRunner = runner.resolveRunner;

pub const RUN_RESOLVE_REQ_BEGIN = "@@ZRUN_REQ_BEGIN";
pub const RUN_RESOLVE_REQ_END = "@@ZRUN_REQ_END";
pub const RUN_RESOLVE_RES_BEGIN = "@@ZRUN_RES_BEGIN";
pub const RUN_RESOLVE_RES_END = "@@ZRUN_RES_END";
pub const RUN_RESOLVE_RES_ERR = "@@ZRUN_RES_ERR";
const RUN_RESOLVE_MAX_LINE = 16384;

const ResolveDaemonRequestHeader = struct {
    request_id: u64,
};

pub fn parseArgs(args: []const []const u8) !Options {
    var path: ?[]const u8 = null;
    var filetype: ?[]const u8 = null;
    var context_path: ?[]const u8 = null;
    var project_root: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--run-resolve")) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "--path=")) {
            path = arg["--path=".len..];
        } else if (std.mem.startsWith(u8, arg, "--filetype=")) {
            filetype = arg["--filetype=".len..];
        } else if (std.mem.startsWith(u8, arg, "--context-path=")) {
            context_path = arg["--context-path=".len..];
        } else if (std.mem.startsWith(u8, arg, "--project-root=")) {
            project_root = arg["--project-root=".len..];
        } else {
            return error.InvalidRunResolveFlag;
        }
    }

    return .{
        .path = path orelse return error.MissingRunResolvePath,
        .filetype = filetype orelse return error.MissingRunResolveFiletype,
        .context_path = context_path,
        .project_root = project_root,
    };
}

pub fn runMode(allocator: std.mem.Allocator, options: Options) !void {
    var stdout_ctx: protocol_stdio.Stdout = .{};
    stdout_ctx.init();
    const stdout = stdout_ctx.io();
    try writeResolvedOutput(stdout, allocator, options);
    try stdout.flush();
}

pub fn handleDaemonFrame(
    allocator: std.mem.Allocator,
    reader: anytype,
    stdout: anytype,
    begin_line: []const u8,
) !void {
    const header = parseResolveDaemonBegin(begin_line) catch |err| {
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

    var request_args: std.ArrayList([]u8) = .empty;
    defer {
        for (request_args.items) |arg| allocator.free(arg);
        request_args.deinit(allocator);
    }

    const ParseArgsLine = struct {
        allocator: std.mem.Allocator,
        request_args: *std.ArrayList([]u8),

        fn onLine(self: @This(), line: []const u8) !void {
            const value = if (line.len > 0 and line[0] == '\t') line[1..] else line;
            if (value.len == 0) return;
            try self.request_args.append(self.allocator, try self.allocator.dupe(u8, value));
        }
    };
    const parse_args_line = ParseArgsLine{
        .allocator = allocator,
        .request_args = &request_args,
    };

    const completed = try frame.readUntilEnd(
        allocator,
        reader,
        RUN_RESOLVE_MAX_LINE,
        RUN_RESOLVE_REQ_END,
        header.request_id,
        parse_args_line.onLine,
    );
    if (!completed) return error.UnexpectedEof;

    try stdout.print("{s} {d}\n", .{ RUN_RESOLVE_RES_BEGIN, header.request_id });
    const options = parseArgs(request_args.items);
    if (options) |parsed| {
        writeResolvedOutput(stdout, allocator, parsed) catch |err| {
            try stdout.print("{s} {d} {s}\n", .{ RUN_RESOLVE_RES_ERR, header.request_id, @errorName(err) });
        };
    } else |err| {
        try stdout.print("{s} {d} {s}\n", .{ RUN_RESOLVE_RES_ERR, header.request_id, @errorName(err) });
    }
    try stdout.print("{s} {d}\n", .{ RUN_RESOLVE_RES_END, header.request_id });
    try stdout.flush();
}

fn writeResolvedOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options) !void {
    var resolved = try resolveRunner(allocator, options);
    defer resolved.deinit(allocator);

    if (resolved.command) |command| {
        try stdout.print("COMMAND\t{s}\n", .{command});
    }
    for (resolved.argv.items) |arg| {
        try stdout.print("ARGV\t{s}\n", .{arg});
    }
    try stdout.print("SOURCE\t{s}\n", .{resolved.source});
    try stdout.print("FILETYPE\t{s}\n", .{resolved.filetype orelse options.filetype});
    try stdout.print("CONFIG_REVISION\t{d}\n", .{config.getSyncedRevision()});
    if (resolved.cleanup_command) |cleanup| {
        try stdout.print("CLEANUP_COMMAND\t{s}\n", .{cleanup});
    }
    if (resolved.cwd) |cwd| {
        try stdout.print("CWD\t{s}\n", .{cwd});
    }
    if (resolved.name) |name| {
        try stdout.print("NAME\t{s}\n", .{name});
    }
}

fn parseResolveDaemonBegin(line: []const u8) !ResolveDaemonRequestHeader {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return error.InvalidRunResolveDaemonHeader;
    if (!std.mem.eql(u8, marker, RUN_RESOLVE_REQ_BEGIN)) {
        return error.InvalidRunResolveDaemonHeader;
    }

    const request_id = try std.fmt.parseInt(u64, it.next() orelse return error.InvalidRunResolveDaemonHeader, 10);
    if (it.next() != null) {
        return error.InvalidRunResolveDaemonHeader;
    }

    return .{ .request_id = request_id };
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

    var resolved = try resolveRunner(allocator, .{
        .path = "/tmp/test.py",
        .filetype = "python",
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("filetype", resolved.source);
    try std.testing.expectEqualStrings("python3 -u '/tmp/test.py'", resolved.command.?);
    try std.testing.expectEqualStrings("python3", resolved.argv.items[0]);
    try std.testing.expectEqualStrings("-u", resolved.argv.items[1]);
    try std.testing.expectEqualStrings("/tmp/test.py", resolved.argv.items[2]);
}

test "handleDaemonFrame writes run resolve error frame for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{} };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try handleDaemonFrame(
        allocator,
        &reader,
        out.writer(allocator),
        "@@ZRUN_REQ_BEGIN 7 extra",
    );

    try std.testing.expectEqualStrings(
        "@@ZRUN_RES_BEGIN 7\n@@ZRUN_RES_ERR 7 InvalidRunResolveDaemonHeader\n@@ZRUN_RES_END 7\n",
        out.items,
    );
}

test "resolveRunner prefers zig build run when build.zig exists" {
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

    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "build.zig", .data = "pub fn build(b: *std.Build) void { _ = b; }\n" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.zig" });
    defer allocator.free(filepath);

    var resolved = try resolveRunner(allocator, .{
        .path = filepath,
        .filetype = "zig",
        .project_root = root,
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("project", resolved.source);
    try std.testing.expectEqualStrings("zig build run", resolved.command.?);
    try std.testing.expectEqualStrings(root, resolved.cwd.?);
    try std.testing.expectEqualStrings("Zig Project", resolved.name.?);
}
