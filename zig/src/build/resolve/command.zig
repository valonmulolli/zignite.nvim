const std = @import("std");
const project_common = @import("../../project/core/common.zig");
const build_types = @import("../system/types.zig");

pub const COMMAND_ARG_PLACEHOLDER = "$zignite_args";
pub const COMMAND_ARG_DISPLAY_PLACEHOLDER = "<args>";

pub fn writeCommandUiMetadata(
    stdout: anytype,
    allocator: std.mem.Allocator,
    filetype: []const u8,
    entry: build_types.CommandEntry,
) !void {
    const display = try commandDisplayAlloc(allocator, entry.command);
    defer allocator.free(display);
    try stdout.print("COMMAND_DISPLAY\t{s}\t{s}\n", .{ entry.name, display });

    if (!commandRequiresArguments(entry.command)) return;

    const prompt = try commandArgumentPromptAlloc(allocator, filetype, entry.name);
    defer allocator.free(prompt);
    const help = try commandArgumentHelpAlloc(allocator, filetype, entry.name);
    defer allocator.free(help);

    try stdout.print("COMMAND_ARGS_REQUIRED\t{s}\t1\n", .{entry.name});
    try stdout.print("COMMAND_ARG_PROMPT\t{s}\t{s}\n", .{ entry.name, prompt });
    try stdout.print("COMMAND_ARG_HELP\t{s}\t{s}\n", .{ entry.name, help });
}

pub fn commandRequiresArguments(command_template: []const u8) bool {
    return std.mem.indexOf(u8, command_template, COMMAND_ARG_PLACEHOLDER) != null;
}

pub fn commandDisplayAlloc(allocator: std.mem.Allocator, command_template: []const u8) ![]u8 {
    if (!commandRequiresArguments(command_template)) {
        return allocator.dupe(u8, command_template);
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var cursor: usize = 0;
    while (true) {
        const next = std.mem.indexOfPos(u8, command_template, cursor, COMMAND_ARG_PLACEHOLDER) orelse {
            try out.appendSlice(allocator, command_template[cursor..]);
            break;
        };
        try out.appendSlice(allocator, command_template[cursor..next]);
        try out.appendSlice(allocator, COMMAND_ARG_DISPLAY_PLACEHOLDER);
        cursor = next + COMMAND_ARG_PLACEHOLDER.len;
    }
    return out.toOwnedSlice(allocator);
}

pub fn commandArgumentPromptAlloc(
    allocator: std.mem.Allocator,
    filetype: []const u8,
    command_name: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, filetype, "zig") and std.mem.eql(u8, command_name, "fetch")) {
        return allocator.dupe(u8, "zig fetch url/path");
    }
    return std.fmt.allocPrint(allocator, "{s} {s} args", .{ filetype, command_name });
}

pub fn commandArgumentHelpAlloc(
    allocator: std.mem.Allocator,
    filetype: []const u8,
    command_name: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, filetype, "zig") and std.mem.eql(u8, command_name, "fetch")) {
        return allocator.dupe(u8, "Paste GitHub URL only | Enter: run | Esc: cancel | Backspace: edit");
    }
    return allocator.dupe(u8, "Type arguments | Enter: run | Esc: cancel | Backspace: edit");
}

pub fn resolveCommandTemplate(
    allocator: std.mem.Allocator,
    filetype: []const u8,
    command_name: []const u8,
    command_template: []const u8,
    command_args: ?[]const u8,
) ![]u8 {
    if (!commandRequiresArguments(command_template)) {
        return allocator.dupe(u8, command_template);
    }

    const raw_args = command_args orelse return error.MissingBuildResolveCommandArgs;
    const trimmed = std.mem.trim(u8, raw_args, " \t\r\n");
    if (trimmed.len == 0) {
        return error.MissingBuildResolveCommandArgs;
    }

    const replacement = if (std.mem.eql(u8, filetype, "zig") and std.mem.eql(u8, command_name, "fetch"))
        try normalizeGithubRepoReferenceAlloc(allocator, trimmed)
    else
        try project_common.quoteShellArgAlloc(allocator, trimmed);
    defer allocator.free(replacement);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var cursor: usize = 0;
    while (true) {
        const next = std.mem.indexOfPos(u8, command_template, cursor, COMMAND_ARG_PLACEHOLDER) orelse {
            try out.appendSlice(allocator, command_template[cursor..]);
            break;
        };
        try out.appendSlice(allocator, command_template[cursor..next]);
        try out.appendSlice(allocator, replacement);
        cursor = next + COMMAND_ARG_PLACEHOLDER.len;
    }

    return out.toOwnedSlice(allocator);
}

pub fn isReservedArgvCommand(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "--argv")) return true;
    if (!std.mem.startsWith(u8, trimmed, "--argv")) return false;
    return trimmed.len == "--argv".len or std.ascii.isWhitespace(trimmed["--argv".len]);
}

pub fn normalizeGithubRepoReferenceAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, trimmed);
    if (std.mem.startsWith(u8, trimmed, "--")) return allocator.dupe(u8, trimmed);

    if (std.mem.startsWith(u8, trimmed, "git+https://github.com/")) {
        return std.fmt.allocPrint(allocator, "--save {s}", .{trimmed});
    }

    if (parseGithubHttpReference(trimmed)) |parsed| {
        return try buildGithubSaveReference(allocator, parsed.repo, parsed.fragment);
    }

    if (parseGithubShorthand(trimmed)) |parsed| {
        return try buildGithubSaveReference(allocator, parsed.repo, parsed.fragment);
    }

    return allocator.dupe(u8, trimmed);
}

fn buildGithubSaveReference(
    allocator: std.mem.Allocator,
    repo: []const u8,
    fragment: ?[]const u8,
) ![]u8 {
    if (fragment) |ref| {
        return std.fmt.allocPrint(
            allocator,
            "--save git+https://github.com/{s}#{s}",
            .{ repo, ref },
        );
    }
    return std.fmt.allocPrint(allocator, "--save git+https://github.com/{s}", .{repo});
}

fn parseGithubHttpReference(value: []const u8) ?struct { repo: []const u8, fragment: ?[]const u8 } {
    const prefixes = [_][]const u8{ "https://github.com/", "http://github.com/" };
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, value, prefix)) continue;
        var path = value[prefix.len..];
        var fragment: ?[]const u8 = null;

        if (std.mem.indexOfScalar(u8, path, '#')) |hash_index| {
            fragment = path[hash_index + 1 ..];
            path = path[0..hash_index];
        }
        if (std.mem.indexOfScalar(u8, path, '?')) |query_index| {
            path = path[0..query_index];
        }
        path = std.mem.trimRight(u8, path, "/");

        var parts = std.mem.splitScalar(u8, path, '/');
        const owner = parts.next() orelse return null;
        const repo_name = parts.next() orelse return null;
        const remainder = parts.rest();
        if (owner.len == 0 or repo_name.len == 0) return null;

        var repo = repo_name;
        if (std.mem.endsWith(u8, repo, ".git")) {
            repo = repo[0 .. repo.len - 4];
        }

        if (remainder.len != 0) {
            if (!std.mem.startsWith(u8, remainder, "tree/")) return null;
            fragment = remainder["tree/".len..];
            if (fragment.?.len == 0) return null;
        }

        return .{
            .repo = value[prefix.len .. prefix.len + owner.len + 1 + repo.len],
            .fragment = fragment,
        };
    }
    return null;
}

fn parseGithubShorthand(value: []const u8) ?struct { repo: []const u8, fragment: ?[]const u8 } {
    var repo = value;
    var fragment: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, value, '#')) |hash_index| {
        repo = value[0..hash_index];
        fragment = value[hash_index + 1 ..];
        if (fragment.?.len == 0) return null;
    }

    if (std.mem.indexOfScalar(u8, repo, '/')) |slash_index| {
        const owner = repo[0..slash_index];
        const name = repo[slash_index + 1 ..];
        if (owner.len == 0 or name.len == 0) return null;
        if (std.mem.indexOfScalar(u8, name, '/')) |_| return null;
        var trimmed_repo = repo;
        if (std.mem.endsWith(u8, trimmed_repo, ".git")) {
            trimmed_repo = trimmed_repo[0 .. trimmed_repo.len - 4];
        }
        return .{ .repo = trimmed_repo, .fragment = fragment };
    }
    return null;
}
