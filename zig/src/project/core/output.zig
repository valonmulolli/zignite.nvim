const std = @import("std");
const auto = @import("auto.zig");
const emit = @import("emit.zig");
const types = @import("types.zig");

const Options = types.Options;

pub fn writeOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !void {
    if (try auto.writeAutoOutput(stdout, allocator, options)) {
        return;
    }
    try emit.writeDirectOutput(stdout, allocator, options, contents);
}
