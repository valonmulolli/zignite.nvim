const std = @import("std");
const config_view = @import("../../../config/view.zig");
const filetype_resolver = @import("../../../filetype.zig");
const pathing = @import("../../../pathing.zig");
const build_system = @import("../../system.zig");
const build_types = @import("../../system/types.zig");
const project = @import("../../../project.zig");
const output = @import("output.zig");
const policy = @import("policy.zig");
const types = @import("../types.zig");

pub fn resolveDetectedOutput(allocator: std.mem.Allocator, options: types.Options) !types.ResolvedOutput {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return resolveDetectedOutputWithIO(threaded.io(), allocator, options);
}

pub fn resolveDetectedOutputWithIO(io: std.Io, allocator: std.mem.Allocator, options: types.Options) !types.ResolvedOutput {
    const resolved_filetype = try filetype_resolver.resolveSupportedAllocWithIO(io, allocator, options.filetype, options.path);
    defer allocator.free(resolved_filetype);

    var resolved = try collectSystemOutputWithIO(io, allocator, options, resolved_filetype);
    errdefer resolved.deinit(allocator);
    resolved.filetype = try allocator.dupe(u8, resolved_filetype);

    var project_output = try collectAutoProjectOutputWithIO(io, allocator, options, resolved_filetype);
    defer project_output.deinit(allocator);
    try output.mergeResolvedOutput(allocator, &resolved, project_output);

    return resolved;
}

pub fn collectConfiguredCommands(
    allocator: std.mem.Allocator,
    filetype: []const u8,
    path: []const u8,
) ![]build_types.CommandEntry {
    const configured = try config_view.listBuildCommands(allocator, filetype);
    defer config_view.freeBuildCommands(allocator, configured);
    var commands = try std.ArrayList(build_types.CommandEntry).initCapacity(allocator, configured.len);
    errdefer {
        types.freeOwnedCommands(allocator, commands.items);
        commands.deinit(allocator);
    }

    for (configured) |entry| {
        const owned_name = try allocator.dupe(u8, entry.name);
        const owned_command = substituteVariablesShellAlloc(allocator, entry.command, path) catch |err| {
            allocator.free(owned_name);
            return err;
        };
        commands.append(allocator, .{
            .name = owned_name,
            .command = owned_command,
        }) catch |err| {
            allocator.free(owned_name);
            allocator.free(owned_command);
            return err;
        };
    }

    return try commands.toOwnedSlice(allocator);
}

fn collectAutoProjectOutput(
    allocator: std.mem.Allocator,
    options: types.Options,
    filetype: []const u8,
) !types.ResolvedOutput {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return collectAutoProjectOutputWithIO(threaded.io(), allocator, options, filetype);
}

fn collectAutoProjectOutputWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: types.Options,
    filetype: []const u8,
) !types.ResolvedOutput {
    const kind = policy.autoKindForFiletype(filetype);
    if (kind == null or !policy.isDetectionEnabled(filetype)) {
        return .{};
    }

    const project_options = project.Options{
        .kind = kind.?,
        .path = options.path,
        .match_path = options.path,
        .project_root = options.project_root,
    };

    const contents = project.readProjectFileWithIO(io, allocator, project_options.kind, project_options.path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{},
    };
    defer allocator.free(contents);

    var project_output = std.Io.Writer.Allocating.init(allocator);
    defer project_output.deinit();
    project.writeOutputWithIO(io, &project_output.writer, allocator, project_options, contents) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{},
    };

    return try output.parseProjectOutput(allocator, project_output.written());
}

fn collectSystemOutput(
    allocator: std.mem.Allocator,
    options: types.Options,
    filetype: []const u8,
) !types.ResolvedOutput {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return collectSystemOutputWithIO(threaded.io(), allocator, options, filetype);
}

fn collectSystemOutputWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: types.Options,
    filetype: []const u8,
) !types.ResolvedOutput {
    const query = policy.systemQueryForFiletype(filetype);
    if (query == null or !policy.isDetectionEnabled(filetype)) {
        return .{};
    }

    const result = try build_system.detectWithIO(io, allocator, query.?, options.path, options.project_root);
    defer build_system.freeOwnedResult(allocator, result);

    return try output.resolvedOutputFromSystemResult(allocator, result);
}

fn substituteVariablesShellAlloc(
    allocator: std.mem.Allocator,
    template: []const u8,
    path: []const u8,
) ![]u8 {
    const file = path;
    const dir = pathing.dirOrDot(path);
    const file_name = std.fs.path.basename(path);
    const file_name_without_ext = std.fs.path.stem(file_name);
    const file_ext_with_dot = std.fs.path.extension(file_name);
    const file_ext = if (file_ext_with_dot.len > 0) file_ext_with_dot[1..] else "";
    const dir_name = std.fs.path.basename(dir);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < template.len) {
        if (template[index] == '%' and index + 1 < template.len and template[index + 1] == '%') {
            try appendShellValue(allocator, &out, file);
            index += 2;
            continue;
        }
        if (template[index] != '$') {
            try out.append(allocator, template[index]);
            index += 1;
            continue;
        }

        var end: usize = index + 1;
        while (end < template.len and (std.ascii.isAlphanumeric(template[end]) or template[end] == '_')) : (end += 1) {}
        if (end == index + 1) {
            try out.append(allocator, template[index]);
            index += 1;
            continue;
        }

        const name = template[index + 1 .. end];
        const replacement = if (std.mem.eql(u8, name, "dir") or std.mem.eql(u8, name, "DIR"))
            dir
        else if (std.mem.eql(u8, name, "file") or std.mem.eql(u8, name, "FILE"))
            file
        else if (std.mem.eql(u8, name, "fileName") or std.mem.eql(u8, name, "FILENAME"))
            file_name
        else if (std.mem.eql(u8, name, "fileNameWithoutExt") or std.mem.eql(u8, name, "FILENAMEWITHOUTEXT"))
            file_name_without_ext
        else if (std.mem.eql(u8, name, "fileExt"))
            file_ext
        else if (std.mem.eql(u8, name, "dirName"))
            dir_name
        else
            null;

        if (replacement) |value| {
            try appendShellValue(allocator, &out, value);
        } else {
            try out.appendSlice(allocator, template[index..end]);
        }
        index = end;
    }

    return out.toOwnedSlice(allocator);
}

fn appendShellValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
) !void {
    try out.append(allocator, '\'');
    for (value) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "'\"'\"'");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '\'');
}

test "resolveDetectedOutput tolerates malformed package json auto output" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "package.json", .data = "{ invalid json" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.ts" });
    defer allocator.free(filepath);

    const resolved = try resolveDetectedOutput(allocator, .{
        .path = filepath,
        .filetype = "typescript",
        .project_root = root,
    });
    defer {
        var owned = resolved;
        owned.deinit(allocator);
    }

    try std.testing.expectEqualStrings("typescript", resolved.filetype.?);
    try std.testing.expectEqualStrings(root, resolved.root.?);
    try std.testing.expectEqualStrings("node", resolved.system.?);
    try std.testing.expect(output.findCommand(resolved.commands.items, "install") != null);
}
