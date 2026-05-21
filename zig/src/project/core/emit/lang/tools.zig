const std = @import("std");
const common = @import("../../common.zig");
const make = @import("../../../make/api.zig");
const package_json = @import("../../../package_json/api.zig");
const pathing = @import("../../../../pathing.zig");
const project_io = @import("../../io.zig");
const pyproject = @import("../../../pyproject/api.zig");
const task_alias = @import("../task_alias.zig");

pub fn writeMakeOutput(stdout: anytype, allocator: std.mem.Allocator, path: []const u8, contents: []const u8) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return writeMakeOutputWithIO(threaded.io(), stdout, allocator, path, contents);
}

pub fn writeMakeOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, path: []const u8, contents: []const u8) !void {
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);
    if (project_io.pathExistsWithIO(io, path)) {
        try make.parseTargetsFromFileAllocWithIO(io, allocator, path, &names);
    } else {
        try make.parseTargets(allocator, contents, &names);
    }
    for (names.items) |name| {
        try stdout.print("COMMAND\t{s}\tmake {s}\n", .{ name, name });
    }
    for (task_alias.canonical_aliases) |alias| {
        if (task_alias.containsName(names.items, alias)) continue;
        const source_name = task_alias.findSourceName(names.items, alias) orelse continue;
        if (std.mem.eql(u8, alias, "build") and std.mem.eql(u8, source_name, "all")) {
            try stdout.print("COMMAND\tbuild\tmake\n", .{});
            continue;
        }
        try stdout.print("COMMAND\t{s}\tmake {s}\n", .{ alias, source_name });
    }

    if (!task_alias.containsName(names.items, "build") and task_alias.findSourceName(names.items, "build") == null) {
        try stdout.print("COMMAND\tbuild\tmake\n", .{});
    }
}

pub fn writePackageJsonOutput(
    stdout: anytype,
    allocator: std.mem.Allocator,
    path: []const u8,
    contents: []const u8,
    package_manager: ?[]const u8,
    is_auto: bool,
) !bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return writePackageJsonOutputWithIO(threaded.io(), stdout, allocator, path, contents, package_manager, is_auto);
}

pub fn writePackageJsonOutputWithIO(
    io: std.Io,
    stdout: anytype,
    allocator: std.mem.Allocator,
    path: []const u8,
    contents: []const u8,
    package_manager: ?[]const u8,
    is_auto: bool,
) !bool {
    if (is_auto and std.mem.trim(u8, contents, " \t\r\n").len == 0) {
        return true;
    }

    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);
    try package_json.parseScriptsLenient(allocator, contents, &names);

    const manager = package_manager orelse blk: {
        const package_json_path = if (is_auto)
            (try project_io.findParentFileAllocWithIO(io, allocator, path, "package.json", 12))
        else
            try allocator.dupe(u8, path);
        defer if (package_json_path) |found_path| allocator.free(found_path);
        const root = if (package_json_path) |found_path| pathing.dirOrDot(found_path) else "";
        break :blk try package_json.detectPackageManagerWithIO(io, allocator, root, contents);
    };

    const install_command = try package_json.formatInstallCommandAlloc(allocator, manager);
    defer allocator.free(install_command);
    try stdout.print("COMMAND\tinstall\t{s}\n", .{install_command});

    for (names.items) |name| {
        const command = try package_json.formatScriptCommandAlloc(allocator, manager, name);
        defer allocator.free(command);
        try stdout.print("COMMAND\t{s}\t{s}\n", .{ name, command });
    }

    for (task_alias.canonical_aliases) |alias| {
        if (std.mem.eql(u8, alias, "clean")) continue;
        if (task_alias.containsName(names.items, alias)) continue;

        const source_name = if (std.mem.eql(u8, alias, "live"))
            package_json.selectLiveScriptName(names.items)
        else
            task_alias.findSourceName(names.items, alias);

        if (source_name) |name| {
            if (std.mem.eql(u8, alias, "live") and std.mem.eql(u8, name, "live")) continue;
            const alias_command = try package_json.formatScriptCommandAlloc(allocator, manager, name);
            defer allocator.free(alias_command);
            try stdout.print("COMMAND\t{s}\t{s}\n", .{ alias, alias_command });
        }
    }

    return true;
}

pub fn writePyprojectOutput(stdout: anytype, allocator: std.mem.Allocator, contents: []const u8) !void {
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);
    try pyproject.parseTools(allocator, contents, &names);
    for (names.items) |name| {
        try stdout.print("TOOL\t{s}\n", .{name});
    }
}

pub fn writePythonAutoOutput(stdout: anytype, allocator: std.mem.Allocator, contents: []const u8) !void {
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);
    try pyproject.parseTools(allocator, contents, &names);
    if (task_alias.containsName(names.items, "uv")) {
        try stdout.print("COMMAND\trun\tuv run -m main\n", .{});
        try stdout.print("COMMAND\ttest\tuv run pytest\n", .{});
        try stdout.print("COMMAND\tinstall\tuv sync\n", .{});
    }
}
