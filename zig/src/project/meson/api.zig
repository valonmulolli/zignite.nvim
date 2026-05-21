const std = @import("std");
const intro = @import("intro.zig");
const parse = @import("parse.zig");

pub const Target = parse.Target;
pub const freeOwnedTargets = parse.freeOwnedTargets;

pub fn parseTargets(
    allocator: std.mem.Allocator,
    contents: []const u8,
    meson_build_path: []const u8,
    match_path: ?[]const u8,
) ![]Target {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return parseTargetsWithIO(threaded.io(), allocator, contents, meson_build_path, match_path);
}

pub fn parseTargetsWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    contents: []const u8,
    meson_build_path: []const u8,
    match_path: ?[]const u8,
) ![]Target {
    const introspected_targets = intro.parseTargetsWithIO(io, allocator, meson_build_path, match_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
    if (introspected_targets) |items| return items;
    return try parse.parseTargets(allocator, contents, meson_build_path, match_path);
}
