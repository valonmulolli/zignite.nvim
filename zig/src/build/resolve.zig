const std = @import("std");
const config = @import("../config.zig");
const frame = @import("../protocol/frame.zig");
const protocol_stdio = @import("../protocol/stdio.zig");
const command = @import("resolve/command.zig");
const detected = @import("resolve/detected.zig");
const types = @import("resolve/types.zig");

pub const Options = types.Options;
pub const ResolvedOutput = types.ResolvedOutput;
pub const resolveOutput = detected.resolveOutput;
pub const resolveDetectedOutput = detected.resolveDetectedOutput;
pub const findCommand = detected.findCommand;

const ResolveDaemonRequestHeader = struct {
    request_id: u64,
};

pub const BUILD_RESOLVE_REQ_BEGIN = "@@ZBR_REQ_BEGIN";
pub const BUILD_RESOLVE_REQ_END = "@@ZBR_REQ_END";
pub const BUILD_RESOLVE_RES_BEGIN = "@@ZBR_RES_BEGIN";
pub const BUILD_RESOLVE_RES_END = "@@ZBR_RES_END";
pub const BUILD_RESOLVE_RES_ERR = "@@ZBR_RES_ERR";
const BUILD_RESOLVE_MAX_LINE = 16384;

pub fn parseArgs(args: []const []const u8) !Options {
    var path: ?[]const u8 = null;
    var filetype: ?[]const u8 = null;
    var command_name: ?[]const u8 = null;
    var command_args: ?[]const u8 = null;
    var project_root: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--build-resolve")) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "--path=")) {
            path = arg["--path=".len..];
        } else if (std.mem.startsWith(u8, arg, "--filetype=")) {
            filetype = arg["--filetype=".len..];
        } else if (std.mem.startsWith(u8, arg, "--command-name=")) {
            command_name = arg["--command-name=".len..];
        } else if (std.mem.startsWith(u8, arg, "--command-args=")) {
            command_args = arg["--command-args=".len..];
        } else if (std.mem.startsWith(u8, arg, "--project-root=")) {
            project_root = arg["--project-root=".len..];
        } else {
            return error.InvalidBuildResolveFlag;
        }
    }

    return .{
        .path = path orelse return error.MissingBuildResolvePath,
        .filetype = filetype orelse return error.MissingBuildResolveFiletype,
        .command_name = command_name,
        .command_args = command_args,
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
    if (options.command_name != null) {
        try writeResolvedCommandOutput(stdout, allocator, options);
        return;
    }

    var parsed_output = try detected.resolveOutput(allocator, options);
    defer parsed_output.deinit(allocator);

    if (parsed_output.root) |root| {
        try stdout.print("ROOT\t{s}\n", .{root});
    }
    if (parsed_output.filetype) |filetype| {
        try stdout.print("FILETYPE\t{s}\n", .{filetype});
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
        try command.writeCommandUiMetadata(stdout, allocator, parsed_output.filetype orelse options.filetype, entry);
    }

    if (parsed_output.preferred.items.len == 0) {
        try detected.appendImplicitPreferred(allocator, &parsed_output.preferred, parsed_output.commands.items);
    }
    for (parsed_output.preferred.items) |entry| {
        try stdout.print("PREFERRED\t{s}\t{s}\n", .{ entry.name, entry.command });
    }
}

fn writeResolvedCommandOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options) !void {
    var parsed_output = try detected.resolveOutput(allocator, options);
    defer parsed_output.deinit(allocator);

    const resolved_filetype = parsed_output.filetype orelse options.filetype;
    const command_name = options.command_name orelse return error.MissingBuildResolveCommandName;
    const command_template = detected.findCommand(parsed_output.commands.items, command_name) orelse return error.UnknownBuildResolveCommand;
    const resolved_command = try command.resolveCommandTemplate(
        allocator,
        resolved_filetype,
        command_name,
        command_template,
        options.command_args,
    );
    defer allocator.free(resolved_command);

    if (command.isReservedArgvCommand(resolved_command)) {
        return error.ReservedBuildResolveArgvCommand;
    }

    const cwd = parsed_output.root orelse (std.fs.path.dirname(options.path) orelse options.path);
    try stdout.print("FILETYPE\t{s}\n", .{resolved_filetype});
    try stdout.print("CWD\t{s}\n", .{cwd});
    try stdout.print("NAME\t{s}: {s}\n", .{ resolved_filetype, command_name });
    try stdout.print("EXEC_COMMAND\t{s}\n", .{resolved_command});
    try stdout.print("CONFIG_REVISION\t{d}\n", .{config.getSyncedRevision()});
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

test "resolveOutput falls back to system commands when project auto output is unavailable" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{},"detect":{},"revision":11}
    , 11);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "uv.lock", .data = "" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.py" });
    defer allocator.free(filepath);

    var output = try detected.resolveOutput(allocator, .{
        .path = filepath,
        .filetype = "python",
        .project_root = root,
    });
    defer output.deinit(allocator);

    try std.testing.expectEqualStrings(root, output.root.?);
    try std.testing.expectEqualStrings("python", output.system.?);
    try std.testing.expectEqualStrings("uv run -m main", detected.findCommand(output.commands.items, "run").?);
    try std.testing.expectEqualStrings("uv sync", detected.findCommand(output.commands.items, "install").?);
}

test "resolveOutput preserves richer detected python commands over generic defaults" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"python":{"run":"python -m main","test":"pytest","install":"pip install -r requirements.txt"}},"detect":{},"revision":12}
    , 12);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "uv.lock", .data = "" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.py" });
    defer allocator.free(filepath);

    var output = try detected.resolveOutput(allocator, .{
        .path = filepath,
        .filetype = "python",
        .project_root = root,
    });
    defer output.deinit(allocator);

    try std.testing.expectEqualStrings("uv run -m main", detected.findCommand(output.commands.items, "run").?);
    try std.testing.expectEqualStrings("uv run pytest", detected.findCommand(output.commands.items, "test").?);
}

test "writeResolvedOutput emits implicit live preference when live command exists" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{},"detect":{"js_package_scripts":true},"revision":13}
    , 13);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "package.json", .data =
        \\{"scripts":{"dev":"vite","build":"vite build"}}
    });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.ts" });
    defer allocator.free(filepath);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try writeResolvedOutput(out.writer(allocator), allocator, .{
        .path = filepath,
        .filetype = "typescript",
        .project_root = root,
    });

    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tlive\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tlive\t") != null);
}

test "writeResolvedOutput emits command ui metadata for placeholder commands" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"zig":{"fetch":"zig fetch $zignite_args"}},"detect":{},"revision":21}
    , 21);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "build.zig", .data = "pub fn build(_: *anyopaque) void {}\n" });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "build.zig" });
    defer allocator.free(filepath);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try writeResolvedOutput(out.writer(allocator), allocator, .{
        .path = filepath,
        .filetype = "zig",
        .project_root = root,
    });

    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND_DISPLAY\tfetch\tzig fetch <args>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND_ARGS_REQUIRED\tfetch\t1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND_ARG_PROMPT\tfetch\tzig fetch url/path\n") != null);
}

test "writeResolvedOutput emits selected command execution metadata" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"rust":{"build":"cargo build"}},"detect":{},"revision":22}
    , 22);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "Cargo.toml", .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
    });
    try tmp.dir.writeFile(.{ .sub_path = "src/main.rs", .data = "fn main() {}\n" });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.rs" });
    defer allocator.free(filepath);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try writeResolvedOutput(out.writer(allocator), allocator, .{
        .path = filepath,
        .filetype = "rust",
        .project_root = root,
        .command_name = "build",
    });

    try std.testing.expect(std.mem.indexOf(u8, out.items, "NAME\trust: build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "EXEC_COMMAND\tcargo build\n") != null);
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
