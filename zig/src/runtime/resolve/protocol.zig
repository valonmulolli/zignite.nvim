const std = @import("std");

pub const ResolveDaemonRequestHeader = struct {
    request_id: u64,
};

pub const RUN_RESOLVE_REQ_BEGIN = "@@ZRUN_REQ_BEGIN";
pub const RUN_RESOLVE_REQ_PAYLOAD_BEGIN = "@@ZRUN_REQ_PAYLOAD_BEGIN";
pub const RUN_RESOLVE_REQ_PAYLOAD_END = "@@ZRUN_REQ_PAYLOAD_END";
pub const RUN_RESOLVE_REQ_END = "@@ZRUN_REQ_END";
pub const RUN_RESOLVE_RES_BEGIN = "@@ZRUN_RES_BEGIN";
pub const RUN_RESOLVE_RES_END = "@@ZRUN_RES_END";
pub const RUN_RESOLVE_RES_ERR = "@@ZRUN_RES_ERR";
pub const RUN_RESOLVE_MAX_LINE = 16384;

pub fn parseResolveDaemonBegin(line: []const u8) !ResolveDaemonRequestHeader {
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
