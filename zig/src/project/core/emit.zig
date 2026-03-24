const std = @import("std");
const build_emit = @import("emit/build.zig");
const lang_emit = @import("emit/lang.zig");
const types = @import("types.zig");

const Options = types.Options;

pub fn writeDirectOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !void {
    if (try build_emit.writeBuildOutput(stdout, allocator, options, contents)) return;
    if (try lang_emit.writeLanguageOutput(stdout, allocator, options, contents)) return;
    return error.InvalidProjectParseKind;
}
