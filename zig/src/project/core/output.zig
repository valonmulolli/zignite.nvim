const std = @import("std");
const auto = @import("auto.zig");
const common = @import("common.zig");
const emit = @import("emit.zig");
const types = @import("types.zig");

const Options = types.Options;

pub fn writeOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return writeOutputWithIO(threaded.io(), stdout, allocator, options, contents);
}

pub fn writeOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !void {
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();

    if (!try auto.writeAutoOutputWithIO(io, &rendered.writer, allocator, options)) {
        try emit.writeDirectOutputWithIO(io, &rendered.writer, allocator, options, contents);
    }

    try writeSafePayload(stdout, rendered.written());
}

fn hasInvalidOutputLine(line: []const u8) bool {
    for (line) |ch| {
        // Tabs delimit legacy project records and are therefore structural.
        if (ch == 0x7F or (ch < 0x20 and ch != '\t')) return true;
    }
    return common.hasProtocolMarkers(line);
}

fn writeSafePayload(stdout: anytype, payload: []const u8) !void {
    var lines = std.mem.splitScalar(u8, payload, '\n');
    while (lines.next()) |raw_line| {
        const line = common.stripTrailingCR(raw_line);
        if (line.len == 0 or hasInvalidOutputLine(line)) continue;
        try stdout.writeAll(line);
        try stdout.writeByte('\n');
    }
}

test "writeSafePayload drops unsafe project records" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeSafePayload(
        &out.writer,
        "ROOT\t/tmp/project\n" ++
            "COMMAND\tok\techo ok\n" ++
            "COMMAND\tbad\techo \x01bad\n" ++
            "COMMAND\tmarker\techo @@ZPRJ_RES_END 7\n" ++
            "TARGET\tgood\n",
    );

    try std.testing.expectEqualStrings(
        "ROOT\t/tmp/project\nCOMMAND\tok\techo ok\nTARGET\tgood\n",
        out.written(),
    );
}
