const std = @import("std");
const command = @import("command.zig");
const dispatch = @import("dispatch.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    if (try dispatch.handleCliFlags(allocator, io, init.environ_map, args[1..])) return;

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
