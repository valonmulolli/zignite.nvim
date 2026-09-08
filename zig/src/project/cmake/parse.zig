const std = @import("std");
const common = @import("../core/common.zig");
const pathing = @import("../../pathing.zig");

pub const Target = struct {
    name: []u8,
    matched: bool,
    exact_match: bool = false,
    artifact_path: ?[]u8 = null,
};

const MatchKind = enum {
    none,
    basename,
    exact,
};

const Variable = struct {
    name: []u8,
    values: [][]u8,
};

pub fn freeOwnedTargets(allocator: std.mem.Allocator, items: []Target) void {
    for (items) |item| {
        allocator.free(item.name);
        if (item.artifact_path) |artifact_path| allocator.free(artifact_path);
    }
    allocator.free(items);
}

pub fn parseTargets(
    allocator: std.mem.Allocator,
    contents: []const u8,
    cmake_lists_path: []const u8,
    match_path: ?[]const u8,
) ![]Target {
    const root = pathing.dirOrDot(cmake_lists_path);
    const normalized_root = try common.normalizePathAlloc(allocator, root);
    defer allocator.free(normalized_root);

    var relative_match_path: ?[]u8 = null;
    defer if (relative_match_path) |value| allocator.free(value);
    var basename: ?[]u8 = null;
    defer if (basename) |value| allocator.free(value);

    if (match_path) |raw_match_path| {
        const normalized_match = try common.normalizePathAlloc(allocator, raw_match_path);
        defer allocator.free(normalized_match);
        relative_match_path = try common.makeRelativeToRootAlloc(allocator, normalized_root, normalized_match);
        basename = try allocator.dupe(u8, std.fs.path.basename(normalized_match));
    }

    var targets: std.ArrayList(Target) = .empty;
    errdefer {
        for (targets.items) |item| allocator.free(item.name);
        targets.deinit(allocator);
    }

    const sanitized = try stripHashCommentsAlloc(allocator, contents);
    defer allocator.free(sanitized);

    const project_name = parseProjectName(sanitized);
    var variables: std.ArrayList(Variable) = .empty;
    defer deinitVariables(allocator, &variables);
    try collectSetVariables(allocator, sanitized, &variables);

    try parseExecutableBlocks(
        allocator,
        sanitized,
        project_name,
        relative_match_path,
        basename,
        variables.items,
        &targets,
    );

    try applyTargetSources(allocator, sanitized, project_name, relative_match_path, basename, variables.items, &targets);

    return try targets.toOwnedSlice(allocator);
}

fn commitBlock(
    allocator: std.mem.Allocator,
    block: []const u8,
    project_name: ?[]const u8,
    relative_match_path: ?[]const u8,
    basename: ?[]const u8,
    variables: []const Variable,
    targets: *std.ArrayList(Target),
) !void {
    const args = extractAddExecutableArgs(block) orelse return;
    const tokens = try tokenizeWhitespaceArgsAlloc(allocator, args);
    defer common.freeOwnedNameList(allocator, tokens);
    if (tokens.len == 0) return;

    var index: usize = 0;
    while (index < tokens.len) : (index += 1) {
        const token = resolveToken(tokens[index], project_name);
        if (std.mem.eql(u8, token, "WIN32") or std.mem.eql(u8, token, "MACOSX_BUNDLE") or std.mem.eql(u8, token, "EXCLUDE_FROM_ALL")) {
            continue;
        }
        break;
    }
    if (index >= tokens.len) return;

    const target = resolveToken(tokens[index], project_name);
    if (target.len == 0 or common.hasInvalidPayloadChars(target) or std.mem.find(u8, target, "${") != null) return;

    // IMPORTED and ALIAS declarations name existing targets; they do not
    // create an artifact that `cmake --build --target` can build.
    if (index + 1 < tokens.len and
        (std.ascii.eqlIgnoreCase(tokens[index + 1], "IMPORTED") or
            std.ascii.eqlIgnoreCase(tokens[index + 1], "ALIAS")))
    {
        return;
    }

    var match_kind: MatchKind = .none;
    if (relative_match_path != null or basename != null) {
        var source_index = index + 1;
        while (source_index < tokens.len) : (source_index += 1) {
            if (isCmakeSourceListKeyword(tokens[source_index])) continue;
            const token_match = try sourceTokenMatchKind(allocator, tokens[source_index], project_name, relative_match_path, basename, variables);
            if (token_match == .exact) {
                match_kind = .exact;
                break;
            }
            if (token_match == .basename) match_kind = .basename;
        }
    }

    for (targets.items) |*item| {
        if (std.mem.eql(u8, item.name, target)) {
            item.matched = item.matched or match_kind != .none;
            item.exact_match = item.exact_match or match_kind == .exact;
            return;
        }
    }

    const owned_name = try allocator.dupe(u8, target);
    targets.append(allocator, .{
        .name = owned_name,
        .matched = match_kind != .none,
        .exact_match = match_kind == .exact,
        .artifact_path = null,
    }) catch |err| {
        allocator.free(owned_name);
        return err;
    };
}

fn indexOfAddExecutable(line: []const u8) ?usize {
    return indexOfCommandCall(line, "add_executable");
}

fn parseExecutableBlocks(
    allocator: std.mem.Allocator,
    contents: []const u8,
    project_name: ?[]const u8,
    relative_match_path: ?[]const u8,
    basename: ?[]const u8,
    variables: []const Variable,
    targets: *std.ArrayList(Target),
) !void {
    var cursor: usize = 0;
    while (cursor < contents.len) {
        const relative_start = indexOfAddExecutable(contents[cursor..]) orelse break;
        const start = cursor + relative_start;
        const relative_end = findMatchingParen(contents[start..]) orelse break;
        const end = start + relative_end + 1;
        try commitBlock(
            allocator,
            contents[start..end],
            project_name,
            relative_match_path,
            basename,
            variables,
            targets,
        );
        cursor = end;
    }
}

fn stripHashCommentsAlloc(allocator: std.mem.Allocator, contents: []const u8) ![]u8 {
    const sanitized = try allocator.alloc(u8, contents.len);
    errdefer allocator.free(sanitized);

    var input_index: usize = 0;
    var quote: u8 = 0;
    var escaped = false;
    var line_comment = false;
    var bracket_comment_equals: ?usize = null;

    while (input_index < contents.len) {
        const ch = contents[input_index];

        if (bracket_comment_equals) |equals| {
            if (bracketCommentCloseLen(contents, input_index, equals)) |close_len| {
                @memset(sanitized[input_index .. input_index + close_len], ' ');
                input_index += close_len;
                bracket_comment_equals = null;
            } else {
                sanitized[input_index] = if (ch == '\n') '\n' else ' ';
                input_index += 1;
            }
            continue;
        }

        if (line_comment) {
            if (ch == '\n') {
                sanitized[input_index] = '\n';
                line_comment = false;
            } else {
                sanitized[input_index] = ' ';
            }
            input_index += 1;
            continue;
        }

        if (quote != 0) {
            sanitized[input_index] = ch;
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == quote) {
                quote = 0;
            }
            input_index += 1;
            continue;
        }

        if (ch == '"' or ch == '\'') {
            quote = ch;
            sanitized[input_index] = ch;
            input_index += 1;
            continue;
        }

        if (ch == '#') {
            if (input_index + 1 < contents.len) {
                if (bracketCommentOpenEquals(contents, input_index + 1)) |equals| {
                    const open_len = 1 + 2 + equals;
                    @memset(sanitized[input_index .. input_index + open_len], ' ');
                    input_index += open_len;
                    bracket_comment_equals = equals;
                    continue;
                }
            }
            sanitized[input_index] = ' ';
            input_index += 1;
            line_comment = true;
            continue;
        }

        sanitized[input_index] = ch;
        input_index += 1;
    }

    return sanitized;
}

fn bracketCommentOpenEquals(text: []const u8, open_index: usize) ?usize {
    if (open_index >= text.len or text[open_index] != '[') return null;

    var index = open_index + 1;
    while (index < text.len and text[index] == '=') : (index += 1) {}
    if (index >= text.len or text[index] != '[') return null;
    return index - open_index - 1;
}

fn bracketCommentCloseLen(text: []const u8, close_index: usize, equals: usize) ?usize {
    if (close_index >= text.len or text[close_index] != ']') return null;
    const end = close_index + 1 + equals;
    if (end >= text.len or text[end] != ']') return null;
    for (text[close_index + 1 .. end]) |ch| {
        if (ch != '=') return null;
    }
    return equals + 2;
}

fn findMatchingParen(text: []const u8) ?usize {
    const open_idx = std.mem.findScalar(u8, text, '(') orelse return null;
    var depth: usize = 0;
    var quote: ?u8 = null;
    var escaped = false;
    var bracket_arg_equals: ?usize = null;

    var index = open_idx;
    while (index < text.len) : (index += 1) {
        const ch = text[index];
        if (bracket_arg_equals) |equals| {
            if (bracketCommentCloseLen(text, index, equals)) |close_len| {
                index += close_len - 1;
                bracket_arg_equals = null;
            }
            continue;
        }
        if (escaped) {
            escaped = false;
            continue;
        }
        if (quote) |active_quote| {
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == active_quote) quote = null;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (bracketCommentOpenEquals(text, index)) |equals| {
            index += equals + 1;
            bracket_arg_equals = equals;
            continue;
        }
        if (ch == '(') {
            depth += 1;
        } else if (ch == ')') {
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return null;
}

fn indexOfSet(line: []const u8) ?usize {
    return indexOfCommandCall(line, "set");
}

fn indexOfTargetSources(line: []const u8) ?usize {
    return indexOfCommandCall(line, "target_sources");
}

fn indexOfAddSubdirectory(line: []const u8) ?usize {
    return indexOfCommandCall(line, "add_subdirectory");
}

fn indexOfCommandCall(line: []const u8, name: []const u8) ?usize {
    var quote: ?u8 = null;
    var escaped = false;
    var bracket_arg_equals: ?usize = null;
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        if (bracket_arg_equals) |equals| {
            if (bracketCommentCloseLen(line, index, equals)) |close_len| {
                index += close_len - 1;
                bracket_arg_equals = null;
            }
            continue;
        }
        if (quote) |active_quote| {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (line[index] == '\\') {
                escaped = true;
                continue;
            }
            if (line[index] == active_quote) quote = null;
            continue;
        }

        if (line[index] == '"' or line[index] == '\'') {
            quote = line[index];
            continue;
        }
        if (bracketCommentOpenEquals(line, index)) |equals| {
            index += equals + 1;
            bracket_arg_equals = equals;
            continue;
        }
        if (std.ascii.toLower(line[index]) != std.ascii.toLower(name[0])) continue;
        const remaining = line[index..];
        if (remaining.len < name.len) continue;
        if (!std.ascii.eqlIgnoreCase(remaining[0..name.len], name)) continue;
        if (index > 0 and isCmakeIdentChar(line[index - 1])) continue;
        const after = index + name.len;
        if (after >= line.len or line[after] == '(' or std.ascii.isWhitespace(line[after])) {
            return index;
        }
    }
    return null;
}

fn isCmakeIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn extractAddExecutableArgs(block: []const u8) ?[]const u8 {
    const open_idx = std.mem.findScalar(u8, block, '(') orelse return null;
    const close_idx = findMatchingParen(block) orelse return null;
    if (close_idx <= open_idx) return null;
    return block[open_idx + 1 .. close_idx];
}

fn countParenDelta(text: []const u8) isize {
    var delta: isize = 0;
    var quote: ?u8 = null;
    var escaped = false;
    var bracket_arg_equals: ?usize = null;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const ch = text[index];
        if (bracket_arg_equals) |equals| {
            if (bracketCommentCloseLen(text, index, equals)) |close_len| {
                index += close_len - 1;
                bracket_arg_equals = null;
            }
            continue;
        }
        if (escaped) {
            escaped = false;
            continue;
        }
        if (quote != null) {
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == quote.?) quote = null;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (bracketCommentOpenEquals(text, index)) |equals| {
            index += equals + 1;
            bracket_arg_equals = equals;
            continue;
        }
        if (ch == '(') delta += 1;
        if (ch == ')') delta -= 1;
    }
    return delta;
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

fn parseProjectName(contents: []const u8) ?[]const u8 {
    var awaiting_name = false;
    var project_depth: isize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = stripHashComment(common.stripTrailingCR(raw_line));
        if (!awaiting_name) {
            const project_idx = indexOfProjectCall(line) orelse continue;
            const open_idx = std.mem.findScalar(u8, line[project_idx..], '(') orelse continue;
            const args = line[project_idx + open_idx + 1 ..];
            const token = extractFirstToken(args);
            if (token.len > 0 and !std.mem.eql(u8, token, ")")) return token;

            project_depth = countParenDelta(line[project_idx..]);
            awaiting_name = project_depth > 0;
            continue;
        }

        const token = extractFirstToken(line);
        if (token.len > 0 and !std.mem.eql(u8, token, ")")) return token;
        project_depth += countParenDelta(line);
        if (project_depth <= 0) awaiting_name = false;
    }
    return null;
}

fn indexOfProjectCall(line: []const u8) ?usize {
    return indexOfCommandCall(line, "project");
}

fn extractFirstToken(text: []const u8) []const u8 {
    const trimmed = common.trimSpaces(text);
    if (trimmed.len == 0) return "";
    var start: usize = 0;
    var end: usize = trimmed.len;
    if ((trimmed[0] == '"' or trimmed[0] == '\'') and trimmed.len >= 2) {
        start = 1;
        var close_index = start;
        while (close_index < trimmed.len and trimmed[close_index] != trimmed[0]) : (close_index += 1) {}
        end = close_index;
    } else {
        var idx: usize = 0;
        while (idx < trimmed.len and !std.ascii.isWhitespace(trimmed[idx]) and trimmed[idx] != ')') : (idx += 1) {}
        end = idx;
    }
    return trimmed[start..end];
}

fn resolveToken(token: []const u8, project_name: ?[]const u8) []const u8 {
    if (project_name != null and std.mem.eql(u8, token, "${PROJECT_NAME}")) {
        return project_name.?;
    }
    return token;
}

fn sourceTokenMatchKind(
    allocator: std.mem.Allocator,
    token: []const u8,
    project_name: ?[]const u8,
    relative_match_path: ?[]const u8,
    basename: ?[]const u8,
    variables: []const Variable,
) !MatchKind {
    if (std.mem.startsWith(u8, token, "$<")) return .none;
    if (variableValues(variables, token)) |values| {
        var match_kind: MatchKind = .none;
        for (values) |value| {
            const value_match = try sourceTokenMatchKind(allocator, value, project_name, relative_match_path, basename, variables);
            if (value_match == .exact) return .exact;
            if (value_match == .basename) match_kind = .basename;
        }
        return match_kind;
    }

    const source_token = resolveToken(token, project_name);
    const normalized_source = try common.normalizePathAlloc(allocator, source_token);
    defer allocator.free(normalized_source);
    return normalizedSourceMatchKind(normalized_source, relative_match_path, basename);
}

fn normalizedSourceMatchKind(
    normalized_source: []const u8,
    relative_match_path: ?[]const u8,
    basename: ?[]const u8,
) MatchKind {
    if (normalized_source.len == 0) return .none;
    if (relative_match_path) |relative_path| {
        if (std.mem.eql(u8, normalized_source, relative_path)) return .exact;
    }
    if (basename) |file_basename| {
        if (std.mem.eql(u8, normalized_source, file_basename)) return .basename;
        if (std.mem.endsWith(u8, normalized_source, file_basename)) {
            const prefix_len = normalized_source.len - file_basename.len;
            if (prefix_len > 0 and normalized_source[prefix_len - 1] == '/') return .basename;
        }
    }
    return .none;
}

fn variableValues(variables: []const Variable, token: []const u8) ?[][]u8 {
    const name = variableName(token) orelse return null;
    for (variables) |variable| {
        if (std.mem.eql(u8, variable.name, name)) return variable.values;
    }
    return null;
}

fn variableName(token: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, token, "${") or !std.mem.endsWith(u8, token, "}")) return null;
    const name = token[2 .. token.len - 1];
    if (name.len == 0) return null;
    return name;
}

fn isCmakeSourceListKeyword(token: []const u8) bool {
    return std.mem.eql(u8, token, "PRIVATE") or
        std.mem.eql(u8, token, "PUBLIC") or
        std.mem.eql(u8, token, "INTERFACE") or
        std.mem.eql(u8, token, "BEFORE") or
        std.mem.eql(u8, token, "SYSTEM") or
        std.mem.eql(u8, token, "FILE_SET") or
        std.mem.eql(u8, token, "TYPE") or
        std.mem.eql(u8, token, "BASE_DIRS") or
        std.mem.eql(u8, token, "FILES");
}

fn collectSetVariables(
    allocator: std.mem.Allocator,
    contents: []const u8,
    variables: *std.ArrayList(Variable),
) !void {
    var capture: ?std.ArrayList(u8) = null;
    defer if (capture) |*list| list.deinit(allocator);
    var depth: isize = 0;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = stripHashComment(common.stripTrailingCR(raw_line));
        if (capture == null) {
            const start_idx = indexOfSet(line) orelse continue;
            var list: std.ArrayList(u8) = .empty;
            errdefer list.deinit(allocator);
            try list.appendSlice(allocator, line[start_idx..]);
            depth = countParenDelta(line[start_idx..]);
            if (depth <= 0) {
                try commitSetBlock(allocator, list.items, variables);
                list.deinit(allocator);
            } else {
                capture = list;
            }
        } else {
            try capture.?.append(allocator, ' ');
            try capture.?.appendSlice(allocator, line);
            depth += countParenDelta(line);
            if (depth <= 0) {
                try commitSetBlock(allocator, capture.?.items, variables);
                capture.?.deinit(allocator);
                capture = null;
            }
        }
    }
}

fn commitSetBlock(
    allocator: std.mem.Allocator,
    block: []const u8,
    variables: *std.ArrayList(Variable),
) !void {
    const args = extractArgs(block) orelse return;
    const tokens = try tokenizeWhitespaceArgsAlloc(allocator, args);
    defer common.freeOwnedNameList(allocator, tokens);
    if (tokens.len < 2) return;

    var values: std.ArrayList([]u8) = .empty;
    errdefer common.deinitOwnedNameList(allocator, &values);
    for (tokens[1..]) |token| {
        if (std.mem.eql(u8, token, "CACHE") or std.mem.eql(u8, token, "PARENT_SCOPE")) break;
        try appendVariableValueTokens(allocator, &values, token);
    }
    if (values.items.len == 0) {
        values.deinit(allocator);
        return;
    }

    try upsertVariable(allocator, variables, tokens[0], try values.toOwnedSlice(allocator));
}

fn appendVariableValueTokens(
    allocator: std.mem.Allocator,
    values: *std.ArrayList([]u8),
    token: []const u8,
) !void {
    var parts = std.mem.splitScalar(u8, token, ';');
    while (parts.next()) |part| {
        const trimmed = common.trimSpaces(part);
        if (trimmed.len == 0) continue;
        const owned = try allocator.dupe(u8, trimmed);
        values.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
    }
}

fn upsertVariable(
    allocator: std.mem.Allocator,
    variables: *std.ArrayList(Variable),
    name: []const u8,
    values: [][]u8,
) !void {
    errdefer common.freeOwnedNameList(allocator, values);
    for (variables.items) |*variable| {
        if (!std.mem.eql(u8, variable.name, name)) continue;
        common.freeOwnedNameList(allocator, variable.values);
        variable.values = values;
        return;
    }

    const owned_name = try allocator.dupe(u8, name);
    variables.append(allocator, .{
        .name = owned_name,
        .values = values,
    }) catch |err| {
        allocator.free(owned_name);
        return err;
    };
}

fn deinitVariables(allocator: std.mem.Allocator, variables: *std.ArrayList(Variable)) void {
    for (variables.items) |variable| {
        allocator.free(variable.name);
        common.freeOwnedNameList(allocator, variable.values);
    }
    variables.deinit(allocator);
}

fn applyTargetSources(
    allocator: std.mem.Allocator,
    contents: []const u8,
    project_name: ?[]const u8,
    relative_match_path: ?[]const u8,
    basename: ?[]const u8,
    variables: []const Variable,
    targets: *std.ArrayList(Target),
) !void {
    var capture: ?std.ArrayList(u8) = null;
    defer if (capture) |*list| list.deinit(allocator);
    var depth: isize = 0;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = stripHashComment(common.stripTrailingCR(raw_line));
        if (capture == null) {
            const start_idx = indexOfTargetSources(line) orelse continue;
            var list: std.ArrayList(u8) = .empty;
            errdefer list.deinit(allocator);
            try list.appendSlice(allocator, line[start_idx..]);
            depth = countParenDelta(line[start_idx..]);
            if (depth <= 0) {
                try commitTargetSourcesBlock(allocator, list.items, project_name, relative_match_path, basename, variables, targets);
                list.deinit(allocator);
            } else {
                capture = list;
            }
        } else {
            try capture.?.append(allocator, ' ');
            try capture.?.appendSlice(allocator, line);
            depth += countParenDelta(line);
            if (depth <= 0) {
                try commitTargetSourcesBlock(allocator, capture.?.items, project_name, relative_match_path, basename, variables, targets);
                capture.?.deinit(allocator);
                capture = null;
            }
        }
    }
}

fn commitTargetSourcesBlock(
    allocator: std.mem.Allocator,
    block: []const u8,
    project_name: ?[]const u8,
    relative_match_path: ?[]const u8,
    basename: ?[]const u8,
    variables: []const Variable,
    targets: *std.ArrayList(Target),
) !void {
    if (relative_match_path == null and basename == null) return;
    const args = extractArgs(block) orelse return;
    const tokens = try tokenizeWhitespaceArgsAlloc(allocator, args);
    defer common.freeOwnedNameList(allocator, tokens);
    if (tokens.len < 2) return;

    const target_name = resolveToken(tokens[0], project_name);
    for (targets.items) |*target| {
        if (!std.mem.eql(u8, target.name, target_name)) continue;
        var match_kind: MatchKind = .none;
        for (tokens[1..]) |token| {
            if (isCmakeSourceListKeyword(token)) continue;
            const token_match = try sourceTokenMatchKind(allocator, token, project_name, relative_match_path, basename, variables);
            if (token_match == .exact) {
                target.matched = true;
                target.exact_match = true;
                return;
            }
            if (token_match == .basename) match_kind = .basename;
        }
        if (match_kind == .basename) target.matched = true;
    }
}

pub fn collectAddSubdirectoriesAlloc(
    allocator: std.mem.Allocator,
    contents: []const u8,
) ![][]u8 {
    const sanitized = try stripHashCommentsAlloc(allocator, contents);
    defer allocator.free(sanitized);

    var subdirs: std.ArrayList([]u8) = .empty;
    errdefer common.deinitOwnedNameList(allocator, &subdirs);
    var capture: ?std.ArrayList(u8) = null;
    defer if (capture) |*list| list.deinit(allocator);
    var depth: isize = 0;

    var lines = std.mem.splitScalar(u8, sanitized, '\n');
    while (lines.next()) |raw_line| {
        const line = stripHashComment(common.stripTrailingCR(raw_line));
        if (capture == null) {
            const start_idx = indexOfAddSubdirectory(line) orelse continue;
            var list: std.ArrayList(u8) = .empty;
            errdefer list.deinit(allocator);
            try list.appendSlice(allocator, line[start_idx..]);
            depth = countParenDelta(line[start_idx..]);
            if (depth <= 0) {
                try commitAddSubdirectoryBlock(allocator, list.items, &subdirs);
                list.deinit(allocator);
            } else {
                capture = list;
            }
        } else {
            try capture.?.append(allocator, ' ');
            try capture.?.appendSlice(allocator, line);
            depth += countParenDelta(line);
            if (depth <= 0) {
                try commitAddSubdirectoryBlock(allocator, capture.?.items, &subdirs);
                capture.?.deinit(allocator);
                capture = null;
            }
        }
    }

    return try subdirs.toOwnedSlice(allocator);
}

fn commitAddSubdirectoryBlock(
    allocator: std.mem.Allocator,
    block: []const u8,
    subdirs: *std.ArrayList([]u8),
) !void {
    const args = extractArgs(block) orelse return;
    const tokens = try tokenizeWhitespaceArgsAlloc(allocator, args);
    defer common.freeOwnedNameList(allocator, tokens);
    if (tokens.len == 0) return;

    const subdir = tokens[0];
    if (subdir.len == 0 or std.mem.find(u8, subdir, "${") != null) return;
    const owned = try allocator.dupe(u8, subdir);
    subdirs.append(allocator, owned) catch |err| {
        allocator.free(owned);
        return err;
    };
}

fn extractArgs(block: []const u8) ?[]const u8 {
    const open_idx = std.mem.findScalar(u8, block, '(') orelse return null;
    const close_idx = std.mem.lastIndexOfScalar(u8, block, ')') orelse return null;
    if (close_idx <= open_idx) return null;
    return block[open_idx + 1 .. close_idx];
}

fn tokenizeWhitespaceArgsAlloc(allocator: std.mem.Allocator, text: []const u8) ![][]u8 {
    var tokens: std.ArrayList([]u8) = .empty;
    errdefer common.deinitOwnedNameList(allocator, &tokens);

    var index: usize = 0;
    while (index < text.len) {
        while (index < text.len and std.ascii.isWhitespace(text[index])) : (index += 1) {}
        if (index >= text.len) break;

        var quote: ?u8 = null;
        var current: std.ArrayList(u8) = .empty;
        errdefer current.deinit(allocator);

        while (index < text.len) : (index += 1) {
            const ch = text[index];
            if (quote) |active_quote| {
                if (ch == active_quote) {
                    quote = null;
                } else {
                    try current.append(allocator, ch);
                }
            } else if (ch == '"' or ch == '\'') {
                quote = ch;
            } else if (std.ascii.isWhitespace(ch)) {
                break;
            } else {
                try current.append(allocator, ch);
            }
        }

        const token = common.trimSpaces(current.items);
        if (token.len > 0) {
            const owned_token = try allocator.dupe(u8, token);
            tokens.append(allocator, owned_token) catch |err| {
                allocator.free(owned_token);
                return err;
            };
        }
        current.deinit(allocator);
    }

    return try tokens.toOwnedSlice(allocator);
}

test "parse cmake targets resolves project name and matches relative source" {
    const allocator = std.testing.allocator;
    const contents =
        \\project(demo-app)
        \\add_executable(${PROJECT_NAME}
        \\  src/main.cpp
        \\  src/lib.cpp
        \\)
        \\add_executable(helper tools/helper.cpp)
    ;

    const targets = try parseTargets(
        allocator,
        contents,
        "/tmp/cmakeproj/CMakeLists.txt",
        "/tmp/cmakeproj/src/main.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 2), targets.len);
    try std.testing.expectEqualStrings("demo-app", targets[0].name);
    try std.testing.expect(targets[0].matched);
    try std.testing.expectEqualStrings("helper", targets[1].name);
    try std.testing.expect(!targets[1].matched);
}

test "parse cmake targets finds multiple commands on one line" {
    const allocator = std.testing.allocator;
    const targets = try parseTargets(
        allocator,
        "add_executable(first src/one.cpp) add_executable(second src/two.cpp)\n",
        "/tmp/cmakeproj/CMakeLists.txt",
        "/tmp/cmakeproj/src/two.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 2), targets.len);
    try std.testing.expectEqualStrings("first", targets[0].name);
    try std.testing.expect(!targets[0].matched);
    try std.testing.expectEqualStrings("second", targets[1].name);
    try std.testing.expect(targets[1].matched);
}

test "parse cmake prefers exact source matches over basename matches" {
    const allocator = std.testing.allocator;
    const targets = try parseTargets(
        allocator,
        "add_executable(first src/a/main.cpp) add_executable(second src/b/main.cpp)\n",
        "/tmp/cmakeproj/CMakeLists.txt",
        "/tmp/cmakeproj/src/b/main.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 2), targets.len);
    try std.testing.expect(targets[0].matched);
    try std.testing.expect(!targets[0].exact_match);
    try std.testing.expect(targets[1].matched);
    try std.testing.expect(targets[1].exact_match);
}

test "parse cmake resolves project name across multiline project call" {
    const allocator = std.testing.allocator;
    const contents =
        "project(\n" ++
        "  demo-app\n" ++
        "  LANGUAGES CXX\n" ++
        ")\n" ++
        "add_executable(${PROJECT_NAME} src/main.cpp)\n";

    const targets = try parseTargets(
        allocator,
        contents,
        "/tmp/cmakeproj/CMakeLists.txt",
        "/tmp/cmakeproj/src/main.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings("demo-app", targets[0].name);
    try std.testing.expect(targets[0].matched);
}

test "parse cmake targets merges duplicate target matches" {
    const allocator = std.testing.allocator;
    const contents =
        \\add_executable(app src/main.cpp)
        \\add_executable(app src/other.cpp)
    ;

    const targets = try parseTargets(
        allocator,
        contents,
        "/tmp/cmakeproj/CMakeLists.txt",
        "/tmp/cmakeproj/src/main.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings("app", targets[0].name);
    try std.testing.expect(targets[0].matched);
}

test "parse cmake targets with primary match" {
    const allocator = std.testing.allocator;
    const targets = try parseTargets(
        allocator,
        "project(app)\nadd_executable(\n  app\n  src/main.cpp\n  src/other.cpp\n)\n",
        "/tmp/cmakeproj/CMakeLists.txt",
        "/tmp/cmakeproj/src/main.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings("app", targets[0].name);
    try std.testing.expect(targets[0].matched);
}

test "parse cmake ignores command names inside strings and identifiers" {
    const allocator = std.testing.allocator;
    const targets = try parseTargets(
        allocator,
        "message(\"project(fake)\")\nmessage(\"add_executable(fake)\")\nmyproject(wrong)\nset(PROJECT_NAME wrong)\nproject(real)\nadd_executable(${PROJECT_NAME} src/main.cpp)\n",
        "/tmp/cmakeproj/CMakeLists.txt",
        "/tmp/cmakeproj/src/main.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings("real", targets[0].name);
    try std.testing.expect(targets[0].matched);
}

test "parse cmake ignores imported and alias executable targets" {
    const allocator = std.testing.allocator;
    const targets = try parseTargets(
        allocator,
        "project(demo)\nadd_executable(imported IMPORTED GLOBAL)\nadd_executable(alias ALIAS imported)\nadd_executable(real src/main.cpp)\n",
        "/tmp/cmakeproj/CMakeLists.txt",
        "/tmp/cmakeproj/src/main.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings("real", targets[0].name);
    try std.testing.expect(targets[0].matched);
}

test "parse cmake targets keeps hash inside quoted string literals" {
    const allocator = std.testing.allocator;
    const contents =
        \\project("demo#app")
        \\add_executable(app "src/file#1.cpp" src/main.cpp) # trailing comment
    ;

    const targets = try parseTargets(
        allocator,
        contents,
        "/tmp/cmakeproj/CMakeLists.txt",
        "/tmp/cmakeproj/src/main.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings("app", targets[0].name);
    try std.testing.expect(targets[0].matched);
}

test "parse cmake ignores multiline bracket comments" {
    const allocator = std.testing.allocator;
    const contents =
        "#[=[\n" ++
        "add_executable(fake src/main.cpp)\n" ++
        "set(PROJECT_NAME fake)\n" ++
        "]=]\n" ++
        "project(real)\n" ++
        "add_executable(real src/main.cpp)\n";

    const targets = try parseTargets(
        allocator,
        contents,
        "/tmp/cmakeproj/CMakeLists.txt",
        "/tmp/cmakeproj/src/main.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings("real", targets[0].name);
    try std.testing.expect(targets[0].matched);
}

test "parse cmake ignores commands inside bracket arguments" {
    const allocator = std.testing.allocator;
    const contents =
        "set(DOCUMENTATION [=[\n" ++
        "add_executable(fake src/fake.cpp)\n" ++
        "]=])\n" ++
        "add_executable(real src/main.cpp)\n";

    const targets = try parseTargets(
        allocator,
        contents,
        "/tmp/cmakeproj/CMakeLists.txt",
        "/tmp/cmakeproj/src/main.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings("real", targets[0].name);
    try std.testing.expect(targets[0].matched);
}

test "parse cmake targets ignores parentheses inside quoted strings" {
    const allocator = std.testing.allocator;
    const contents =
        "add_executable(\n" ++
        "  app\n" ++
        "  \"src/part(.cpp\"\n" ++
        ")\n";

    const targets = try parseTargets(
        allocator,
        contents,
        "/tmp/cmakeproj/CMakeLists.txt",
        "/tmp/cmakeproj/src/part(.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings("app", targets[0].name);
    try std.testing.expect(targets[0].matched);
}

test "parse cmake targets expands set variables used as sources" {
    const allocator = std.testing.allocator;
    const contents =
        \\set(APP_SOURCES
        \\  src/main.cpp
        \\  src/lib.cpp
        \\)
        \\add_executable(app ${APP_SOURCES})
    ;

    const targets = try parseTargets(
        allocator,
        contents,
        "/tmp/cmakeproj/CMakeLists.txt",
        "/tmp/cmakeproj/src/main.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings("app", targets[0].name);
    try std.testing.expect(targets[0].matched);
}

test "parse cmake targets marks target_sources matches" {
    const allocator = std.testing.allocator;
    const contents =
        \\add_executable(app)
        \\target_sources(app
        \\  PRIVATE
        \\    src/main.cpp
        \\)
    ;

    const targets = try parseTargets(
        allocator,
        contents,
        "/tmp/cmakeproj/CMakeLists.txt",
        "/tmp/cmakeproj/src/main.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings("app", targets[0].name);
    try std.testing.expect(targets[0].matched);
}

test "parse cmake targets rejects unsafe protocol names" {
    const allocator = std.testing.allocator;
    const targets = try parseTargets(
        allocator,
        "add_executable(@@ZQF_RES_END src/main.cpp)\n",
        "/tmp/cmakeproj/CMakeLists.txt",
        "/tmp/cmakeproj/src/main.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 0), targets.len);
}

test "collect cmake add_subdirectory entries" {
    const allocator = std.testing.allocator;
    const subdirs = try collectAddSubdirectoriesAlloc(allocator,
        \\add_subdirectory(app)
        \\add_subdirectory("tools/cli" build-cli EXCLUDE_FROM_ALL)
    );
    defer common.freeOwnedNameList(allocator, subdirs);

    try std.testing.expectEqual(@as(usize, 2), subdirs.len);
    try std.testing.expectEqualStrings("app", subdirs[0]);
    try std.testing.expectEqualStrings("tools/cli", subdirs[1]);
}

test "collect cmake add_subdirectory ignores multiline bracket comments" {
    const allocator = std.testing.allocator;
    const subdirs = try collectAddSubdirectoriesAlloc(allocator, "#[=[\n" ++
        "add_subdirectory(fake)\n" ++
        "]=]\n" ++
        "add_subdirectory(real)\n");
    defer common.freeOwnedNameList(allocator, subdirs);

    try std.testing.expectEqual(@as(usize, 1), subdirs.len);
    try std.testing.expectEqualStrings("real", subdirs[0]);
}
