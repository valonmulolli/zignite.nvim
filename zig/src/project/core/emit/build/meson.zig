const std = @import("std");
const build_common = @import("../../../../build/common.zig");
const meson = @import("../../../meson/api.zig");
const pathing = @import("../../../../pathing.zig");
const project_common = @import("../../common.zig");
const shared = @import("shared.zig");
const types = @import("../../types.zig");

const Options = types.Options;

pub fn writeMesonOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return writeMesonOutputWithIO(threaded.io(), stdout, allocator, options, contents);
}

pub fn writeMesonOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !void {
    const items = try meson.parseTargetsWithIO(io, allocator, contents, options.path, options.match_path);
    defer meson.freeOwnedTargets(allocator, items);
    const primary_target = shared.findPrimaryTargetName(items);

    const root = pathing.dirOrDot(options.path);
    const build_dir = try build_common.resolveMesonBuildDirAllocWithIO(io, allocator, root);
    defer allocator.free(build_dir);
    const shell_build_dir = try project_common.quoteShellArgIfNeededAlloc(allocator, build_dir);
    defer allocator.free(shell_build_dir);

    const meson_setup_command = try std.fmt.allocPrint(allocator, "meson setup {s}", .{shell_build_dir});
    defer allocator.free(meson_setup_command);
    const meson_clean_command = if (build_common.hasMesonBuildTreeWithIO(io, root))
        try std.fmt.allocPrint(allocator, "meson compile -C {s} --clean", .{shell_build_dir})
    else
        try std.fmt.allocPrint(allocator, "python -c 'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' -- {s}", .{shell_build_dir});
    defer allocator.free(meson_clean_command);
    const meson_test_command = try std.fmt.allocPrint(allocator, "meson test -C {s}", .{shell_build_dir});
    defer allocator.free(meson_test_command);
    const meson_install_command = try std.fmt.allocPrint(allocator, "meson install -C {s}", .{shell_build_dir});
    defer allocator.free(meson_install_command);
    try stdout.print("COMMAND\tmeson-setup\t{s}\n", .{meson_setup_command});
    try stdout.print("COMMAND\tmeson-clean\t{s}\n", .{meson_clean_command});
    try stdout.print("COMMAND\tmeson-test\t{s}\n", .{meson_test_command});
    try stdout.print("COMMAND\tinstall\t{s}\n", .{meson_install_command});
    try stdout.print("COMMAND\tsetup\t{s}\n", .{meson_setup_command});
    try stdout.print("COMMAND\tclean\t{s}\n", .{meson_clean_command});
    try stdout.print("COMMAND\ttest\t{s}\n", .{meson_test_command});
    try stdout.print("PREFERRED\tsetup\t{s}\n", .{meson_setup_command});
    try stdout.print("PREFERRED\tclean\t{s}\n", .{meson_clean_command});
    try stdout.print("PREFERRED\ttest\t{s}\n", .{meson_test_command});
    try stdout.print("PREFERRED\tinstall\t{s}\n", .{meson_install_command});
    const primary_run_path = try shared.emitTargetBuildRunCommandsWithIO(
        io,
        stdout,
        allocator,
        items,
        root,
        build_dir,
        primary_target,
        "meson-build",
        "meson-run",
        build_common.mesonBuildCommandAlloc,
        build_common.mesonRunCommandAlloc,
        build_common.discoverBuildRunPathAllocWithIO,
    );
    defer if (primary_run_path) |value| allocator.free(value);

    if (primary_target) |name| {
        try shared.emitPrimaryBuildRunCommands(
            stdout,
            allocator,
            root,
            name,
            primary_run_path,
            "meson-build",
            "meson-run",
            build_common.mesonBuildCommandAlloc,
            build_common.mesonRunCommandAlloc,
        );
    }
}
