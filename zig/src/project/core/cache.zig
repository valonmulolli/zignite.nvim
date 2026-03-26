const std = @import("std");
const types = @import("types.zig");

const page_allocator = std.heap.page_allocator;
const Options = types.Options;

const CacheEntry = struct {
    signature: []u8,
    output: []u8,
};

var auto_output_cache: std.StringHashMap(CacheEntry) = .init(page_allocator);

pub fn getAutoOutput(options: Options, signature: []const u8) !?[]const u8 {
    const cache_key = try cacheKeyAlloc(page_allocator, options);
    defer page_allocator.free(cache_key);

    const entry = auto_output_cache.get(cache_key) orelse return null;
    if (!std.mem.eql(u8, entry.signature, signature)) return null;
    return entry.output;
}

pub fn storeAutoOutput(options: Options, signature: []const u8, output: []const u8) !void {
    const cache_key = try cacheKeyAlloc(page_allocator, options);
    errdefer page_allocator.free(cache_key);

    const owned_signature = try page_allocator.dupe(u8, signature);
    errdefer page_allocator.free(owned_signature);
    const owned_output = try page_allocator.dupe(u8, output);
    errdefer page_allocator.free(owned_output);

    const gop = try auto_output_cache.getOrPut(cache_key);
    if (gop.found_existing) {
        page_allocator.free(cache_key);
        page_allocator.free(gop.value_ptr.signature);
        page_allocator.free(gop.value_ptr.output);
    } else {
        gop.key_ptr.* = cache_key;
    }
    gop.value_ptr.* = .{
        .signature = owned_signature,
        .output = owned_output,
    };
}

pub fn resetForTests() void {
    var iterator = auto_output_cache.iterator();
    while (iterator.next()) |entry| {
        page_allocator.free(entry.key_ptr.*);
        page_allocator.free(entry.value_ptr.signature);
        page_allocator.free(entry.value_ptr.output);
    }
    auto_output_cache.clearRetainingCapacity();
}

fn cacheKeyAlloc(allocator: std.mem.Allocator, options: Options) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}\x1f{s}", .{
        @tagName(options.kind),
        options.path,
        options.match_path orelse "",
        options.project_root orelse "",
    });
}
