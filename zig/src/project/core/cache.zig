const std = @import("std");
const types = @import("types.zig");

const page_allocator = std.heap.page_allocator;
const max_cache_entries = 256;
const Options = types.Options;

const CacheEntry = struct {
    signature: []u8,
    output: []u8,
};

var auto_output_cache: std.StringHashMap(CacheEntry) = undefined;
var cache_initialized = false;

pub fn getAutoOutput(allocator: std.mem.Allocator, options: Options, signature: []const u8) !?[]u8 {
    ensureCacheInit();

    const cache_key = try cacheKeyAlloc(page_allocator, options);
    defer page_allocator.free(cache_key);

    const entry = auto_output_cache.get(cache_key) orelse return null;
    if (!std.mem.eql(u8, entry.signature, signature)) return null;
    return try allocator.dupe(u8, entry.output);
}

pub fn storeAutoOutput(options: Options, signature: []const u8, output: []const u8) !void {
    ensureCacheInit();

    const cache_key = try cacheKeyAlloc(page_allocator, options);
    errdefer page_allocator.free(cache_key);

    if (auto_output_cache.get(cache_key) == null and auto_output_cache.count() >= max_cache_entries) {
        resetCache();
        ensureCacheInit();
    }

    const cache_allocator = page_allocator;
    const owned_key = try cache_allocator.dupe(u8, cache_key);
    errdefer cache_allocator.free(owned_key);
    const owned_signature = try cache_allocator.dupe(u8, signature);
    errdefer cache_allocator.free(owned_signature);
    const owned_output = try cache_allocator.dupe(u8, output);
    errdefer cache_allocator.free(owned_output);

    if (try auto_output_cache.fetchPut(owned_key, .{
        .signature = owned_signature,
        .output = owned_output,
    })) |old| {
        // Replacements return the old value but do not retain the new key.
        cache_allocator.free(owned_key);
        cache_allocator.free(old.value.signature);
        cache_allocator.free(old.value.output);
    }

    page_allocator.free(cache_key);
}

pub fn resetForTests() void {
    resetCache();
}

fn cacheKeyAlloc(allocator: std.mem.Allocator, options: Options) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}\x1f{s}", .{
        @tagName(options.kind),
        options.path,
        options.match_path orelse "",
        options.project_root orelse "",
    });
}

fn ensureCacheInit() void {
    if (cache_initialized) return;
    auto_output_cache = std.StringHashMap(CacheEntry).init(page_allocator);
    cache_initialized = true;
}

fn resetCache() void {
    if (!cache_initialized) return;
    var it = auto_output_cache.iterator();
    while (it.next()) |entry| {
        page_allocator.free(entry.key_ptr.*);
        page_allocator.free(entry.value_ptr.*.signature);
        page_allocator.free(entry.value_ptr.*.output);
    }
    auto_output_cache.deinit();
    auto_output_cache = std.StringHashMap(CacheEntry).init(page_allocator);
    cache_initialized = true;
}
