const std = @import("std");
const config = @import("config.zig");

pub fn resolveSupportedAlloc(
    allocator: std.mem.Allocator,
    requested_filetype: []const u8,
    filepath: []const u8,
) ![]u8 {
    const requested = std.mem.trim(u8, requested_filetype, " \t\r\n");
    const aliased = aliasFiletype(requested);
    const ext_filetype = extensionFiletype(filepath);

    if (aliased.len != 0) {
        if (hasConfiguredEntryForFiletype(allocator, aliased)) {
            return allocator.dupe(u8, aliased);
        }
        if (ext_filetype) |value| {
            return allocator.dupe(u8, value);
        }
        if (try shebangFiletypeAlloc(allocator, filepath)) |value| {
            return value;
        }
        return allocator.dupe(u8, aliased);
    }

    if (ext_filetype) |value| {
        return allocator.dupe(u8, value);
    }
    if (try shebangFiletypeAlloc(allocator, filepath)) |value| {
        return value;
    }
    return allocator.dupe(u8, requested);
}

fn aliasFiletype(requested: []const u8) []const u8 {
    if (std.mem.eql(u8, requested, "c++")) return "cpp";
    if (std.mem.eql(u8, requested, "bash")) return "sh";
    if (std.mem.eql(u8, requested, "cxx")) return "cpp";
    if (std.mem.eql(u8, requested, "javascriptreact")) return "javascript";
    if (std.mem.eql(u8, requested, "jsx")) return "javascript";
    if (std.mem.eql(u8, requested, "typescriptreact")) return "typescript";
    if (std.mem.eql(u8, requested, "tsx")) return "typescript";
    return requested;
}

fn extensionFiletype(filepath: []const u8) ?[]const u8 {
    const ext_with_dot = std.fs.path.extension(filepath);
    if (ext_with_dot.len <= 1) return null;
    const ext = ext_with_dot[1..];

    if (std.mem.eql(u8, ext, "bash")) return "sh";
    if (std.mem.eql(u8, ext, "c")) return "c";
    if (std.mem.eql(u8, ext, "cc")) return "cpp";
    if (std.mem.eql(u8, ext, "cjs")) return "javascript";
    if (std.mem.eql(u8, ext, "cpp")) return "cpp";
    if (std.mem.eql(u8, ext, "cts")) return "typescript";
    if (std.mem.eql(u8, ext, "cxx")) return "cpp";
    if (std.mem.eql(u8, ext, "dart")) return "dart";
    if (std.mem.eql(u8, ext, "ex")) return "elixir";
    if (std.mem.eql(u8, ext, "exs")) return "elixir";
    if (std.mem.eql(u8, ext, "f")) return "fortran";
    if (std.mem.eql(u8, ext, "f03")) return "fortran";
    if (std.mem.eql(u8, ext, "f08")) return "fortran";
    if (std.mem.eql(u8, ext, "f90")) return "fortran";
    if (std.mem.eql(u8, ext, "f95")) return "fortran";
    if (std.mem.eql(u8, ext, "for")) return "fortran";
    if (std.mem.eql(u8, ext, "go")) return "go";
    if (std.mem.eql(u8, ext, "hs")) return "haskell";
    if (std.mem.eql(u8, ext, "htm")) return "html";
    if (std.mem.eql(u8, ext, "html")) return "html";
    if (std.mem.eql(u8, ext, "java")) return "java";
    if (std.mem.eql(u8, ext, "jl")) return "julia";
    if (std.mem.eql(u8, ext, "js")) return "javascript";
    if (std.mem.eql(u8, ext, "json")) return "json";
    if (std.mem.eql(u8, ext, "kt")) return "kotlin";
    if (std.mem.eql(u8, ext, "kts")) return "kotlin";
    if (std.mem.eql(u8, ext, "lua")) return "lua";
    if (std.mem.eql(u8, ext, "mjs")) return "javascript";
    if (std.mem.eql(u8, ext, "mts")) return "typescript";
    if (std.mem.eql(u8, ext, "odin")) return "odin";
    if (std.mem.eql(u8, ext, "perl")) return "perl";
    if (std.mem.eql(u8, ext, "php")) return "php";
    if (std.mem.eql(u8, ext, "pl")) return "perl";
    if (std.mem.eql(u8, ext, "pm")) return "perl";
    if (std.mem.eql(u8, ext, "py")) return "python";
    if (std.mem.eql(u8, ext, "pyw")) return "python";
    if (std.mem.eql(u8, ext, "r")) return "r";
    if (std.mem.eql(u8, ext, "rb")) return "ruby";
    if (std.mem.eql(u8, ext, "rs")) return "rust";
    if (std.mem.eql(u8, ext, "sh")) return "sh";
    if (std.mem.eql(u8, ext, "swift")) return "swift";
    if (std.mem.eql(u8, ext, "ts")) return "typescript";
    if (std.mem.eql(u8, ext, "tsx")) return "typescript";
    if (std.mem.eql(u8, ext, "zig")) return "zig";
    if (std.mem.eql(u8, ext, "zsh")) return "zsh";
    return null;
}

fn shebangFiletypeAlloc(allocator: std.mem.Allocator, filepath: []const u8) !?[]u8 {
    if (filepath.len == 0) return null;

    var file = if (std.fs.path.isAbsolute(filepath))
        std.fs.openFileAbsolute(filepath, .{}) catch return null
    else
        std.fs.cwd().openFile(filepath, .{}) catch return null;
    defer file.close();

    var buffer: [256]u8 = undefined;
    const bytes_read = try file.readAll(buffer[0..]);
    if (bytes_read == 0) return null;

    const text = buffer[0..bytes_read];
    const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const first_line = std.mem.trimRight(u8, text[0..line_end], "\r");
    if (!std.mem.startsWith(u8, first_line, "#!")) return null;

    const rest = std.mem.trimLeft(u8, first_line[2..], " \t");
    var interpreter: ?[]const u8 = null;
    if (std.mem.startsWith(u8, rest, "/usr/bin/env")) {
        const env_rest = std.mem.trimLeft(u8, rest["/usr/bin/env".len..], " \t");
        if (std.mem.startsWith(u8, env_rest, "-S")) {
            interpreter = nextToken(std.mem.trimLeft(u8, env_rest["-S".len..], " \t"));
        } else {
            interpreter = nextToken(env_rest);
        }
    } else {
        const executable = nextToken(rest) orelse return null;
        interpreter = std.fs.path.basename(executable);
    }

    const mapped = mapShebangInterpreter(interpreter orelse return null) orelse return null;
    return allocator.dupe(u8, mapped);
}

fn nextToken(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimLeft(u8, text, " \t");
    if (trimmed.len == 0) return null;
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    return trimmed[0..end];
}

fn mapShebangInterpreter(interpreter: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, interpreter, "bash")) return "sh";
    if (std.mem.eql(u8, interpreter, "bun")) return "javascript";
    if (std.mem.eql(u8, interpreter, "deno")) return "javascript";
    if (std.mem.eql(u8, interpreter, "elixir")) return "elixir";
    if (std.mem.eql(u8, interpreter, "julia")) return "julia";
    if (std.mem.eql(u8, interpreter, "lua")) return "lua";
    if (std.mem.eql(u8, interpreter, "node")) return "javascript";
    if (std.mem.eql(u8, interpreter, "nodejs")) return "javascript";
    if (std.mem.eql(u8, interpreter, "perl")) return "perl";
    if (std.mem.eql(u8, interpreter, "php")) return "php";
    if (std.mem.eql(u8, interpreter, "python")) return "python";
    if (std.mem.eql(u8, interpreter, "python3")) return "python";
    if (std.mem.eql(u8, interpreter, "r")) return "r";
    if (std.mem.eql(u8, interpreter, "rscript")) return "r";
    if (std.mem.eql(u8, interpreter, "ruby")) return "ruby";
    if (std.mem.eql(u8, interpreter, "sh")) return "sh";
    if (std.mem.eql(u8, interpreter, "zsh")) return "zsh";
    return null;
}

fn hasConfiguredEntryForFiletype(allocator: std.mem.Allocator, filetype: []const u8) bool {
    const raw = config.getSyncedConfigJson() orelse return false;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return false;
    defer parsed.deinit();

    if (parsed.value != .object) return false;
    const root = parsed.value.object;
    if (root.get("runners")) |runners| {
        if (runners == .object and runners.object.get(filetype) != null) return true;
    }
    if (root.get("build_commands")) |commands| {
        if (commands == .object and commands.object.get(filetype) != null) return true;
    }
    return false;
}

test "resolveSupportedAlloc prefers extension over unconfigured aliased filetype" {
    const allocator = std.testing.allocator;

    const resolved = try resolveSupportedAlloc(allocator, "typescriptreact", "/tmp/example.tsx");
    defer allocator.free(resolved);

    try std.testing.expectEqualStrings("typescript", resolved);
}

test "resolveSupportedAlloc preserves configured aliased filetype" {
    const allocator = std.testing.allocator;
    @import("config/store.zig").reset();
    defer @import("config/store.zig").reset();
    try @import("config/store.zig").setSyncedConfigJson(
        \\{"runners":{"javascript":"node $file"},"build_commands":{},"revision":1}
    , 1);

    const resolved = try resolveSupportedAlloc(allocator, "javascriptreact", "/tmp/example.jsx");
    defer allocator.free(resolved);

    try std.testing.expectEqualStrings("javascript", resolved);
}
