const std = @import("std");
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
    var action: ?types.Action = null;
    var command_name: ?[]const u8 = null;
    var command_args: ?[]const u8 = null;

    for (args) |arg| {
        if (try protocol_args.parseCommonPathArg(&common, arg, "--build-action")) {
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

    return .{
        .path = common.path orelse return error.MissingBuildActionPath,
        .filetype = common.filetype orelse return error.MissingBuildActionFiletype,
        .action = action orelse return error.MissingBuildActionKind,
        .command_name = command_name,
        .command_args = command_args,
        .project_root = common.project_root,
    };
}

pub const DaemonHeader = struct {
    request_id: u64,
};

pub fn parseDaemonBegin(line: []const u8) !DaemonHeader {
    const prefix = BUILD_ACTION_REQ_BEGIN ++ " ";
    if (!std.mem.startsWith(u8, line, prefix)) {
        return error.InvalidBuildActionDaemonHeader;
    }
    const remainder = line[prefix.len..];
    if (remainder.len == 0) return error.InvalidBuildActionDaemonHeader;
    if (std.mem.findScalar(u8, remainder, ' ')) |_| {
        return error.InvalidBuildActionDaemonHeader;
    }
    return .{
        .request_id = try std.fmt.parseInt(u64, remainder, 10),
    };
}
