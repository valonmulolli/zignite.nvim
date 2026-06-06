const std = @import("std");
const common = @import("../common.zig");
const project_common = @import("../../project/core/common.zig");
const pyproject = @import("../../project/pyproject/api.zig");
const shared = @import("shared.zig");
const types = @import("types.zig");

const Result = types.Result;
const CommandEntry = types.CommandEntry;
pub const markers = &.{ "pyproject.toml", "uv.lock", "requirements.txt", "environment.yml", "environment.yaml" };
const PythonProfile = enum {
    uv,
    conda,
    requirements,
};

pub fn detect(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return detectWithIO(threaded.io(), allocator, path, project_root);
}

pub fn detectWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    return try shared.detectWithMarkersAndBuildWithIO(io, allocator, path, project_root, markers, buildResultWithIO);
}

fn buildResult(allocator: std.mem.Allocator, root: []const u8) !Result {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return buildResultWithIO(threaded.io(), allocator, root);
}

fn buildResultWithIO(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !Result {
    const commands = try buildCommandsAllocWithIO(io, allocator, root);
    return try shared.makeResult(allocator, root, "python", null, commands);
}

fn buildCommandsAlloc(allocator: std.mem.Allocator, root: []const u8) ![]CommandEntry {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return buildCommandsAllocWithIO(threaded.io(), allocator, root);
}

fn buildCommandsAllocWithIO(io: std.Io, allocator: std.mem.Allocator, root: []const u8) ![]CommandEntry {
    const pyproject_path = try std.fs.path.join(allocator, &.{ root, "pyproject.toml" });
    defer allocator.free(pyproject_path);

    const profile = try detectProfileWithIO(io, allocator, root, pyproject_path) orelse return allocator.alloc(CommandEntry, 0);

    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer shared.deinitCommandList(allocator, &commands);

    switch (profile) {
        .uv => {
            try shared.appendOwnedCommand(&commands, allocator, "run", try allocator.dupe(u8, "uv run -m main"));
            try shared.appendOwnedCommand(&commands, allocator, "test", try allocator.dupe(u8, "uv run pytest"));
            try shared.appendOwnedCommand(&commands, allocator, "install", try allocator.dupe(u8, "uv sync"));
        },
        .conda => {
            const conda_env_path = try findCondaEnvironmentPathAllocWithIO(io, allocator, root) orelse return allocator.alloc(CommandEntry, 0);
            defer allocator.free(conda_env_path);

            const conda_env_name = try readCondaEnvironmentNameAllocWithIO(io, allocator, conda_env_path);
            defer if (conda_env_name) |name| allocator.free(name);

            const env_file_name = std.fs.path.basename(conda_env_path);
            const run_prefix = if (conda_env_name) |name| blk: {
                const quoted_name = try quoteCondaEnvNameAlloc(allocator, name);
                defer allocator.free(quoted_name);
                break :blk try std.fmt.allocPrint(allocator, "conda run -n {s}", .{quoted_name});
            } else try allocator.dupe(u8, "conda run");
            defer allocator.free(run_prefix);

            try shared.appendOwnedCommand(
                &commands,
                allocator,
                "run",
                try std.fmt.allocPrint(allocator, "{s} python -m main", .{run_prefix}),
            );
            try shared.appendOwnedCommand(
                &commands,
                allocator,
                "test",
                try std.fmt.allocPrint(allocator, "{s} pytest", .{run_prefix}),
            );
            try shared.appendOwnedCommand(
                &commands,
                allocator,
                "install",
                try std.fmt.allocPrint(allocator, "conda env update -f {s} --prune", .{env_file_name}),
            );
        },
        .requirements => {
            try shared.appendOwnedCommand(&commands, allocator, "run", try allocator.dupe(u8, "python -m main"));
            try shared.appendOwnedCommand(&commands, allocator, "test", try allocator.dupe(u8, "pytest"));
            try shared.appendOwnedCommand(&commands, allocator, "install", try allocator.dupe(u8, "pip install -r requirements.txt"));
        },
    }

    return try commands.toOwnedSlice(allocator);
}

fn detectProfile(
    allocator: std.mem.Allocator,
    root: []const u8,
    pyproject_path: []const u8,
) !?PythonProfile {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return detectProfileWithIO(threaded.io(), allocator, root, pyproject_path);
}

fn detectProfileWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    pyproject_path: []const u8,
) !?PythonProfile {
    const has_uv_lock = shared.pathHasFileWithIO(io, root, "uv.lock");
    const has_requirements = shared.pathHasFileWithIO(io, root, "requirements.txt");
    const conda_env_path = try findCondaEnvironmentPathAllocWithIO(io, allocator, root);
    defer if (conda_env_path) |path| allocator.free(path);
    const has_pyproject = shared.pathExistsWithIO(io, pyproject_path);

    if (!has_pyproject) {
        if (has_uv_lock) return .uv;
        if (conda_env_path != null) return .conda;
        if (has_requirements) return .requirements;
        return null;
    }

    const contents = try common.readFileAllocWithIO(io, allocator, pyproject_path);
    defer allocator.free(contents);

    if (has_uv_lock or pyproject.hasToolSection(contents, "tool.uv")) return .uv;
    if (conda_env_path != null) return .conda;
    if (has_requirements) return .requirements;
    return null;
}

fn findCondaEnvironmentPathAllocWithIO(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !?[]u8 {
    const yml = try std.fs.path.join(allocator, &.{ root, "environment.yml" });
    defer allocator.free(yml);
    if (shared.pathExistsWithIO(io, yml)) {
        return try allocator.dupe(u8, yml);
    }

    const yaml = try std.fs.path.join(allocator, &.{ root, "environment.yaml" });
    defer allocator.free(yaml);
    if (shared.pathExistsWithIO(io, yaml)) {
        return try allocator.dupe(u8, yaml);
    }

    return null;
}

fn readCondaEnvironmentNameAlloc(allocator: std.mem.Allocator, environment_path: []const u8) !?[]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return readCondaEnvironmentNameAllocWithIO(threaded.io(), allocator, environment_path);
}

fn readCondaEnvironmentNameAllocWithIO(io: std.Io, allocator: std.mem.Allocator, environment_path: []const u8) !?[]u8 {
    const contents = try common.readFileAllocWithIO(io, allocator, environment_path);
    defer allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, stripHashComment(stripTrailingCR(raw_line)), " \t\r\n");
        if (!std.mem.startsWith(u8, line, "name:")) continue;
        const value = std.mem.trim(u8, line["name:".len..], " \t\r\n");
        if (value.len == 0) return null;
        return try allocator.dupe(u8, stripOptionalQuotes(value));
    }
    return null;
}

fn stripTrailingCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

fn stripHashComment(line: []const u8) []const u8 {
    var quote: ?u8 = null;
    var escaped = false;

    for (line, 0..) |ch, index| {
        if (quote) |active_quote| {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == active_quote) {
                quote = null;
            }
            continue;
        }

        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (ch == '#') return line[0..index];
    }

    return line;
}

fn stripOptionalQuotes(value: []const u8) []const u8 {
    if (value.len < 2) return value;
    const first = value[0];
    const last = value[value.len - 1];
    if ((first == '"' or first == '\'') and last == first) {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn quoteCondaEnvNameAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.') continue;
        return project_common.quoteShellArgAlloc(allocator, name);
    }
    return allocator.dupe(u8, name);
}

test "detectProfile accepts uv lock without pyproject" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "uv.lock", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const pyproject_path = try std.fs.path.join(allocator, &.{ root, "pyproject.toml" });
    defer allocator.free(pyproject_path);

    try std.testing.expectEqual(PythonProfile.uv, (try detectProfile(allocator, root, pyproject_path)).?);
}

test "detect returns uv commands for uv lock without pyproject" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "uv.lock", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.py" });
    defer allocator.free(filepath);

    const result = try detect(allocator, filepath, root);
    defer types.freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("python", result.system.?);
    try std.testing.expectEqualStrings("uv run -m main", findCommand(result.commands, "run").?);
    try std.testing.expectEqualStrings("uv sync", findCommand(result.commands, "install").?);
}

test "readCondaEnvironmentName keeps hash inside quoted yaml scalar" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "environment.yml", .data = "name: \"demo#gpu\"\n" });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "environment.yml", allocator);
    defer allocator.free(path);

    const name = (try readCondaEnvironmentNameAlloc(allocator, path)).?;
    defer allocator.free(name);

    try std.testing.expectEqualStrings("demo#gpu", name);
}

fn findCommand(commands: []const CommandEntry, name: []const u8) ?[]const u8 {
    for (commands) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.command;
    }
    return null;
}
