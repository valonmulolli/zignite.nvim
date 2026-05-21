const std = @import("std");
const build_action = @import("build/action.zig");
const build_resolve = @import("build/resolve.zig");
const command = @import("command.zig");
const config = @import("config.zig");
const daemon = @import("daemon.zig");
const quickfix = @import("quickfix.zig");
const detect = @import("detect.zig");
const project = @import("project.zig");
const run_resolve = @import("runtime/resolve.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    if (hasFlag(args[1..], "--daemon")) {
        try daemon.run(allocator, io, init.environ_map);
        return;
    }

    if (hasFlag(args[1..], "--config-sync")) {
        const options = config.parseArgs(args[1..]) catch |err| {
            std.log.err("Invalid config-sync options: {}", .{err});
            std.process.exit(1);
        };
        try config.runMode(allocator, io, options);
        return;
    }

    if (hasFlag(args[1..], "--quickfix-daemon")) {
        try quickfix.runDaemon(allocator, io);
        return;
    }

    if (hasFlag(args[1..], "--detect-daemon")) {
        try detect.runDaemon(allocator, io);
        return;
    }

    if (hasFlag(args[1..], "--project-parse-daemon")) {
        try project.runDaemon(allocator, io);
        return;
    }

    if (hasFlag(args[1..], "--quickfix")) {
        const options = quickfix.parseArgs(args[1..]) catch |err| {
            std.log.err("Invalid quickfix options: {}", .{err});
            std.process.exit(1);
        };
        try quickfix.runMode(allocator, io, options);
        return;
    }

    if (hasFlag(args[1..], "--detect")) {
        const options = detect.parseArgs(args[1..]) catch |err| {
            std.log.err("Invalid detect options: {}", .{err});
            std.process.exit(1);
        };
        try detect.runMode(allocator, io, options);
        return;
    }

    if (hasFlag(args[1..], "--project-parse")) {
        const options = project.parseArgs(args[1..]) catch |err| {
            std.log.err("Invalid project-parse options: {}", .{err});
            std.process.exit(1);
        };
        try project.runMode(allocator, io, options);
        return;
    }

    if (hasFlag(args[1..], "--build-resolve")) {
        const options = build_resolve.parseArgs(args[1..]) catch |err| {
            std.log.err("Invalid build-resolve options: {}", .{err});
            std.process.exit(1);
        };
        try build_resolve.runModeWithEnviron(allocator, io, init.environ_map, options);
        return;
    }

    if (hasFlag(args[1..], "--build-action")) {
        const options = build_action.parseArgs(args[1..]) catch |err| {
            std.log.err("Invalid build-action options: {}", .{err});
            std.process.exit(1);
        };
        try build_action.runModeWithEnviron(allocator, io, init.environ_map, options);
        return;
    }

    if (hasFlag(args[1..], "--run-resolve")) {
        const options = run_resolve.parseArgs(args[1..]) catch |err| {
            std.log.err("Invalid run-resolve options: {}", .{err});
            std.process.exit(1);
        };
        try run_resolve.runMode(allocator, io, init.environ_map, options);
        return;
    }

    try command.run(io, args);
}

fn printUsage() void {
    std.log.err(
        \\Usage:
        \\  zignite [--timeout=MS] <full command string>
        \\  zignite [--timeout=MS] [--cleanup=CMD] --argv <program> [args...]
        \\  zignite [--timeout=MS] [--cleanup=CMD] <full command string>
        \\  zignite --daemon
        \\  zignite --config-sync --revision=<N>
        \\  zignite --quickfix [--max-lines=N] [--max-bytes=N] [--strip-ansi=0|1]
        \\                    [--strip-max-lines=N] [--parse-diagnostics=0|1]
        \\  zignite --quickfix-daemon
        \\  zignite --detect --tool=zig|go|cargo|odin
        \\  zignite --detect-daemon
        \\  zignite --project-parse-daemon
        \\  zignite --project-parse --kind=make|package-json|maven|gradle|cmake|bazel|bazel-workspace|meson|cargo|pyproject|go|go-mod|go-work --path=/abs/path
        \\  zignite --build-resolve --filetype=<ft> --path=/abs/path
        \\  zignite --build-action --action=named|live|last --filetype=<ft> --path=/abs/path
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
