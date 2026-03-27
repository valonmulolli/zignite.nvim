const std = @import("std");

const page_allocator = std.heap.page_allocator;

var synced_revision: u64 = 0;
var synced_json: ?[]u8 = null;

pub fn setSyncedConfigJson(json: []const u8, revision: u64) !void {
    const owned = try page_allocator.dupe(u8, json);
    errdefer page_allocator.free(owned);

    if (synced_json) |previous| {
        page_allocator.free(previous);
    }

    synced_json = owned;
    synced_revision = revision;
}

pub fn getSyncedConfigJson() ?[]const u8 {
    return synced_json;
}

pub fn getSyncedRevision() u64 {
    return synced_revision;
}

pub fn reset() void {
    if (synced_json) |previous| {
        page_allocator.free(previous);
    }
    synced_json = null;
    synced_revision = 0;
}
