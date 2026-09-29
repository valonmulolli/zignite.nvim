const std = @import("std");
const builtin = @import("builtin");

const path_delimiter: u8 = if (builtin.os.tag == .windows) ';' else ':';

pub fn findMissingToolWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    cwd: ?[]const u8,
    command_text: ?[]const u8,
    argv: []const []u8,
) !?[]u8 {
    const tool = if (argv.len > 0) argv[0] else firstCommandWord(command_text orelse "");
    if (tool == null or tool.?.len == 0 or isShellBuiltin(tool.?)) return null;

    const environment = environ_map orelse return null;
    const path_value = environment.get("PATH") orelse return null;
    if (try isToolAvailable(io, allocator, path_value, cwd, tool.?)) return null;

    return try allocator.dupe(u8, tool.?);
}

fn isToolAvailable(
    io: std.Io,
    allocator: std.mem.Allocator,
    path_value: []const u8,
    cwd: ?[]const u8,
    tool: []const u8,
) !bool {
    if (hasPathSeparator(tool)) {
        const candidate = try makePathCandidate(allocator, cwd, "", tool);
        defer allocator.free(candidate);
        return try accessExecutable(io, allocator, candidate);
    }

    var path_it = std.mem.splitScalar(u8, path_value, path_delimiter);
    while (path_it.next()) |path_entry| {
        const candidate = try makePathCandidate(allocator, cwd, path_entry, tool);
        defer allocator.free(candidate);
        if (try accessExecutable(io, allocator, candidate)) return true;
    }
    return false;
}

fn makePathCandidate(
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    path_entry: []const u8,
    tool: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(tool)) return try allocator.dupe(u8, tool);

    if (path_entry.len == 0) {
        if (cwd) |root| return try std.fs.path.join(allocator, &.{ root, tool });
        return try allocator.dupe(u8, tool);
    }

    if (std.fs.path.isAbsolute(path_entry)) {
        return try std.fs.path.join(allocator, &.{ path_entry, tool });
    }

    if (cwd) |root| {
        return try std.fs.path.join(allocator, &.{ root, path_entry, tool });
    }
    return try std.fs.path.join(allocator, &.{ path_entry, tool });
}

fn accessExecutable(io: std.Io, allocator: std.mem.Allocator, candidate: []const u8) !bool {
    if (try accessPath(io, candidate)) return true;

    if (builtin.os.tag == .windows and std.fs.path.extension(candidate).len == 0) {
        for ([_][]const u8{ ".exe", ".cmd", ".bat", ".com" }) |extension| {
            const with_extension = try std.fmt.allocPrint(allocator, "{s}{s}", .{ candidate, extension });
            defer allocator.free(with_extension);
            if (try accessPath(io, with_extension)) return true;
        }
    }
    return false;
}

fn accessPath(io: std.Io, candidate: []const u8) !bool {
    const stat = std.Io.Dir.statFile(.cwd(), io, candidate, .{}) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => false,
        error.AccessDenied, error.PermissionDenied => true,
        else => return err,
    };
    if (stat.kind != .file) return false;

    const options: std.Io.Dir.AccessOptions = .{ .execute = true };
    if (std.fs.path.isAbsolute(candidate)) {
        std.Io.Dir.accessAbsolute(io, candidate, options) catch |err| return switch (err) {
            error.FileNotFound => false,
            error.AccessDenied, error.PermissionDenied => true,
            else => return err,
        };
    } else {
        std.Io.Dir.access(.cwd(), io, candidate, options) catch |err| return switch (err) {
            error.FileNotFound => false,
            error.AccessDenied, error.PermissionDenied => true,
            else => return err,
        };
    }
    return true;
}

fn firstCommandWord(command: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < command.len and std.ascii.isWhitespace(command[index])) : (index += 1) {}
    if (index == command.len) return null;

    if (command[index] == '\'' or command[index] == '"') {
        const quote = command[index];
        const start = index + 1;
        index = start;
        while (index < command.len and command[index] != quote) : (index += 1) {}
        if (index == start) return null;
        return command[start..index];
    }

    const start = index;
    while (index < command.len and !std.ascii.isWhitespace(command[index]) and
        !isShellOperator(command[index])) : (index += 1)
    {}
    if (index == start) return null;
    return command[start..index];
}

fn isShellOperator(ch: u8) bool {
    return ch == '&' or ch == '|' or ch == ';' or ch == '<' or ch == '>';
}

fn hasPathSeparator(tool: []const u8) bool {
    if (builtin.os.tag == .windows) return std.mem.findAny(u8, tool, "\\/") != null;
    return std.mem.findScalar(u8, tool, '/') != null;
}

fn isShellBuiltin(tool: []const u8) bool {
    for ([_][]const u8{
        "[", "cd", ".", ":", "command", "echo", "exec", "exit", "export", "false", "if", "printf", "pwd", "read", "set", "source", "test", "true", "type", "umask", "unset",
    }) |builtin_name| {
        if (std.mem.eql(u8, tool, builtin_name)) return true;
    }
    return false;
}

test "findMissingTool reports a missing executable from PATH" {
    const allocator = std.testing.allocator;
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("PATH", "/zignite/path/does/not/exist");

    const missing = (try findMissingToolWithIO(
        std.testing.io,
        allocator,
        &environment,
        "/tmp",
        "dart run /tmp/main.dart",
        &.{},
    )).?;
    defer allocator.free(missing);
    try std.testing.expectEqualStrings("dart", missing);
}

test "findMissingTool ignores shell builtins" {
    const allocator = std.testing.allocator;
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("PATH", "/zignite/path/does/not/exist");

    try std.testing.expect((try findMissingToolWithIO(
        std.testing.io,
        allocator,
        &environment,
        "/tmp",
        "cd /tmp",
        &.{},
    )) == null);
}

test "findMissingTool does not treat a directory as an executable" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "fake-tool", .default_dir);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);

    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("PATH", root);

    const missing = (try findMissingToolWithIO(
        std.testing.io,
        allocator,
        &environment,
        root,
        "fake-tool --version",
        &.{},
    )).?;
    defer allocator.free(missing);
    try std.testing.expectEqualStrings("fake-tool", missing);
}
