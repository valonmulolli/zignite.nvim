const std = @import("std");

pub const CommonPathArgs = struct {
    path: ?[]const u8 = null,
    filetype: ?[]const u8 = null,
    project_root: ?[]const u8 = null,
};

pub const ConfigArgs = struct {
    stdin: bool = false,
    revision: ?u64 = null,
};

pub fn parseConfigArg(config: *ConfigArgs, arg: []const u8) !bool {
    if (std.mem.eql(u8, arg, "--config-stdin")) {
        config.stdin = true;
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--config-revision=")) {
        config.revision = try std.fmt.parseInt(u64, arg["--config-revision=".len..], 10);
        return true;
    }
    return false;
}

pub fn validateConfigArgs(config: ConfigArgs) !void {
    if (config.stdin and (config.revision == null or config.revision.? == 0)) return error.MissingConfigRevision;
    if (!config.stdin and config.revision != null) return error.UnexpectedConfigRevision;
}

pub fn parseCommonPathArg(
    common: *CommonPathArgs,
    arg: []const u8,
    mode_flag: []const u8,
) !bool {
    if (std.mem.eql(u8, arg, mode_flag)) {
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--path=")) {
        common.path = arg["--path=".len..];
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--filetype=")) {
        common.filetype = arg["--filetype=".len..];
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--project-root=")) {
        common.project_root = arg["--project-root=".len..];
        return true;
    }
    return false;
}

test "parseCommonPathArg parses shared flags" {
    var common: CommonPathArgs = .{};

    try std.testing.expect(try parseCommonPathArg(&common, "--build-resolve", "--build-resolve"));
    try std.testing.expect(try parseCommonPathArg(&common, "--path=/tmp/main.zig", "--build-resolve"));
    try std.testing.expect(try parseCommonPathArg(&common, "--filetype=zig", "--build-resolve"));
    try std.testing.expect(try parseCommonPathArg(&common, "--project-root=/tmp", "--build-resolve"));

    try std.testing.expectEqualStrings("/tmp/main.zig", common.path.?);
    try std.testing.expectEqualStrings("zig", common.filetype.?);
    try std.testing.expectEqualStrings("/tmp", common.project_root.?);
}

test "parseCommonPathArg leaves unrelated flag untouched" {
    var common: CommonPathArgs = .{};

    try std.testing.expect(!(try parseCommonPathArg(&common, "--context-path=/tmp/src", "--run-resolve")));
    try std.testing.expect(common.path == null);
    try std.testing.expect(common.filetype == null);
    try std.testing.expect(common.project_root == null);
}

test "parseConfigArg parses one-shot config flags" {
    var config: ConfigArgs = .{};

    try std.testing.expect(try parseConfigArg(&config, "--config-stdin"));
    try std.testing.expect(try parseConfigArg(&config, "--config-revision=42"));
    try validateConfigArgs(config);

    try std.testing.expect(config.stdin);
    try std.testing.expectEqual(@as(u64, 42), config.revision.?);
}

test "validateConfigArgs rejects incomplete one-shot config flags" {
    try std.testing.expectError(error.MissingConfigRevision, validateConfigArgs(.{ .stdin = true }));
    try std.testing.expectError(error.MissingConfigRevision, validateConfigArgs(.{ .stdin = true, .revision = 0 }));
    try std.testing.expectError(error.UnexpectedConfigRevision, validateConfigArgs(.{ .revision = 42 }));
}
