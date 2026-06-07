const std = @import("std");
const frame = @import("../../protocol/frame.zig");

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
    var begin = try frame.parseBeginFrame(line, BUILD_RESOLVE_REQ_BEGIN, error.InvalidBuildResolveDaemonHeader);
    if (begin.it.next() != null) return error.InvalidBuildResolveDaemonHeader;
    return .{ .request_id = begin.request_id };
}
