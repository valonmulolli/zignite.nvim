const std = @import("std");

const page_allocator = std.heap.page_allocator;

var synced_revision: u64 = 0;
var synced_generation: u64 = 0;
var synced_json: ?[]u8 = null;

pub fn setSyncedConfigJson(json: []const u8, revision: u64) !void {
    const owned = try page_allocator.dupe(u8, json);
    errdefer page_allocator.free(owned);

    if (synced_json) |previous| {
        page_allocator.free(previous);
    }

    synced_json = owned;
    synced_revision = revision;
    synced_generation +%= 1;
}

pub fn getSyncedConfigJson() ?[]const u8 {
    return synced_json;
}

pub fn getSyncedRevision() u64 {
    return synced_revision;
}

pub fn getSyncedGeneration() u64 {
    return synced_generation;
}

pub fn reset() void {
    if (synced_json) |previous| {
        page_allocator.free(previous);
    }
    synced_json = null;
    synced_revision = 0;
    synced_generation +%= 1;
}

test "store: set/get/reset" {
    reset();
    try std.testing.expectEqual(@as(u64, 0), getSyncedRevision());
    try std.testing.expectEqual(@as(?[]const u8, null), getSyncedConfigJson());

    try setSyncedConfigJson("{\"foo\":1}", 42);
    try std.testing.expectEqual(@as(u64, 42), getSyncedRevision());
    try std.testing.expectEqualStrings("{\"foo\":1}", getSyncedConfigJson().?);

    try setSyncedConfigJson("bar", 99);
    try std.testing.expectEqual(@as(u64, 99), getSyncedRevision());
    try std.testing.expectEqualStrings("bar", getSyncedConfigJson().?);

    reset();
    try std.testing.expectEqual(@as(u64, 0), getSyncedRevision());
    try std.testing.expectEqual(@as(?[]const u8, null), getSyncedConfigJson());
}

test "store: reset after set increments generation" {
    reset();
    const gen = getSyncedGeneration();
    reset();
    try std.testing.expect(gen +% 1 == getSyncedGeneration());
    reset();
    try std.testing.expect(gen +% 2 == getSyncedGeneration());
}
