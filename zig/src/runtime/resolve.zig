const std = @import("std");
const build_resolve = @import("../build/resolve.zig");
const build_types = @import("../build/system/types.zig");
const config = @import("../config.zig");
const config_store = @import("../config/store.zig");
const frame = @import("../protocol/frame.zig");
const protocol_stdio = @import("../protocol/stdio.zig");

pub const Options = struct {
    path: []const u8,
    filetype: []const u8,
    project_root: ?[]const u8 = null,
};

pub const RUN_RESOLVE_REQ_BEGIN = "@@ZRUN_REQ_BEGIN";
pub const RUN_RESOLVE_REQ_END = "@@ZRUN_REQ_END";
pub const RUN_RESOLVE_RES_BEGIN = "@@ZRUN_RES_BEGIN";
pub const RUN_RESOLVE_RES_END = "@@ZRUN_RES_END";
pub const RUN_RESOLVE_RES_ERR = "@@ZRUN_RES_ERR";
const RUN_RESOLVE_MAX_LINE = 16384;

const ResolveDaemonRequestHeader = struct {
    request_id: u64,
};

pub const ResolvedRunner = struct {
    source: []const u8 = "filetype",
    command: ?[]u8 = null,
    cleanup_command: ?[]u8 = null,
    cwd: ?[]u8 = null,
    name: ?[]u8 = null,

    pub fn deinit(self: *ResolvedRunner, allocator: std.mem.Allocator) void {
        if (self.command) |command| allocator.free(command);
        if (self.cleanup_command) |cleanup| allocator.free(cleanup);
        if (self.cwd) |cwd| allocator.free(cwd);
        if (self.name) |name| allocator.free(name);
    }
};

pub fn parseArgs(args: []const []const u8) !Options {
    var path: ?[]const u8 = null;
    var filetype: ?[]const u8 = null;
    var project_root: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--run-resolve")) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "--path=")) {
            path = arg["--path=".len..];
        } else if (std.mem.startsWith(u8, arg, "--filetype=")) {
            filetype = arg["--filetype=".len..];
        } else if (std.mem.startsWith(u8, arg, "--project-root=")) {
            project_root = arg["--project-root=".len..];
        } else {
            return error.InvalidRunResolveFlag;
        }
    }

    return .{
        .path = path orelse return error.MissingRunResolvePath,
        .filetype = filetype orelse return error.MissingRunResolveFiletype,
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

pub fn resolveRunner(allocator: std.mem.Allocator, options: Options) !ResolvedRunner {
    var build_output = try build_resolve.resolveOutput(allocator, .{
        .path = options.path,
        .filetype = options.filetype,
        .project_root = options.project_root,
    });
    defer build_output.deinit(allocator);

    if (std.mem.eql(u8, options.filetype, "zig")) {
        if (try buildProjectRunner(allocator, options.filetype, &build_output)) |runner| {
            return runner;
        }
    }

    if (try collectConfiguredRunner(allocator, options.filetype)) |configured| {
        var runner = configured;
        errdefer runner.deinit(allocator);
        try applySmartRunnerDefaults(allocator, options.filetype, &build_output, &runner);
        return runner;
    }

    if (try buildProjectRunner(allocator, options.filetype, &build_output)) |runner| {
        return runner;
    }

    return .{};
}

fn writeResolvedOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options) !void {
    var runner = try resolveRunner(allocator, options);
    defer runner.deinit(allocator);

    if (runner.command) |command| {
        try stdout.print("COMMAND\t{s}\n", .{command});
    }
    try stdout.print("SOURCE\t{s}\n", .{runner.source});
    try stdout.print("FILETYPE\t{s}\n", .{options.filetype});
    try stdout.print("CONFIG_REVISION\t{d}\n", .{config.getSyncedRevision()});
    if (runner.cleanup_command) |cleanup| {
        try stdout.print("CLEANUP_COMMAND\t{s}\n", .{cleanup});
    }
    if (runner.cwd) |cwd| {
        try stdout.print("CWD\t{s}\n", .{cwd});
    }
    if (runner.name) |name| {
        try stdout.print("NAME\t{s}\n", .{name});
    }
}

fn collectConfiguredRunner(allocator: std.mem.Allocator, filetype: []const u8) !?ResolvedRunner {
    const raw = config.getSyncedConfigJson() orelse return null;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const runners = parsed.value.object.get("runners") orelse return null;
    if (runners != .object) return null;
    const runner_value = runners.object.get(filetype) orelse return null;

    return try parseRunnerValue(allocator, runner_value);
}

fn parseRunnerValue(allocator: std.mem.Allocator, value: std.json.Value) !?ResolvedRunner {
    switch (value) {
        .string => |command| {
            if (command.len == 0) return null;
            return .{ .command = try allocator.dupe(u8, command) };
        },
        .array => {
            const joined = try joinCommandArray(allocator, value.array.items);
            if (joined == null) return null;
            return .{ .command = joined };
        },
        .object => {
            const cmd_value = value.object.get("cmd") orelse return null;
            const command = try parseRunnerCommand(allocator, cmd_value) orelse return null;
            var runner = ResolvedRunner{ .command = command };
            errdefer runner.deinit(allocator);

            if (value.object.get("cleanup_command")) |cleanup| {
                if (cleanup == .string and cleanup.string.len > 0) {
                    runner.cleanup_command = try allocator.dupe(u8, cleanup.string);
                }
            }
            if (value.object.get("cwd")) |cwd| {
                if (cwd == .string and cwd.string.len > 0) {
                    runner.cwd = try allocator.dupe(u8, cwd.string);
                }
            }
            return runner;
        },
        else => return null,
    }
}

fn parseRunnerCommand(allocator: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    return switch (value) {
        .string => |command| if (command.len == 0) null else try allocator.dupe(u8, command),
        .array => try joinCommandArray(allocator, value.array.items),
        else => null,
    };
}

fn joinCommandArray(allocator: std.mem.Allocator, items: []const std.json.Value) !?[]u8 {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);

    var appended = false;
    for (items) |item| {
        if (item != .string or item.string.len == 0) continue;
        if (appended) try joined.appendSlice(allocator, " && ");
        try joined.appendSlice(allocator, item.string);
        appended = true;
    }

    if (!appended) return null;
    return joined.toOwnedSlice(allocator);
}

fn applySmartRunnerDefaults(
    allocator: std.mem.Allocator,
    filetype: []const u8,
    build_output: *const build_resolve.ResolvedOutput,
    runner: *ResolvedRunner,
) !void {
    const command = runner.command orelse return;

    if (std.mem.eql(u8, filetype, "python") and std.mem.eql(u8, command, "python3 -u $file")) {
        if (findCommand(build_output.commands.items, "run")) |project_run| {
            if (std.mem.startsWith(u8, project_run, "uv run ")) {
                allocator.free(command);
                runner.command = try allocator.dupe(u8, project_run);
            }
        }
        return;
    }

    if (std.mem.eql(u8, filetype, "go") and std.mem.eql(u8, command, "go run $file")) {
        if (findCommand(build_output.commands.items, "run")) |project_run| {
            allocator.free(command);
            runner.command = try allocator.dupe(u8, project_run);
            if (runner.cwd == null) {
                runner.cwd = try allocator.dupe(u8, "$dir");
            }
        }
    }
}

fn buildProjectRunner(
    allocator: std.mem.Allocator,
    filetype: []const u8,
    build_output: *const build_resolve.ResolvedOutput,
) !?ResolvedRunner {
    const command = findPreferredProjectCommand(build_output) orelse return null;

    var runner = ResolvedRunner{
        .source = "project",
        .command = try allocator.dupe(u8, command),
        .name = try formatProjectName(allocator, filetype),
    };
    errdefer runner.deinit(allocator);

    if (build_output.root) |root| {
        runner.cwd = try allocator.dupe(u8, root);
    }
    return runner;
}

fn findPreferredProjectCommand(build_output: *const build_resolve.ResolvedOutput) ?[]const u8 {
    const names = [_][]const u8{ "run", "live", "dev", "watch", "serve", "start", "preview", "build" };
    for (names) |name| {
        if (findCommand(build_output.preferred.items, name)) |command| return command;
    }
    for (names) |name| {
        if (findCommand(build_output.commands.items, name)) |command| return command;
    }
    return null;
}

fn findCommand(commands: []const build_types.CommandEntry, name: []const u8) ?[]const u8 {
    for (commands) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.command;
    }
    return null;
}

fn formatProjectName(allocator: std.mem.Allocator, filetype: []const u8) ![]u8 {
    var text = try allocator.dupe(u8, filetype);
    errdefer allocator.free(text);
    if (text.len > 0 and std.ascii.isLower(text[0])) {
        text[0] = std.ascii.toUpper(text[0]);
    }
    return std.fmt.allocPrint(allocator, "{s} Project", .{text});
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

    var runner = try resolveRunner(allocator, .{
        .path = "/tmp/test.py",
        .filetype = "python",
    });
    defer runner.deinit(allocator);

    try std.testing.expectEqualStrings("filetype", runner.source);
    try std.testing.expectEqualStrings("python3 -u $file", runner.command.?);
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
