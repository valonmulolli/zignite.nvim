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
    const environment = environ_map orelse return null;
    const path_value = environment.get("PATH") orelse return null;

    if (argv.len > 0) {
        return try findMissingToolInWord(io, allocator, path_value, cwd, argv[0]);
    }

    var scanner = CommandScanner{ .command = command_text orelse "" };
    var previous_command_was_external = false;
    while (scanner.next()) |tool| {
        if (isShellBuiltin(tool) or isShellKeyword(tool)) {
            previous_command_was_external = false;
            continue;
        }
        // Commands such as `gcc ... && /tmp/output` run an artifact produced
        // by the preceding tool. It cannot be required on PATH before launch.
        if (previous_command_was_external and hasPathSeparator(tool)) continue;
        if (try findMissingToolInWord(io, allocator, path_value, cwd, tool)) |missing| return missing;
        previous_command_was_external = true;
    }
    return null;
}

fn findMissingToolInWord(
    io: std.Io,
    allocator: std.mem.Allocator,
    path_value: []const u8,
    cwd: ?[]const u8,
    tool: []const u8,
) !?[]u8 {
    if (tool.len == 0 or isShellBuiltin(tool) or isShellKeyword(tool)) return null;
    if (try isToolAvailable(io, allocator, path_value, cwd, tool)) return null;
    return try allocator.dupe(u8, tool);
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

const CommandScanner = struct {
    command: []const u8,
    index: usize = 0,
    command_active: bool = false,
    wrapper_pending: bool = false,
    wrapper_skip_next: bool = false,

    fn next(self: *CommandScanner) ?[]const u8 {
        while (self.index < self.command.len) {
            if (self.command_active) {
                if (self.wrapper_pending) {
                    self.wrapper_pending = false;
                    self.skipHorizontalWhitespace();
                    if (self.index < self.command.len and !isCommandSeparator(self.command[self.index])) {
                        if (self.readWord()) |word| {
                            if (self.wrapper_skip_next) {
                                self.wrapper_skip_next = false;
                                self.wrapper_pending = true;
                                continue;
                            }
                            if (isAssignmentWord(word)) {
                                self.wrapper_pending = true;
                                continue;
                            }
                            if (isWrapperOption(word)) {
                                self.wrapper_skip_next = isWrapperOptionWithArgument(word);
                                self.wrapper_pending = true;
                                continue;
                            }
                            return word;
                        }
                    }
                }
                self.wrapper_skip_next = false;
                self.skipToCommandSeparator();
                self.command_active = false;
                continue;
            }

            self.skipCommandSeparators();
            self.skipHorizontalWhitespace();
            if (self.index >= self.command.len) return null;

            const word = self.readWord() orelse {
                self.index += 1;
                continue;
            };
            if (isAssignmentWord(word)) continue;

            self.command_active = true;
            self.wrapper_pending = isCommandWrapper(word);
            return word;
        }
        return null;
    }

    fn readWord(self: *CommandScanner) ?[]const u8 {
        const start = self.index;
        var quote: ?u8 = null;
        while (self.index < self.command.len) {
            const ch = self.command[self.index];
            if (quote) |active_quote| {
                if (ch == active_quote) {
                    quote = null;
                } else if (ch == '\\' and self.index + 1 < self.command.len) {
                    self.index += 1;
                }
                self.index += 1;
                continue;
            }

            if (ch == '\'' or ch == '"') {
                quote = ch;
                self.index += 1;
            } else if (ch == '\\' and self.index + 1 < self.command.len) {
                self.index += 2;
            } else if (std.ascii.isWhitespace(ch) or isCommandSeparator(ch)) {
                break;
            } else {
                self.index += 1;
            }
        }
        if (self.index == start) return null;

        const word = self.command[start..self.index];
        if (word.len >= 2 and (word[0] == '\'' or word[0] == '"') and word[word.len - 1] == word[0]) {
            return word[1 .. word.len - 1];
        }
        return word;
    }

    fn skipCommandSeparators(self: *CommandScanner) void {
        while (self.index < self.command.len) {
            if (self.command[self.index] == '\n' or self.command[self.index] == '\r') {
                self.index += 1;
                continue;
            }
            if (!isCommandSeparator(self.command[self.index])) return;
            self.index += 1;
            if (self.index < self.command.len and
                (self.command[self.index] == '&' or self.command[self.index] == '|'))
            {
                self.index += 1;
            }
        }
    }

    fn skipToCommandSeparator(self: *CommandScanner) void {
        var quote: ?u8 = null;
        while (self.index < self.command.len) {
            const ch = self.command[self.index];
            if (quote) |active_quote| {
                if (ch == active_quote) {
                    quote = null;
                } else if (ch == '\\' and self.index + 1 < self.command.len) {
                    self.index += 1;
                }
                self.index += 1;
                continue;
            }

            if (ch == '\'' or ch == '"') {
                quote = ch;
                self.index += 1;
            } else if (ch == '\\' and self.index + 1 < self.command.len) {
                self.index += 2;
            } else if (isCommandSeparator(ch)) {
                return;
            } else {
                self.index += 1;
            }
        }
    }

    fn skipHorizontalWhitespace(self: *CommandScanner) void {
        while (self.index < self.command.len and
            (self.command[self.index] == ' ' or self.command[self.index] == '\t'))
        {
            self.index += 1;
        }
    }
};

fn isCommandSeparator(ch: u8) bool {
    return ch == '&' or ch == '|' or ch == ';' or ch == '\n' or ch == '\r';
}

fn isCommandWrapper(word: []const u8) bool {
    return std.mem.eql(u8, word, "command") or std.mem.eql(u8, word, "exec");
}

fn isWrapperOption(word: []const u8) bool {
    return word.len > 1 and word[0] == '-';
}

fn isWrapperOptionWithArgument(word: []const u8) bool {
    return std.mem.eql(u8, word, "-a") or std.mem.eql(u8, word, "--argv0");
}

fn isAssignmentWord(word: []const u8) bool {
    if (word.len == 0) return false;
    var index: usize = 0;
    if (!(std.ascii.isAlphabetic(word[index]) or word[index] == '_')) return false;
    index += 1;
    while (index < word.len and (std.ascii.isAlphanumeric(word[index]) or word[index] == '_')) : (index += 1) {}
    return index < word.len and word[index] == '=';
}

fn isShellKeyword(word: []const u8) bool {
    for ([_][]const u8{
        "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "select", "then", "until", "while",
    }) |keyword| {
        if (std.mem.eql(u8, word, keyword)) return true;
    }
    return false;
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

test "findMissingTool scans past shell builtins and separators" {
    const allocator = std.testing.allocator;
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("PATH", "/zignite/path/does/not/exist");

    const missing = (try findMissingToolWithIO(
        std.testing.io,
        allocator,
        &environment,
        "/tmp",
        "cd '/tmp/project' && printf ready | dart run main.dart",
        &.{},
    )).?;
    defer allocator.free(missing);
    try std.testing.expectEqualStrings("dart", missing);
}

test "findMissingTool skips command wrapper options" {
    const allocator = std.testing.allocator;
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("PATH", "/zignite/path/does/not/exist");

    const missing = (try findMissingToolWithIO(
        std.testing.io,
        allocator,
        &environment,
        "/tmp",
        "command -v dart",
        &.{},
    )).?;
    defer allocator.free(missing);
    try std.testing.expectEqualStrings("dart", missing);
}

test "findMissingTool skips exec option arguments" {
    const allocator = std.testing.allocator;
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("PATH", "/zignite/path/does/not/exist");

    const missing = (try findMissingToolWithIO(
        std.testing.io,
        allocator,
        &environment,
        "/tmp",
        "exec -a zignite dart run main.dart",
        &.{},
    )).?;
    defer allocator.free(missing);
    try std.testing.expectEqualStrings("dart", missing);
}

test "findMissingTool resets wrapper option state at separators" {
    const allocator = std.testing.allocator;
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("PATH", "/zignite/path/does/not/exist");

    const missing = (try findMissingToolWithIO(
        std.testing.io,
        allocator,
        &environment,
        "/tmp",
        "exec -a; exec dart run main.dart",
        &.{},
    )).?;
    defer allocator.free(missing);
    try std.testing.expectEqualStrings("dart", missing);
}

test "findMissingTool skips environment assignments" {
    const allocator = std.testing.allocator;
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("PATH", "/zignite/path/does/not/exist");

    const missing = (try findMissingToolWithIO(
        std.testing.io,
        allocator,
        &environment,
        "/tmp",
        "ZIG_GLOBAL_CACHE_DIR=/tmp/cache dart run main.dart",
        &.{},
    )).?;
    defer allocator.free(missing);
    try std.testing.expectEqualStrings("dart", missing);
}

test "findMissingTool ignores generated path artifacts after an external command" {
    if (comptime builtin.os.tag == .windows) return;

    const allocator = std.testing.allocator;
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("PATH", "/zignite/path/does/not/exist");

    try std.testing.expect((try findMissingToolWithIO(
        std.testing.io,
        allocator,
        &environment,
        "/tmp",
        "/bin/sh -c true && /tmp/zignite-generated-output",
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
