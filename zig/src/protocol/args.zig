const std = @import("std");

pub const CommonPathArgs = struct {
    path: ?[]const u8 = null,
    filetype: ?[]const u8 = null,
    project_root: ?[]const u8 = null,
};

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
