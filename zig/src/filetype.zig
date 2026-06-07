const std = @import("std");
const config_view = @import("config/view.zig");

pub fn resolveSupportedAlloc(
    allocator: std.mem.Allocator,
    requested_filetype: []const u8,
    filepath: []const u8,
) ![]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return resolveSupportedAllocWithIO(threaded.io(), allocator, requested_filetype, filepath);
}

pub fn resolveSupportedAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    requested_filetype: []const u8,
    filepath: []const u8,
) ![]u8 {
    const requested = std.mem.trim(u8, requested_filetype, " \t\r\n");
    const aliased = aliasFiletype(requested);
    const named_filetype = filenameFiletype(filepath);
    const ext_filetype = extensionFiletype(filepath);

    if (aliased.len != 0) {
        if (config_view.hasConfiguredEntryForFiletype(aliased)) {
            return allocator.dupe(u8, aliased);
        }
        if (named_filetype) |value| {
            return allocator.dupe(u8, value);
        }
        if (ext_filetype) |value| {
            return allocator.dupe(u8, value);
        }
        if (try shebangFiletypeAllocWithIO(io, allocator, filepath)) |value| {
            return value;
        }
        return allocator.dupe(u8, aliased);
    }

    if (named_filetype) |value| {
        return allocator.dupe(u8, value);
    }
    if (ext_filetype) |value| {
        return allocator.dupe(u8, value);
    }
    if (try shebangFiletypeAllocWithIO(io, allocator, filepath)) |value| {
        return value;
    }
    return allocator.dupe(u8, requested);
}

fn aliasFiletype(requested: []const u8) []const u8 {
    return alias_map.get(requested) orelse requested;
}

const alias_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "c++", "cpp" },
    .{ "bash", "sh" },
    .{ "cxx", "cpp" },
    .{ "javascriptreact", "javascript" },
    .{ "jsx", "javascript" },
    .{ "typescriptreact", "typescript" },
    .{ "tsx", "typescript" },
    .{ "cmake", "cpp" },
    .{ "make", "cpp" },
    .{ "meson", "cpp" },
    .{ "groovy", "java" },
    .{ "objcpp", "cpp" },
    .{ "objc", "c" },
    .{ "cuda", "cpp" },
});

fn filenameFiletype(filepath: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(filepath);
    return filename_map.get(base);
}

const filename_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "BUILD", "bzl" },
    .{ "BUILD.bazel", "bzl" },
    .{ "Cargo.toml", "rust" },
    .{ "CMakeLists.txt", "cpp" },
    .{ "GNUmakefile", "cpp" },
    .{ "MODULE.bazel", "bzl" },
    .{ "Makefile", "cpp" },
    .{ "WORKSPACE", "bzl" },
    .{ "WORKSPACE.bazel", "bzl" },
    .{ "build.gradle", "java" },
    .{ "build.gradle.kts", "kotlin" },
    .{ "go.mod", "go" },
    .{ "go.work", "go" },
    .{ "makefile", "cpp" },
    .{ "meson.build", "cpp" },
    .{ "package.json", "javascript" },
    .{ "pnpm-lock.yaml", "javascript" },
    .{ "pom.xml", "java" },
    .{ "pyproject.toml", "python" },
    .{ "requirements.txt", "python" },
    .{ "settings.gradle", "java" },
    .{ "settings.gradle.kts", "kotlin" },
    .{ "uv.lock", "python" },
    .{ "yarn.lock", "javascript" },
});

fn extensionFiletype(filepath: []const u8) ?[]const u8 {
    const ext_with_dot = std.fs.path.extension(filepath);
    if (ext_with_dot.len <= 1) return null;
    const ext = ext_with_dot[1..];
    return ext_map.get(ext);
}

const ext_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "bash", "sh" },
    .{ "c", "c" },
    .{ "cc", "cpp" },
    .{ "cjs", "javascript" },
    .{ "cpp", "cpp" },
    .{ "cts", "typescript" },
    .{ "cu", "cpp" },
    .{ "cuh", "cpp" },
    .{ "cxx", "cpp" },
    .{ "dart", "dart" },
    .{ "ex", "elixir" },
    .{ "exs", "elixir" },
    .{ "f", "fortran" },
    .{ "f03", "fortran" },
    .{ "f08", "fortran" },
    .{ "f90", "fortran" },
    .{ "f95", "fortran" },
    .{ "for", "fortran" },
    .{ "go", "go" },
    .{ "h", "c" },
    .{ "hh", "cpp" },
    .{ "hs", "haskell" },
    .{ "htm", "html" },
    .{ "html", "html" },
    .{ "hpp", "cpp" },
    .{ "hxx", "cpp" },
    .{ "java", "java" },
    .{ "jl", "julia" },
    .{ "js", "javascript" },
    .{ "json", "json" },
    .{ "kt", "kotlin" },
    .{ "kts", "kotlin" },
    .{ "lua", "lua" },
    .{ "mjs", "javascript" },
    .{ "mts", "typescript" },
    .{ "odin", "odin" },
    .{ "perl", "perl" },
    .{ "php", "php" },
    .{ "pl", "perl" },
    .{ "pm", "perl" },
    .{ "py", "python" },
    .{ "pyw", "python" },
    .{ "r", "r" },
    .{ "rb", "ruby" },
    .{ "rs", "rust" },
    .{ "sh", "sh" },
    .{ "swift", "swift" },
    .{ "ts", "typescript" },
    .{ "tsx", "typescript" },
    .{ "zig", "zig" },
    .{ "zsh", "zsh" },
});

fn shebangFiletypeAllocWithIO(io: std.Io, allocator: std.mem.Allocator, filepath: []const u8) !?[]u8 {
    if (filepath.len == 0) return null;

    var file = std.Io.Dir.cwd().openFile(io, filepath, .{}) catch return null;
    defer file.close(io);

    var reader_buf: [256]u8 = undefined;
    var file_reader = file.reader(io, &reader_buf);
    var buffer: [256]u8 = undefined;
    const bytes_read = file_reader.interface.readSliceShort(buffer[0..]) catch return null;
    if (bytes_read == 0) return null;

    const text = buffer[0..bytes_read];
    const line_end = std.mem.findScalar(u8, text, '\n') orelse text.len;
    const first_line = std.mem.trimEnd(u8, text[0..line_end], "\r");
    if (!std.mem.startsWith(u8, first_line, "#!")) return null;

    const rest = std.mem.trimStart(u8, first_line[2..], " \t");
    var interpreter: ?[]const u8 = null;
    if (std.mem.startsWith(u8, rest, "/usr/bin/env")) {
        const env_rest = std.mem.trimStart(u8, rest["/usr/bin/env".len..], " \t");
        if (std.mem.startsWith(u8, env_rest, "-S")) {
            interpreter = nextToken(std.mem.trimStart(u8, env_rest["-S".len..], " \t"));
        } else {
            interpreter = nextToken(env_rest);
        }
    } else {
        const executable = nextToken(rest) orelse return null;
        interpreter = std.fs.path.basename(executable);
    }

    const mapped = mapShebangInterpreter(interpreter orelse return null) orelse return null;
    return @as(?[]u8, try allocator.dupe(u8, mapped));
}

fn nextToken(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, text, " \t");
    if (trimmed.len == 0) return null;
    const end = std.mem.findAny(u8, trimmed, " \t") orelse trimmed.len;
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

test "resolveSupportedAlloc maps project manifest filenames to backend filetypes" {
    const allocator = std.testing.allocator;

    const cases = [_]struct {
        requested: []const u8,
        path: []const u8,
        expected: []const u8,
    }{
        .{ .requested = "json", .path = "/tmp/app/package.json", .expected = "javascript" },
        .{ .requested = "toml", .path = "/tmp/app/Cargo.toml", .expected = "rust" },
        .{ .requested = "toml", .path = "/tmp/app/pyproject.toml", .expected = "python" },
        .{ .requested = "cmake", .path = "/tmp/app/CMakeLists.txt", .expected = "cpp" },
        .{ .requested = "meson", .path = "/tmp/app/meson.build", .expected = "cpp" },
        .{ .requested = "xml", .path = "/tmp/app/pom.xml", .expected = "java" },
        .{ .requested = "groovy", .path = "/tmp/app/build.gradle", .expected = "java" },
        .{ .requested = "gomod", .path = "/tmp/app/go.mod", .expected = "go" },
    };

    for (cases) |case| {
        const resolved = try resolveSupportedAlloc(allocator, case.requested, case.path);
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings(case.expected, resolved);
    }
}

test "resolveSupportedAlloc maps known extensions directly" {
    const allocator = std.testing.allocator;

    const cases = [_]struct {
        path: []const u8,
        expected: []const u8,
    }{
        .{ .path = "/tmp/main.go", .expected = "go" },
        .{ .path = "/tmp/main.rs", .expected = "rust" },
        .{ .path = "/tmp/main.zig", .expected = "zig" },
        .{ .path = "/tmp/main.lua", .expected = "lua" },
        .{ .path = "/tmp/main.py", .expected = "python" },
        .{ .path = "/tmp/main.js", .expected = "javascript" },
        .{ .path = "/tmp/main.ts", .expected = "typescript" },
        .{ .path = "/tmp/main.odin", .expected = "odin" },
        .{ .path = "/tmp/main.jl", .expected = "julia" },
        .{ .path = "/tmp/main.rb", .expected = "ruby" },
    };

    for (cases) |case| {
        const resolved = try resolveSupportedAlloc(allocator, "auto", case.path);
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings(case.expected, resolved);
    }
}

test "resolveSupportedAlloc keeps aliased filetype when no extension match" {
    const allocator = std.testing.allocator;
    const resolved = try resolveSupportedAlloc(allocator, "cxx", "/tmp/example.unknown");
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings("cpp", resolved);
}

test "resolveSupportedAlloc returns requested for unknown files" {
    const allocator = std.testing.allocator;
    const resolved = try resolveSupportedAlloc(allocator, "ruby", "/tmp/example.weird");
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings("ruby", resolved);
}

test "resolveSupportedAlloc trims whitespace from requested filetype" {
    const allocator = std.testing.allocator;
    const resolved = try resolveSupportedAlloc(allocator, "  c++  ", "/tmp/example.unknown");
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings("cpp", resolved);
}

test "resolveSupportedAlloc prefers extension over filename" {
    const allocator = std.testing.allocator;
    // .py extension wins over Makefile basename lookup
    const resolved = try resolveSupportedAlloc(allocator, "auto", "/tmp/Makefile.py");
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings("python", resolved);
}

test "resolveSupportedAlloc uses filename for extensionless files" {
    const allocator = std.testing.allocator;
    const resolved = try resolveSupportedAlloc(allocator, "auto", "/tmp/Makefile");
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings("cpp", resolved);
}
