const std = @import("std");

pub const ResolveDaemonRequestHeader = struct {
    request_id: u64,
};

pub const BUILD_RESOLVE_REQ_BEGIN = "@@ZBR_REQ_BEGIN";
pub const BUILD_RESOLVE_REQ_END = "@@ZBR_REQ_END";
pub const BUILD_RESOLVE_RES_BEGIN = "@@ZBR_RES_BEGIN";
pub const BUILD_RESOLVE_RES_END = "@@ZBR_RES_END";
pub const BUILD_RESOLVE_RES_ERR = "@@ZBR_RES_ERR";
pub const BUILD_RESOLVE_MAX_LINE = 16384;

pub fn parseResolveDaemonBegin(line: []const u8) !ResolveDaemonRequestHeader {
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
