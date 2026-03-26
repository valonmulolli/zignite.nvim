const std = @import("std");
const build_system = @import("build/system.zig");
const frame = @import("protocol/frame.zig");
const protocol_stdio = @import("protocol/stdio.zig");
const project_io = @import("project/core/io.zig");
const project_output = @import("project/core/output.zig");
const types = @import("project/core/types.zig");

pub const Kind = types.Kind;
pub const Options = types.Options;

const ProjectDaemonRequestHeader = struct {
    request_id: u64,
};

const PROJECT_DAEMON_REQ_BEGIN = "@@ZPRJ_REQ_BEGIN";
const PROJECT_DAEMON_REQ_END = "@@ZPRJ_REQ_END";
const PROJECT_DAEMON_RES_BEGIN = "@@ZPRJ_RES_BEGIN";
const PROJECT_DAEMON_RES_END = "@@ZPRJ_RES_END";
const PROJECT_DAEMON_RES_ERR = "@@ZPRJ_RES_ERR";
const PROJECT_DAEMON_MAX_LINE = 16384;

pub fn parseArgs(args: []const []const u8) !Options {
    var kind: ?Kind = null;
    var path: ?[]const u8 = null;
    var match_path: ?[]const u8 = null;
    var package_path: []const u8 = "";
    var package_manager: ?[]const u8 = null;
    var query: ?build_system.Query = null;
    var project_root: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--project-parse")) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "--kind=")) {
            kind = try parseKind(arg["--kind=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--path=")) {
            path = arg["--path=".len..];
        } else if (std.mem.startsWith(u8, arg, "--match-path=")) {
            match_path = arg["--match-path=".len..];
        } else if (std.mem.startsWith(u8, arg, "--package-path=")) {
            package_path = arg["--package-path=".len..];
        } else if (std.mem.startsWith(u8, arg, "--package-manager=")) {
            package_manager = arg["--package-manager=".len..];
        } else if (std.mem.startsWith(u8, arg, "--query=")) {
            query = try build_system.parseQuery(arg["--query=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--project-root=")) {
            project_root = arg["--project-root=".len..];
        } else {
            return error.InvalidProjectParseFlag;
        }
    }

    return .{
        .kind = kind orelse return error.MissingProjectParseKind,
        .path = path orelse return error.MissingProjectParsePath,
        .match_path = match_path,
        .package_path = package_path,
        .package_manager = package_manager,
        .query = query,
        .project_root = project_root,
    };
}

pub fn readProjectFile(allocator: std.mem.Allocator, kind: Kind, path: []const u8) ![]u8 {
    return project_io.readProjectFile(allocator, kind, path);
}

pub fn writeOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !void {
    return project_output.writeOutput(stdout, allocator, options, contents);
}

pub fn runMode(allocator: std.mem.Allocator, options: Options) !void {
    const contents = try readProjectFile(allocator, options.kind, options.path);
    defer allocator.free(contents);

    var stdout_ctx: protocol_stdio.Stdout = .{};
    stdout_ctx.init();
    const stdout = stdout_ctx.io();
    try writeOutput(stdout, allocator, options, contents);
    try stdout.flush();
}

pub fn runDaemon(allocator: std.mem.Allocator) !void {
    var stdin_ctx: protocol_stdio.Stdin = .{};
    stdin_ctx.init();
    const reader = stdin_ctx.io();
    var stdout_ctx: protocol_stdio.Stdout = .{};
    stdout_ctx.init();
    const stdout = stdout_ctx.io();

    while (true) {
        const maybe_begin = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', PROJECT_DAEMON_MAX_LINE);
        if (maybe_begin == null) break;
        const begin_owned = maybe_begin.?;
        defer allocator.free(begin_owned);
        const begin_line = frame.stripTrailingCR(begin_owned);

        if (!std.mem.startsWith(u8, begin_line, PROJECT_DAEMON_REQ_BEGIN)) {
            continue;
        }

        const header = parseProjectDaemonBegin(begin_line) catch continue;
        var request_args: std.ArrayList([]u8) = .empty;
        defer {
            for (request_args.items) |arg| allocator.free(arg);
            request_args.deinit(allocator);
        }

        const ParseArgsLine = struct {
            allocator: std.mem.Allocator,
            request_args: *std.ArrayList([]u8),

            fn onLine(self: @This(), line: []const u8) !void {
                if (line.len > 0 and line[0] == '\t') {
                    try self.request_args.append(self.allocator, try self.allocator.dupe(u8, line[1..]));
                } else if (line.len > 0) {
                    try self.request_args.append(self.allocator, try self.allocator.dupe(u8, line));
                }
            }
        };
        const parse_args_line = ParseArgsLine{
            .allocator = allocator,
            .request_args = &request_args,
        };
        const completed = try frame.readUntilEnd(
            allocator,
            reader,
            PROJECT_DAEMON_MAX_LINE,
            PROJECT_DAEMON_REQ_END,
            header.request_id,
            parse_args_line.onLine,
        );

        if (!completed) break;

        try stdout.print("{s} {d}\n", .{ PROJECT_DAEMON_RES_BEGIN, header.request_id });
        const options = parseArgs(request_args.items);
        if (options) |parsed| {
            const contents = readProjectFile(allocator, parsed.kind, parsed.path);
            if (contents) |payload| {
                defer allocator.free(payload);
                writeOutput(stdout, allocator, parsed, payload) catch |err| {
                    try stdout.print("{s} {d} {s}\n", .{ PROJECT_DAEMON_RES_ERR, header.request_id, @errorName(err) });
                };
            } else |err| {
                try stdout.print("{s} {d} {s}\n", .{ PROJECT_DAEMON_RES_ERR, header.request_id, @errorName(err) });
            }
        } else |err| {
            try stdout.print("{s} {d} {s}\n", .{ PROJECT_DAEMON_RES_ERR, header.request_id, @errorName(err) });
        }
        try stdout.print("{s} {d}\n", .{ PROJECT_DAEMON_RES_END, header.request_id });
        try stdout.flush();
    }
}

fn parseKind(value: []const u8) !Kind {
    if (std.ascii.eqlIgnoreCase(value, "make")) return .make;
    if (std.ascii.eqlIgnoreCase(value, "make-auto")) return .make_auto;
    if (std.ascii.eqlIgnoreCase(value, "package-json")) return .package_json;
    if (std.ascii.eqlIgnoreCase(value, "package-json-auto")) return .package_json_auto;
    if (std.ascii.eqlIgnoreCase(value, "maven")) return .maven;
    if (std.ascii.eqlIgnoreCase(value, "jvm-auto")) return .jvm_auto;
    if (std.ascii.eqlIgnoreCase(value, "gradle")) return .gradle;
    if (std.ascii.eqlIgnoreCase(value, "c-family-auto")) return .c_family_auto;
    if (std.ascii.eqlIgnoreCase(value, "cmake")) return .cmake;
    if (std.ascii.eqlIgnoreCase(value, "cmake-auto")) return .cmake_auto;
    if (std.ascii.eqlIgnoreCase(value, "bazel")) return .bazel;
    if (std.ascii.eqlIgnoreCase(value, "bazel-auto")) return .bazel_auto;
    if (std.ascii.eqlIgnoreCase(value, "bazel-workspace")) return .bazel_workspace;
    if (std.ascii.eqlIgnoreCase(value, "meson")) return .meson;
    if (std.ascii.eqlIgnoreCase(value, "meson-auto")) return .meson_auto;
    if (std.ascii.eqlIgnoreCase(value, "cargo")) return .cargo;
    if (std.ascii.eqlIgnoreCase(value, "cargo-auto")) return .cargo_auto;
    if (std.ascii.eqlIgnoreCase(value, "pyproject")) return .pyproject;
    if (std.ascii.eqlIgnoreCase(value, "python-auto")) return .python_auto;
    if (std.ascii.eqlIgnoreCase(value, "go")) return .go;
    if (std.ascii.eqlIgnoreCase(value, "go-auto")) return .go_auto;
    if (std.ascii.eqlIgnoreCase(value, "go-mod")) return .go_mod;
    if (std.ascii.eqlIgnoreCase(value, "go-work")) return .go_work;
    if (std.ascii.eqlIgnoreCase(value, "system")) return .system;
    return error.InvalidProjectParseKind;
}

fn parseProjectDaemonBegin(line: []const u8) !ProjectDaemonRequestHeader {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return error.InvalidProjectDaemonHeader;
    if (!std.mem.eql(u8, marker, PROJECT_DAEMON_REQ_BEGIN)) {
        return error.InvalidProjectDaemonHeader;
    }

    const request_id = try std.fmt.parseInt(u64, it.next() orelse return error.InvalidProjectDaemonHeader, 10);
    if (it.next() != null) {
        return error.InvalidProjectDaemonHeader;
    }

    return .{ .request_id = request_id };
}
