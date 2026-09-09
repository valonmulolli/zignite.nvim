const std = @import("std");
const frame = @import("../../protocol/frame.zig");
const protocol_args = @import("../../protocol/args.zig");
const types = @import("types.zig");

pub const BUILD_ACTION_REQ_BEGIN = "@@ZBA_REQ_BEGIN";
pub const BUILD_ACTION_REQ_END = "@@ZBA_REQ_END";
pub const BUILD_ACTION_RES_BEGIN = "@@ZBA_RES_BEGIN";
pub const BUILD_ACTION_RES_END = "@@ZBA_RES_END";
pub const BUILD_ACTION_RES_ERR = "@@ZBA_RES_ERR";
pub const BUILD_ACTION_MAX_LINE = 16 * 1024 * 1024;

pub fn parseArgs(args: []const []const u8) !types.Options {
    var common: protocol_args.CommonPathArgs = .{};
    var config_args: protocol_args.ConfigArgs = .{};
    var action: ?types.Action = null;
    var command_name: ?[]const u8 = null;
    var command_args: ?[]const u8 = null;

    for (args) |arg| {
        if (try protocol_args.parseCommonPathArg(&common, arg, "--build-action")) {
            continue;
        }
        if (try protocol_args.parseConfigArg(&config_args, arg)) {
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--action=")) {
            const value = arg["--action=".len..];
            if (std.mem.eql(u8, value, "named")) {
                action = .named;
            } else if (std.mem.eql(u8, value, "live")) {
                action = .live;
            } else if (std.mem.eql(u8, value, "last")) {
                action = .last;
            } else {
                return error.InvalidBuildActionKind;
            }
        } else if (std.mem.startsWith(u8, arg, "--command-name=")) {
            command_name = arg["--command-name=".len..];
        } else if (std.mem.startsWith(u8, arg, "--command-args=")) {
            command_args = arg["--command-args=".len..];
        } else {
            return error.InvalidBuildActionFlag;
        }
    }

    try protocol_args.validateConfigArgs(config_args);

    return .{
        .path = common.path orelse return error.MissingBuildActionPath,
        .filetype = common.filetype orelse return error.MissingBuildActionFiletype,
        .action = action orelse return error.MissingBuildActionKind,
        .command_name = command_name,
        .command_args = command_args,
        .project_root = common.project_root,
        .config_stdin = config_args.stdin,
        .config_revision = config_args.revision,
    };
}

pub const DaemonHeader = struct {
    request_id: u64,
};

pub fn parseDaemonBegin(line: []const u8) !DaemonHeader {
    var begin = try frame.parseBeginFrame(line, BUILD_ACTION_REQ_BEGIN, error.InvalidBuildActionDaemonHeader);
    if (begin.it.next() != null) return error.InvalidBuildActionDaemonHeader;
    return .{ .request_id = begin.request_id };
}

test "parseArgs accepts one-shot config flags" {
    const options = try parseArgs(&.{
        "--build-action",
        "--path=/tmp/build.zig",
        "--filetype=zig",
        "--action=named",
        "--command-name=build",
        "--config-stdin",
        "--config-revision=44",
    });

    try std.testing.expect(options.config_stdin);
    try std.testing.expectEqual(@as(u64, 44), options.config_revision.?);
}
