const std = @import("std");
const command_mode = @import("command_mode.zig");
const quickfix = @import("quickfix.zig");
const detect = @import("detect.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    if (hasFlag(args[1..], "--quickfix-daemon")) {
        try quickfix.runDaemon(allocator);
        return;
    }

    if (hasFlag(args[1..], "--detect-daemon")) {
        try detect.runDaemon(allocator);
        return;
    }

    if (hasFlag(args[1..], "--quickfix")) {
        const options = quickfix.parseArgs(args[1..]) catch |err| {
            std.log.err("Invalid quickfix options: {}", .{err});
            std.process.exit(1);
        };
        try quickfix.runMode(allocator, options);
        return;
    }

    if (hasFlag(args[1..], "--detect")) {
        const options = detect.parseArgs(args[1..]) catch |err| {
            std.log.err("Invalid detect options: {}", .{err});
            std.process.exit(1);
        };
        try detect.runMode(allocator, options);
        return;
    }

    try command_mode.run(allocator, args);
}

fn printUsage() void {
    std.log.err(
        \\Usage:
        \\  zignite [--timeout=MS] <full command string>
        \\  zignite [--timeout=MS] --argv <program> [args...]
        \\  zignite --quickfix [--max-lines=N] [--max-bytes=N] [--strip-ansi=0|1]
        \\                    [--strip-max-lines=N] [--parse-diagnostics=0|1]
        \\  zignite --quickfix-daemon
        \\  zignite --detect --tool=zig|go|cargo|odin
        \\  zignite --detect-daemon
    , .{});
}

fn hasFlag(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) {
            return true;
        }
    }
    return false;
}
