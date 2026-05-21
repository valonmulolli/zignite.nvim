const std = @import("std");
const gradle = @import("../../../gradle/api.zig");
const maven = @import("../../../maven/api.zig");
const common = @import("../../common.zig");
const pathing = @import("../../../../pathing.zig");
const project_io = @import("../../io.zig");
const task_alias = @import("../task_alias.zig");

fn emitCanonicalTaskAliases(
    stdout: anytype,
    allocator: std.mem.Allocator,
    names: []const []u8,
    prefix: []const u8,
    aliases: []const []const u8,
) !void {
    for (aliases) |alias| {
        if (task_alias.containsName(names, alias)) continue;
        const source_name = task_alias.findSourceName(names, alias) orelse continue;
        const command = try std.fmt.allocPrint(allocator, "{s} {s}", .{ prefix, source_name });
        defer allocator.free(command);
        try stdout.print("COMMAND\t{s}\t{s}\n", .{ alias, command });
    }
}

pub fn writeMavenOutput(stdout: anytype, allocator: std.mem.Allocator, contents: []const u8) !void {
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);
    try maven.parseGoals(allocator, contents, &names);

    for (names.items) |name| {
        const command = try std.fmt.allocPrint(allocator, "mvn {s}", .{name});
        defer allocator.free(command);
        try stdout.print("COMMAND\t{s}\t{s}\n", .{ name, command });
    }

    try emitCanonicalTaskAliases(stdout, allocator, names.items, "mvn", &task_alias.canonical_aliases);

    try stdout.print("COMMAND\tmvn-build\tmvn compile\n", .{});
    try stdout.print("COMMAND\tmvn-test\tmvn test\n", .{});
    try stdout.print("COMMAND\tmvn-package\tmvn package\n", .{});
    try stdout.print("COMMAND\tbuild\tmvn compile\n", .{});
    try stdout.print("COMMAND\ttest\tmvn test\n", .{});
    try stdout.print("PREFERRED\tbuild\tmvn compile\n", .{});
    try stdout.print("PREFERRED\ttest\tmvn test\n", .{});

    var run_command: ?[]const u8 = null;
    for (names.items) |name| {
        if (std.mem.eql(u8, name, "spring-boot:run")) {
            run_command = "mvn spring-boot:run";
            break;
        }
        if (run_command == null and std.mem.eql(u8, name, "exec:java")) {
            run_command = "mvn exec:java";
        }
    }

    if (run_command) |command| {
        try stdout.print("COMMAND\tmvn-run\t{s}\n", .{command});
        try stdout.print("COMMAND\trun\t{s}\n", .{command});
        try stdout.print("PRIMARY_RUN\t{s}\n", .{command});
        try stdout.print("PREFERRED\trun\t{s}\n", .{command});
    }
}

pub fn writeGradleOutput(stdout: anytype, allocator: std.mem.Allocator, build_file_path: []const u8, contents: []const u8) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return writeGradleOutputWithIO(threaded.io(), stdout, allocator, build_file_path, contents);
}

pub fn writeGradleOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, build_file_path: []const u8, contents: []const u8) !void {
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);
    try gradle.parseTasks(allocator, contents, &names);

    const root = pathing.dirOrDot(build_file_path);
    const wrapper_path = try std.fs.path.join(allocator, &.{ root, "gradlew" });
    defer allocator.free(wrapper_path);
    const prefix: []const u8 = if (project_io.pathExistsWithIO(io, wrapper_path)) "./gradlew" else "gradle";

    const build_command = try std.fmt.allocPrint(allocator, "{s} build", .{prefix});
    defer allocator.free(build_command);
    const test_command = try std.fmt.allocPrint(allocator, "{s} test", .{prefix});
    defer allocator.free(test_command);
    const clean_command = try std.fmt.allocPrint(allocator, "{s} clean", .{prefix});
    defer allocator.free(clean_command);

    for (names.items) |name| {
        const command = try std.fmt.allocPrint(allocator, "{s} {s}", .{ prefix, name });
        defer allocator.free(command);
        try stdout.print("COMMAND\t{s}\t{s}\n", .{ name, command });
    }

    try emitCanonicalTaskAliases(stdout, allocator, names.items, prefix, &task_alias.canonical_aliases);

    try stdout.print("COMMAND\tgradle-build\t{s}\n", .{build_command});
    try stdout.print("COMMAND\tgradle-test\t{s}\n", .{test_command});
    try stdout.print("COMMAND\tgradle-clean\t{s}\n", .{clean_command});
    try stdout.print("COMMAND\tbuild\t{s}\n", .{build_command});
    try stdout.print("COMMAND\ttest\t{s}\n", .{test_command});
    try stdout.print("COMMAND\tclean\t{s}\n", .{clean_command});
    try stdout.print("PREFERRED\tbuild\t{s}\n", .{build_command});
    try stdout.print("PREFERRED\ttest\t{s}\n", .{test_command});

    var run_task: ?[]const u8 = null;
    for (names.items) |name| {
        if (std.mem.eql(u8, name, "bootRun")) {
            run_task = "bootRun";
            break;
        }
        if (run_task == null and std.mem.eql(u8, name, "run")) {
            run_task = "run";
        }
    }

    if (run_task) |task| {
        const run_command = try std.fmt.allocPrint(allocator, "{s} {s}", .{ prefix, task });
        defer allocator.free(run_command);
        try stdout.print("COMMAND\tgradle-run\t{s}\n", .{run_command});
        try stdout.print("COMMAND\trun\t{s}\n", .{run_command});
        try stdout.print("PRIMARY_RUN\t{s}\n", .{run_command});
        try stdout.print("PREFERRED\trun\t{s}\n", .{run_command});
    }
}
