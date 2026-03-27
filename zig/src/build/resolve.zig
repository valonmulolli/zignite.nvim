const std = @import("std");
const config = @import("../config.zig");
const frame = @import("../protocol/frame.zig");
const protocol_stdio = @import("../protocol/stdio.zig");
const project = @import("../project.zig");
const project_types = @import("../project/core/types.zig");
const build_types = @import("system/types.zig");

pub const Options = struct {
    path: []const u8,
    filetype: []const u8,
    project_root: ?[]const u8 = null,
};

const ResolveDaemonRequestHeader = struct {
    request_id: u64,
};

pub const BUILD_RESOLVE_REQ_BEGIN = "@@ZBR_REQ_BEGIN";
pub const BUILD_RESOLVE_REQ_END = "@@ZBR_REQ_END";
pub const BUILD_RESOLVE_RES_BEGIN = "@@ZBR_RES_BEGIN";
pub const BUILD_RESOLVE_RES_END = "@@ZBR_RES_END";
pub const BUILD_RESOLVE_RES_ERR = "@@ZBR_RES_ERR";
const BUILD_RESOLVE_MAX_LINE = 16384;

pub const ResolvedOutput = struct {
    root: ?[]u8 = null,
    system: ?[]u8 = null,
    build_ready: ?bool = null,
    commands: std.ArrayList(build_types.CommandEntry) = .empty,
    preferred: std.ArrayList(build_types.CommandEntry) = .empty,

    pub fn deinit(self: *ResolvedOutput, allocator: std.mem.Allocator) void {
        if (self.root) |root| allocator.free(root);
        if (self.system) |system| allocator.free(system);
        freeOwnedCommands(allocator, self.commands.items);
        self.commands.deinit(allocator);
        freeOwnedCommands(allocator, self.preferred.items);
        self.preferred.deinit(allocator);
    }
};

pub fn parseArgs(args: []const []const u8) !Options {
    var path: ?[]const u8 = null;
    var filetype: ?[]const u8 = null;
    var project_root: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--build-resolve")) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "--path=")) {
            path = arg["--path=".len..];
        } else if (std.mem.startsWith(u8, arg, "--filetype=")) {
            filetype = arg["--filetype=".len..];
        } else if (std.mem.startsWith(u8, arg, "--project-root=")) {
            project_root = arg["--project-root=".len..];
        } else {
            return error.InvalidBuildResolveFlag;
        }
    }

    return .{
        .path = path orelse return error.MissingBuildResolvePath,
        .filetype = filetype orelse return error.MissingBuildResolveFiletype,
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
        if (frame.parseRequestId(begin_line, BUILD_RESOLVE_REQ_BEGIN)) |request_id| {
            try frame.writeErrorResponse(
                stdout,
                BUILD_RESOLVE_RES_BEGIN,
                BUILD_RESOLVE_RES_ERR,
                BUILD_RESOLVE_RES_END,
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
        BUILD_RESOLVE_MAX_LINE,
        BUILD_RESOLVE_REQ_END,
        header.request_id,
        parse_args_line.onLine,
    );
    if (!completed) return error.UnexpectedEof;

    try stdout.print("{s} {d}\n", .{ BUILD_RESOLVE_RES_BEGIN, header.request_id });
    const options = parseArgs(request_args.items);
    if (options) |parsed| {
        writeResolvedOutput(stdout, allocator, parsed) catch |err| {
            try stdout.print("{s} {d} {s}\n", .{ BUILD_RESOLVE_RES_ERR, header.request_id, @errorName(err) });
        };
    } else |err| {
        try stdout.print("{s} {d} {s}\n", .{ BUILD_RESOLVE_RES_ERR, header.request_id, @errorName(err) });
    }
    try stdout.print("{s} {d}\n", .{ BUILD_RESOLVE_RES_END, header.request_id });
    try stdout.flush();
}

fn writeResolvedOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options) !void {
    const configured = try collectConfiguredCommands(allocator, options.filetype);
    defer freeOwnedCommands(allocator, configured);

    var parsed_output = try resolveOutput(allocator, options);
    defer parsed_output.deinit(allocator);

    if (parsed_output.root) |root| {
        try stdout.print("ROOT\t{s}\n", .{root});
    }
    if (parsed_output.system) |system| {
        try stdout.print("SYSTEM\t{s}\n", .{system});
    }
    if (parsed_output.build_ready) |ready| {
        try stdout.print("BUILD_READY\t{d}\n", .{if (ready) @as(u8, 1) else @as(u8, 0)});
    }
    try stdout.print("CONFIG_REVISION\t{d}\n", .{config.getSyncedRevision()});

    for (parsed_output.commands.items) |entry| {
        try stdout.print("COMMAND\t{s}\t{s}\n", .{ entry.name, entry.command });
    }

    if (parsed_output.preferred.items.len == 0) {
        try appendImplicitPreferred(allocator, &parsed_output.preferred, parsed_output.commands.items);
    }
    for (parsed_output.preferred.items) |entry| {
        try stdout.print("PREFERRED\t{s}\t{s}\n", .{ entry.name, entry.command });
    }
}

pub fn resolveOutput(allocator: std.mem.Allocator, options: Options) !ResolvedOutput {
    const configured = try collectConfiguredCommands(allocator, options.filetype);
    defer freeOwnedCommands(allocator, configured);

    var parsed_output = try collectAutoProjectOutput(allocator, options);
    errdefer parsed_output.deinit(allocator);

    for (configured) |entry| {
        try upsertOwnedCommand(&parsed_output.commands, allocator, entry.name, entry.command);
    }
    return parsed_output;
}

fn collectConfiguredCommands(allocator: std.mem.Allocator, filetype: []const u8) ![]build_types.CommandEntry {
    const raw = config.getSyncedConfigJson() orelse return allocator.alloc(build_types.CommandEntry, 0);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch
        return allocator.alloc(build_types.CommandEntry, 0);
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return allocator.alloc(build_types.CommandEntry, 0);

    const build_commands = root.object.get("build_commands") orelse return allocator.alloc(build_types.CommandEntry, 0);
    if (build_commands != .object) return allocator.alloc(build_types.CommandEntry, 0);

    const filetype_commands = build_commands.object.get(filetype) orelse return allocator.alloc(build_types.CommandEntry, 0);
    if (filetype_commands != .object) return allocator.alloc(build_types.CommandEntry, 0);

    var commands = try std.ArrayList(build_types.CommandEntry).initCapacity(allocator, filetype_commands.object.count());
    errdefer {
        freeOwnedCommands(allocator, commands.items);
        commands.deinit(allocator);
    }

    var it = filetype_commands.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        try commands.append(allocator, .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .command = try allocator.dupe(u8, entry.value_ptr.string),
        });
    }

    return try commands.toOwnedSlice(allocator);
}

fn collectAutoProjectOutput(allocator: std.mem.Allocator, options: Options) !ResolvedOutput {
    const kind = autoKindForFiletype(options.filetype);
    if (kind == null or !isDetectionEnabled(allocator, options.filetype)) {
        return .{};
    }

    const project_options = project.Options{
        .kind = kind.?,
        .path = options.path,
        .match_path = options.path,
        .project_root = options.project_root,
    };

    const contents = try project.readProjectFile(allocator, project_options.kind, project_options.path);
    defer allocator.free(contents);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try project.writeOutput(output.writer(allocator), allocator, project_options, contents);

    return try parseProjectOutput(allocator, output.items);
}

fn parseProjectOutput(allocator: std.mem.Allocator, output: []const u8) !ResolvedOutput {
    var parsed: ResolvedOutput = .{};
    errdefer parsed.deinit(allocator);

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "ROOT\t")) {
            parsed.root = try allocator.dupe(u8, line["ROOT\t".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "SYSTEM\t")) {
            parsed.system = try allocator.dupe(u8, line["SYSTEM\t".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "BUILD_READY\t")) {
            parsed.build_ready = std.mem.eql(u8, line["BUILD_READY\t".len..], "1");
            continue;
        }

        const first = splitFirstTab(line) orelse continue;
        if (!std.mem.eql(u8, first[0], "COMMAND") and !std.mem.eql(u8, first[0], "PREFERRED")) continue;
        const second = splitFirstTab(first[1]) orelse continue;
        if (second[0].len == 0 or second[1].len == 0) continue;

        if (std.mem.eql(u8, first[0], "COMMAND")) {
            try upsertOwnedCommand(&parsed.commands, allocator, second[0], second[1]);
        } else {
            try upsertOwnedCommand(&parsed.preferred, allocator, second[0], second[1]);
        }
    }

    return parsed;
}

fn autoKindForFiletype(filetype: []const u8) ?project_types.Kind {
    if (std.mem.eql(u8, filetype, "c") or std.mem.eql(u8, filetype, "cpp")) return .c_family_auto;
    if (std.mem.eql(u8, filetype, "rust")) return .cargo_auto;
    if (std.mem.eql(u8, filetype, "go")) return .go_auto;
    if (std.mem.eql(u8, filetype, "java") or std.mem.eql(u8, filetype, "kotlin")) return .jvm_auto;
    if (std.mem.eql(u8, filetype, "javascript") or std.mem.eql(u8, filetype, "typescript")) return .package_json_auto;
    if (std.mem.eql(u8, filetype, "python")) return .python_auto;
    if (std.mem.eql(u8, filetype, "bzl")) return .bazel_auto;
    return null;
}

fn isDetectionEnabled(allocator: std.mem.Allocator, filetype: []const u8) bool {
    const raw = config.getSyncedConfigJson() orelse return true;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return true;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return true;
    const detect = root.object.get("detect") orelse return true;
    if (detect != .object) return true;

    const detect_key =
        if (std.mem.eql(u8, filetype, "c") or std.mem.eql(u8, filetype, "cpp"))
            "c_cpp_make"
        else if (std.mem.eql(u8, filetype, "javascript") or std.mem.eql(u8, filetype, "typescript"))
            "js_package_scripts"
        else if (std.mem.eql(u8, filetype, "java") or std.mem.eql(u8, filetype, "kotlin"))
            "java_kotlin_project"
        else if (std.mem.eql(u8, filetype, "bzl"))
            "bazel_project"
        else
            return true;

    const enabled = detect.object.get(detect_key) orelse return true;
    if (enabled != .bool) return true;
    return enabled.bool;
}

fn appendImplicitPreferred(
    allocator: std.mem.Allocator,
    preferred: *std.ArrayList(build_types.CommandEntry),
    commands: []const build_types.CommandEntry,
) !void {
    const keys = [_][]const u8{ "build", "run", "test", "clean" };
    for (keys) |key| {
        if (findCommand(preferred.items, key) != null) continue;
        const command = findCommand(commands, key) orelse continue;
        try upsertOwnedCommand(preferred, allocator, key, command);
    }
}

fn findCommand(commands: []const build_types.CommandEntry, name: []const u8) ?[]const u8 {
    for (commands) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.command;
    }
    return null;
}

fn upsertOwnedCommand(
    commands: *std.ArrayList(build_types.CommandEntry),
    allocator: std.mem.Allocator,
    name: []const u8,
    command: []const u8,
) !void {
    for (commands.items) |*entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        allocator.free(entry.command);
        entry.command = try allocator.dupe(u8, command);
        return;
    }

    try commands.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .command = try allocator.dupe(u8, command),
    });
}

fn freeOwnedCommands(allocator: std.mem.Allocator, commands: []build_types.CommandEntry) void {
    for (commands) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.command);
    }
}

fn splitFirstTab(line: []const u8) ?struct { [2][]const u8 } {
    const index = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
    return .{ .{ line[0..index], line[index + 1 ..] } };
}

fn parseResolveDaemonBegin(line: []const u8) !ResolveDaemonRequestHeader {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return error.InvalidBuildResolveDaemonHeader;
    if (!std.mem.eql(u8, marker, BUILD_RESOLVE_REQ_BEGIN)) {
        return error.InvalidBuildResolveDaemonHeader;
    }

    const request_id = try std.fmt.parseInt(u64, it.next() orelse return error.InvalidBuildResolveDaemonHeader, 10);
    if (it.next() != null) {
        return error.InvalidBuildResolveDaemonHeader;
    }
    return .{ .request_id = request_id };
}

const TestReader = struct {
    fn readUntilDelimiterOrEofAlloc(
        self: *TestReader,
        allocator: std.mem.Allocator,
        delimiter: u8,
        max_line: usize,
    ) !?[]u8 {
        _ = self;
        _ = allocator;
        _ = delimiter;
        _ = max_line;
        return null;
    }
};

test "runMode merges synced configured build commands with backend commands" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"c":{"build":"make","custom":"make custom"},"rust":{"build":"cargo build"}},"detect":{"c_cpp_make":true}}
    , 7);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "CMakeLists.txt", .data = "project(demo)\nadd_executable(demo main.cpp)\n" });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "main.cpp" });
    defer allocator.free(filepath);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try writeResolvedOutput(out.writer(allocator), allocator, .{
        .path = filepath,
        .filetype = "c",
        .project_root = root,
    });

    try std.testing.expect(std.mem.indexOf(u8, out.items, "CONFIG_REVISION\t7\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tcustom\tmake custom\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbuild\tcmake --build build\n") != null);
}

test "handleDaemonFrame writes build resolve error frame for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{};
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try handleDaemonFrame(
        allocator,
        &reader,
        out.writer(allocator),
        "@@ZBR_REQ_BEGIN 9 extra",
    );

    try std.testing.expectEqualStrings(
        "@@ZBR_RES_BEGIN 9\n@@ZBR_RES_ERR 9 InvalidBuildResolveDaemonHeader\n@@ZBR_RES_END 9\n",
        out.items,
    );
}
