const std = @import("std");
const build_common = @import("../../../../build/common.zig");
const cmake = @import("../../../cmake/api.zig");
const pathing = @import("../../../../pathing.zig");
const project_common = @import("../../common.zig");
const shared = @import("shared.zig");
const types = @import("../../types.zig");

const Options = types.Options;

pub fn writeCmakeOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return writeCmakeOutputWithIO(threaded.io(), stdout, allocator, options, contents);
}

pub fn writeCmakeOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !void {
    const items = try cmake.parseTargetsWithIO(io, allocator, contents, options.path, options.match_path);
    defer cmake.freeOwnedTargets(allocator, items);
    const primary_target = shared.findPrimaryTargetName(items);

    const root = pathing.dirOrDot(options.path);
    const build_dir = try build_common.resolveCmakeBuildDirAllocWithIO(io, allocator, root);
    defer allocator.free(build_dir);
    const shell_build_dir = try project_common.quoteShellArgIfNeededAlloc(allocator, build_dir);
    defer allocator.free(shell_build_dir);

    const cmake_config_command = try std.fmt.allocPrint(allocator, "cmake -B {s} -DCMAKE_EXPORT_COMPILE_COMMANDS=1", .{shell_build_dir});
    defer allocator.free(cmake_config_command);
    const cmake_clean_command = if (build_common.hasCmakeBuildTreeWithIO(io, root))
        try std.fmt.allocPrint(allocator, "cmake --build {s} --target clean", .{shell_build_dir})
    else
        try std.fmt.allocPrint(allocator, "python -c 'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' -- {s}", .{shell_build_dir});
    defer allocator.free(cmake_clean_command);
    const cmake_debug_command = try std.fmt.allocPrint(
        allocator,
        "cmake -B {s} -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build {s}",
        .{ shell_build_dir, shell_build_dir },
    );
    defer allocator.free(cmake_debug_command);
    const cmake_release_command = try std.fmt.allocPrint(
        allocator,
        "cmake -B {s} -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build {s}",
        .{ shell_build_dir, shell_build_dir },
    );
    defer allocator.free(cmake_release_command);
    const cmake_test_command = try std.fmt.allocPrint(allocator, "ctest --test-dir {s}", .{shell_build_dir});
    defer allocator.free(cmake_test_command);
    const cmake_install_command = try std.fmt.allocPrint(allocator, "cmake --build {s} --target install", .{shell_build_dir});
    defer allocator.free(cmake_install_command);
    try stdout.print("COMMAND\tcmake-config\t{s}\n", .{cmake_config_command});
    try stdout.print("COMMAND\tcmake-clean\t{s}\n", .{cmake_clean_command});
    try stdout.print("COMMAND\tcmake-debug\t{s}\n", .{cmake_debug_command});
    try stdout.print("COMMAND\tcmake-release\t{s}\n", .{cmake_release_command});
    try stdout.print("COMMAND\tcmake-test\t{s}\n", .{cmake_test_command});
    try stdout.print("COMMAND\tinstall\t{s}\n", .{cmake_install_command});
    try stdout.print("COMMAND\tconfig\t{s}\n", .{cmake_config_command});
    try stdout.print("COMMAND\tclean\t{s}\n", .{cmake_clean_command});
    try stdout.print("COMMAND\tdebug\t{s}\n", .{cmake_debug_command});
    try stdout.print("COMMAND\trelease\t{s}\n", .{cmake_release_command});
    try stdout.print("COMMAND\ttest\t{s}\n", .{cmake_test_command});
    try stdout.print("PREFERRED\tconfig\t{s}\n", .{cmake_config_command});
    try stdout.print("PREFERRED\tclean\t{s}\n", .{cmake_clean_command});
    try stdout.print("PREFERRED\tdebug\t{s}\n", .{cmake_debug_command});
    try stdout.print("PREFERRED\trelease\t{s}\n", .{cmake_release_command});
    try stdout.print("PREFERRED\ttest\t{s}\n", .{cmake_test_command});
    try stdout.print("PREFERRED\tinstall\t{s}\n", .{cmake_install_command});
    const primary_run_path = try shared.emitTargetBuildRunCommandsWithIO(
        io,
        stdout,
        allocator,
        items,
        root,
        build_dir,
        primary_target,
        "cmake-build",
        "cmake-run",
        build_common.cmakeBuildCommandAlloc,
        build_common.cmakeRunCommandAlloc,
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
            "cmake-build",
            "cmake-run",
            build_common.cmakeBuildCommandAlloc,
            build_common.cmakeRunCommandAlloc,
        );
    }
}
