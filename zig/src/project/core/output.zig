const std = @import("std");
const auto = @import("auto.zig");
const emit = @import("emit.zig");
const types = @import("types.zig");

const Options = types.Options;

pub fn writeOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return writeOutputWithIO(threaded.io(), stdout, allocator, options, contents);
}

pub fn writeOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !void {
    if (try auto.writeAutoOutputWithIO(io, stdout, allocator, options)) {
        return;
    }
    try emit.writeDirectOutputWithIO(io, stdout, allocator, options, contents);
}
