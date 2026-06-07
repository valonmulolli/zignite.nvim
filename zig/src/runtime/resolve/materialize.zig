const std = @import("std");
const pathing = @import("../../pathing.zig");
const types = @import("types.zig");

pub fn materializeRunner(
    allocator: std.mem.Allocator,
    runner: *types.ResolvedRunner,
    path: []const u8,
) !void {
    const filetype_name = runner.filetype orelse "";
    if (runner.name == null and filetype_name.len > 0) {
        runner.name = try allocator.dupe(u8, filetype_name);
    }

    if (runner.cwd) |cwd| {
        const resolved = try substituteVariablesRaw(allocator, cwd, path);
        allocator.free(cwd);
        runner.cwd = resolved;
    }

    if (runner.cleanup_command) |cleanup| {
        const resolved = try substituteVariablesShell(allocator, cleanup, path, runner.cwd);
        allocator.free(cleanup);
        runner.cleanup_command = resolved;
    }

    if (runner.command) |command| {
        const raw_command = try substituteVariablesRaw(allocator, command, path);
        defer allocator.free(raw_command);
        if (isReservedArgvCommand(raw_command)) {
            return error.ReservedRunResolveArgvCommand;
        }

        const resolved = try substituteVariablesShell(allocator, command, path, runner.cwd);
        allocator.free(command);
        runner.command = resolved;

        runner.argv = try tokenizeCommand(allocator, resolved);
    }

    if (std.mem.eql(u8, runner.source, "project") and runner.cwd == null) {
        runner.cwd = try allocator.dupe(u8, pathing.dirOrDot(path));
    }
}

pub fn substituteVariablesRaw(
    allocator: std.mem.Allocator,
    template: []const u8,
    path: []const u8,
) ![]u8 {
    return substituteVariablesImpl(allocator, template, path, false, null);
}

pub fn substituteVariablesShell(
    allocator: std.mem.Allocator,
    template: []const u8,
    path: []const u8,
    cwd_hint: ?[]const u8,
) ![]u8 {
    return substituteVariablesImpl(allocator, template, path, true, cwd_hint);
}

fn substituteVariablesImpl(
    allocator: std.mem.Allocator,
    template: []const u8,
    path: []const u8,
    shell_escape: bool,
    cwd_hint: ?[]const u8,
) ![]u8 {
    const file = path;
    const dir = pathing.dirOrDot(path);
    const file_name = std.fs.path.basename(path);
    const file_name_without_ext = std.fs.path.stem(file_name);
    const file_ext_with_dot = std.fs.path.extension(file_name);
    const file_ext = if (file_ext_with_dot.len > 0) file_ext_with_dot[1..] else "";
    const root = cwd_hint orelse dir;
    const dir_name = std.fs.path.basename(root);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < template.len) {
        if (template[index] == '%' and index + 1 < template.len and template[index + 1] == '%') {
            try out.append(allocator, '%');
            index += 2;
            continue;
        }
        if (template[index] != '$') {
            const start = index;
            while (index < template.len and template[index] != '$' and
                !(template[index] == '%' and index + 1 < template.len and template[index + 1] == '%')) : (index += 1)
            {}
            try out.appendSlice(allocator, template[start..index]);
            continue;
        }

        var end = index + 1;
        while (end < template.len and (std.ascii.isAlphanumeric(template[end]) or template[end] == '_')) : (end += 1) {}
        if (end == index + 1) {
            try out.append(allocator, template[index]);
            index += 1;
            continue;
        }

        const name = template[index + 1 .. end];
        const replacement = if (std.mem.eql(u8, name, "dir"))
            dir
        else if (std.mem.eql(u8, name, "file"))
            file
        else if (std.mem.eql(u8, name, "fileName"))
            file_name
        else if (std.mem.eql(u8, name, "fileNameWithoutExt"))
            file_name_without_ext
        else if (std.mem.eql(u8, name, "fileExt"))
            file_ext
        else if (std.mem.eql(u8, name, "dirName"))
            dir_name
        else
            null;

        if (replacement) |value| {
            try appendResolvedVariable(allocator, &out, value, shell_escape);
        } else {
            try out.appendSlice(allocator, template[index..end]);
        }
        index = end;
    }

    return out.toOwnedSlice(allocator);
}

fn appendResolvedVariable(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
    shell_escape: bool,
) !void {
    if (!shell_escape) {
        try out.appendSlice(allocator, value);
        return;
    }

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

fn hasUnsupportedShellSyntax(command: []const u8) bool {
    if (command.len == 0) return true;

    var quote: ?u8 = null;
    var index: usize = 0;
    while (index < command.len) : (index += 1) {
        const ch = command[index];
        if (std.ascii.isControl(ch)) return true;

        if (quote) |current_quote| {
            if (ch == current_quote) {
                quote = null;
            } else if (ch == '\\' and current_quote == '"' and index + 1 < command.len) {
                index += 1;
            }
        } else {
            if (ch == '\'' or ch == '"') {
                quote = ch;
            } else if (ch == '`' or ch == '|' or ch == ';' or ch == '<' or ch == '>' or ch == '&' or
                ch == '*' or ch == '?' or ch == '~' or ch == '\n')
            {
                return true;
            } else if (ch == '$' and index + 1 < command.len and command[index + 1] == '(') {
                return true;
            } else if (ch == '\\' and index + 1 < command.len) {
                index += 1;
            }
        }
    }

    return quote != null;
}

fn hasUnresolvedPlaceholders(command: []const u8) bool {
    var quote: ?u8 = null;
    var index: usize = 0;
    while (index < command.len) : (index += 1) {
        const ch = command[index];
        if (quote) |current_quote| {
            if (ch == current_quote) {
                quote = null;
            } else if (ch == '\\' and current_quote == '"' and index + 1 < command.len) {
                index += 1;
            } else if (current_quote == '"' and ch == '$' and index + 1 < command.len) {
                const next = command[index + 1];
                if (next == '(' or next == '{' or std.ascii.isAlphanumeric(next) or next == '_') return true;
            }
        } else {
            if (ch == '\'' or ch == '"') {
                quote = ch;
            } else if (ch == '\\' and index + 1 < command.len) {
                index += 1;
            } else if (ch == '$' and index + 1 < command.len) {
                const next = command[index + 1];
                if (next == '(' or next == '{' or std.ascii.isAlphanumeric(next) or next == '_') return true;
            }
        }
    }
    return quote != null;
}

pub fn tokenizeCommand(allocator: std.mem.Allocator, command: []const u8) !std.ArrayList([]u8) {
    var tokens: std.ArrayList([]u8) = .empty;
    errdefer {
        for (tokens.items) |arg| allocator.free(arg);
        tokens.deinit(allocator);
    }

    if (hasUnsupportedShellSyntax(command) or hasUnresolvedPlaceholders(command)) {
        return tokens;
    }

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);
    var quote: ?u8 = null;
    var index: usize = 0;
    while (index < command.len) : (index += 1) {
        const ch = command[index];
        if (quote) |current_quote| {
            if (ch == current_quote) {
                quote = null;
            } else if (ch == '\\' and current_quote == '"' and index + 1 < command.len) {
                index += 1;
                try current.append(allocator, command[index]);
            } else {
                try current.append(allocator, ch);
            }
        } else {
            if (ch == '\'' or ch == '"') {
                quote = ch;
            } else if (std.ascii.isWhitespace(ch)) {
                if (current.items.len > 0) {
                    try appendCurrentToken(allocator, &tokens, &current);
                }
            } else if (ch == '\\' and index + 1 < command.len) {
                index += 1;
                try current.append(allocator, command[index]);
            } else {
                try current.append(allocator, ch);
            }
        }
    }

    if (quote != null) {
        return tokens;
    }
    if (current.items.len > 0) {
        try appendCurrentToken(allocator, &tokens, &current);
    }
    return tokens;
}

fn appendCurrentToken(
    allocator: std.mem.Allocator,
    tokens: *std.ArrayList([]u8),
    current: *std.ArrayList(u8),
) !void {
    const token = try current.toOwnedSlice(allocator);
    current.* = .empty;
    tokens.append(allocator, token) catch |err| {
        allocator.free(token);
        return err;
    };
}

pub fn isReservedArgvCommand(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "--argv")) return true;
    if (!std.mem.startsWith(u8, trimmed, "--argv")) return false;
    return trimmed.len == "--argv".len or std.ascii.isWhitespace(trimmed["--argv".len]);
}

test "substituteVariablesRaw uses dot for bare relative file dir" {
    const allocator = std.testing.allocator;

    const resolved = try substituteVariablesRaw(allocator, "$dir", "main.py");
    defer allocator.free(resolved);

    try std.testing.expectEqualStrings(".", resolved);
}

test "materializeRunner uses dot cwd for bare relative project path" {
    const allocator = std.testing.allocator;

    var runner = types.ResolvedRunner{
        .source = "project",
        .filetype = try allocator.dupe(u8, "python"),
        .command = try allocator.dupe(u8, "python3 -u $file"),
    };
    try materializeRunner(allocator, &runner, "main.py");
    defer runner.deinit(allocator);

    try std.testing.expectEqualStrings(".", runner.cwd.?);
    try std.testing.expectEqualStrings("python3 -u 'main.py'", runner.command.?);
    try std.testing.expectEqualStrings("python3", runner.argv.items[0]);
    try std.testing.expectEqualStrings("-u", runner.argv.items[1]);
    try std.testing.expectEqualStrings("main.py", runner.argv.items[2]);
}

test "materializeRunner keeps file paths with spaces as one argv argument" {
    const allocator = std.testing.allocator;

    var runner = types.ResolvedRunner{
        .source = "filetype",
        .filetype = try allocator.dupe(u8, "python"),
        .command = try allocator.dupe(u8, "python3 -u $file"),
    };

    try materializeRunner(allocator, &runner, "/tmp/example dir/main.py");
    defer runner.deinit(allocator);

    try std.testing.expectEqualStrings("python3 -u '/tmp/example dir/main.py'", runner.command.?);
    try std.testing.expectEqual(@as(usize, 3), runner.argv.items.len);
    try std.testing.expectEqualStrings("python3", runner.argv.items[0]);
    try std.testing.expectEqualStrings("-u", runner.argv.items[1]);
    try std.testing.expectEqualStrings("/tmp/example dir/main.py", runner.argv.items[2]);
}
