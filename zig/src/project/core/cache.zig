const std = @import("std");
const types = @import("types.zig");

const page_allocator = std.heap.page_allocator;
const max_cache_entries = 256;
const Options = types.Options;

const CacheEntry = struct {
    signature: []u8,
    output: []u8,
};

var cache_arena = std.heap.ArenaAllocator.init(page_allocator);
var auto_output_cache: std.StringHashMap(CacheEntry) = undefined;
var cache_initialized = false;

pub fn getAutoOutput(options: Options, signature: []const u8) !?[]const u8 {
    ensureCacheInit();

    const cache_key = try cacheKeyAlloc(page_allocator, options);
    defer page_allocator.free(cache_key);

    const entry = auto_output_cache.get(cache_key) orelse return null;
    if (!std.mem.eql(u8, entry.signature, signature)) return null;
    return entry.output;
}

pub fn storeAutoOutput(options: Options, signature: []const u8, output: []const u8) !void {
    ensureCacheInit();

    const cache_key = try cacheKeyAlloc(page_allocator, options);
    errdefer page_allocator.free(cache_key);

    if (auto_output_cache.get(cache_key) == null and auto_output_cache.count() >= max_cache_entries) {
        resetCache();
        ensureCacheInit();
    }

    const cache_allocator = cache_arena.allocator();
    const owned_key = try cache_allocator.dupe(u8, cache_key);
    const owned_signature = try cache_allocator.dupe(u8, signature);
    const owned_output = try cache_allocator.dupe(u8, output);

    try auto_output_cache.put(owned_key, .{
        .signature = owned_signature,
        .output = owned_output,
    });

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
    auto_output_cache = std.StringHashMap(CacheEntry).init(cache_arena.allocator());
    cache_initialized = true;
}

fn resetCache() void {
    if (!cache_initialized) return;
    auto_output_cache.deinit();
    cache_arena.deinit();
    cache_arena = std.heap.ArenaAllocator.init(page_allocator);
    auto_output_cache = std.StringHashMap(CacheEntry).init(cache_arena.allocator());
    cache_initialized = true;
}
