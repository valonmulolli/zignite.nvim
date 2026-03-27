const std = @import("std");
const build_resolve = @import("build/resolve.zig");
const command = @import("command.zig");
const daemon = @import("daemon.zig");
const quickfix = @import("quickfix.zig");
const detect = @import("detect.zig");
const project = @import("project.zig");
const run_resolve = @import("runtime/resolve.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    if (hasFlag(args[1..], "--daemon")) {
        try daemon.run(allocator);
        return;
    }

    if (hasFlag(args[1..], "--quickfix-daemon")) {
        try quickfix.runDaemon(allocator);
        return;
    }

    if (hasFlag(args[1..], "--detect-daemon")) {
        try detect.runDaemon(allocator);
        return;
    }

    if (hasFlag(args[1..], "--project-parse-daemon")) {
        try project.runDaemon(allocator);
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

    if (hasFlag(args[1..], "--project-parse")) {
        const options = project.parseArgs(args[1..]) catch |err| {
            std.log.err("Invalid project-parse options: {}", .{err});
            std.process.exit(1);
        };
        try project.runMode(allocator, options);
        return;
    }

    if (hasFlag(args[1..], "--build-resolve")) {
        const options = build_resolve.parseArgs(args[1..]) catch |err| {
            std.log.err("Invalid build-resolve options: {}", .{err});
            std.process.exit(1);
        };
        try build_resolve.runMode(allocator, options);
        return;
    }

    if (hasFlag(args[1..], "--run-resolve")) {
        const options = run_resolve.parseArgs(args[1..]) catch |err| {
            std.log.err("Invalid run-resolve options: {}", .{err});
            std.process.exit(1);
        };
        try run_resolve.runMode(allocator, options);
        return;
    }

    try command.run(allocator, args);
}

fn printUsage() void {
    std.log.err(
        \\Usage:
        \\  zignite [--timeout=MS] <full command string>
        \\  zignite [--timeout=MS] --argv <program> [args...]
        \\  zignite --daemon
        \\  zignite --quickfix [--max-lines=N] [--max-bytes=N] [--strip-ansi=0|1]
        \\                    [--strip-max-lines=N] [--parse-diagnostics=0|1]
        \\  zignite --quickfix-daemon
        \\  zignite --detect --tool=zig|go|cargo|odin
        \\  zignite --detect-daemon
        \\  zignite --project-parse-daemon
        \\  zignite --project-parse --kind=make|package-json|maven|gradle|cmake|bazel|bazel-workspace|meson|cargo|pyproject|go|go-mod|go-work --path=/abs/path
        \\  zignite --build-resolve --filetype=<ft> --path=/abs/path
        \\  zignite --run-resolve --filetype=<ft> --path=/abs/path
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
