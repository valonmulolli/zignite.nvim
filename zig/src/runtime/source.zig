const std = @import("std");
const scratch_max_entries = 128;

pub const InputKind = enum {
    file,
    selection,
    buffer,
};

pub const SourceRequest = struct {
    source_path: []const u8,
    filetype: []const u8,
    buffer_id: ?u32 = null,
    input_kind: InputKind = .file,
    selection_text: ?[]const u8 = null,
};

pub const PreparedSource = struct {
    execution_path: []u8,
    cleanup_command: ?[]u8 = null,

    pub fn deinit(self: *PreparedSource, allocator: std.mem.Allocator) void {
        allocator.free(self.execution_path);
        if (self.cleanup_command) |command| allocator.free(command);
    }
};

pub fn prepareSource(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    request: SourceRequest,
) !PreparedSource {
    switch (request.input_kind) {
        .file => {
            if (shouldMaterializeFileInput(request)) {
                const source_text = try readSourceFileAlloc(io, allocator, request.source_path, 4 * 1024 * 1024);
                defer allocator.free(source_text);

                return prepareInlineSourceWithKey(
                    io,
                    allocator,
                    environ_map,
                    request.source_path,
                    "",
                    request.filetype,
                    source_text,
                );
            }
            return .{
                .execution_path = try allocator.dupe(u8, request.source_path),
            };
        },
        .selection, .buffer => return prepareInlineSource(io, allocator, environ_map, request),
    }
}

fn shouldMaterializeFileInput(request: SourceRequest) bool {
    if (!std.mem.eql(u8, request.filetype, "zig")) return false;
    if (request.source_path.len == 0) return false;

    const ext = std.fs.path.extension(request.source_path);
    return !std.mem.eql(u8, ext, ".zig");
}

fn prepareInlineSource(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    request: SourceRequest,
) !PreparedSource {
    const selection_text = request.selection_text orelse return error.MissingSelectionPayload;
    if (selection_text.len == 0) return error.MissingSelectionPayload;

    const source_key = try stableSourceKeyAlloc(allocator, request.source_path, request.buffer_id);
    defer allocator.free(source_key);

    return prepareInlineSourceWithKey(
        io,
        allocator,
        environ_map,
        source_key,
        request.source_path,
        request.filetype,
        selection_text,
    );
}

fn prepareInlineSourceWithKey(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    source_key: []const u8,
    extension_source_path: []const u8,
    filetype: []const u8,
    selection_text: []const u8,
) !PreparedSource {
    const extension = resolveExtension(extension_source_path, filetype);
    const scratch_root = try scratchRootAlloc(allocator, environ_map);
    defer allocator.free(scratch_root);

    try std.Io.Dir.cwd().createDirPath(io, scratch_root);

    const scratch_path = try stableScratchPathAlloc(
        allocator,
        scratch_root,
        source_key,
        filetype,
        extension,
        selection_text,
    );
    errdefer allocator.free(scratch_path);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = scratch_path,
        .data = selection_text,
    });
    pruneScratchRootBestEffort(io, allocator, scratch_root, scratch_path, scratch_max_entries) catch {};

    return .{
        .execution_path = scratch_path,
    };
}

fn stableSourceKeyAlloc(allocator: std.mem.Allocator, source_path: []const u8, buffer_id: ?u32) ![]u8 {
    if (source_path.len > 0) return allocator.dupe(u8, source_path);
    if (buffer_id) |id| return std.fmt.allocPrint(allocator, "buffer:{d}", .{id});
    return error.MissingSelectionSourceKey;
}

fn readSourceFileAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
}

fn resolveExtension(source_path: []const u8, filetype: []const u8) []const u8 {
    const path_ext = std.fs.path.extension(source_path);
    if (path_ext.len > 1) return path_ext[1..];

    return switch (std.meta.stringToEnum(FiletypeExtension, filetype) orelse .unknown) {
        .c => "c",
        .cpp => "cpp",
        .dart => "dart",
        .elixir => "exs",
        .fortran => "f90",
        .go => "go",
        .haskell => "hs",
        .html => "html",
        .java => "java",
        .javascript => "js",
        .json => "json",
        .julia => "jl",
        .kotlin => "kt",
        .lua => "lua",
        .odin => "odin",
        .perl => "pl",
        .php => "php",
        .python => "py",
        .r => "r",
        .ruby => "rb",
        .rust => "rs",
        .sh => "sh",
        .swift => "swift",
        .typescript => "ts",
        .zig => "zig",
        .zsh => "zsh",
        .unknown => "",
    };
}

const FiletypeExtension = enum {
    c,
    cpp,
    dart,
    elixir,
    fortran,
    go,
    haskell,
    html,
    java,
    javascript,
    json,
    julia,
    kotlin,
    lua,
    odin,
    perl,
    php,
    python,
    r,
    ruby,
    rust,
    sh,
    swift,
    typescript,
    zig,
    zsh,
    unknown,
};

fn scratchRootAlloc(allocator: std.mem.Allocator, environ_map: ?*const std.process.Environ.Map) ![]u8 {
    if (try getEnvVarOwnedOrNull(allocator, environ_map, "ZIGNITE_RUN_CACHE_DIR")) |root| {
        return root;
    }
    if (try getEnvVarOwnedOrNull(allocator, environ_map, "XDG_CACHE_HOME")) |xdg_cache_home| {
        defer allocator.free(xdg_cache_home);
        return std.fs.path.join(allocator, &.{ xdg_cache_home, "zignite", "run" });
    }
    if (try getEnvVarOwnedOrNull(allocator, environ_map, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".cache", "zignite", "run" });
    }
    if (try getEnvVarOwnedOrNull(allocator, environ_map, "TMPDIR")) |tmpdir| {
        defer allocator.free(tmpdir);
        return std.fs.path.join(allocator, &.{ tmpdir, "zignite-run" });
    }
    return allocator.dupe(u8, "/tmp/zignite-run");
}

fn getEnvVarOwnedOrNull(
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    name: []const u8,
) !?[]u8 {
    const map = environ_map orelse return null;
    const value = map.get(name) orelse return null;
    return @as(?[]u8, try allocator.dupe(u8, value));
}

fn stableScratchPathAlloc(
    allocator: std.mem.Allocator,
    scratch_root: []const u8,
    source_path: []const u8,
    filetype: []const u8,
    extension: []const u8,
    selection_text: []const u8,
) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(source_path);
    hasher.update("\x00");
    hasher.update(filetype);
    hasher.update("\x00");
    hasher.update(selection_text);
    const digest = hasher.final();

    const file_name = if (extension.len > 0)
        try std.fmt.allocPrint(allocator, "{x}.{s}", .{ digest, extension })
    else
        try std.fmt.allocPrint(allocator, "{x}", .{digest});
    defer allocator.free(file_name);

    return std.fs.path.join(allocator, &.{ scratch_root, file_name });
}

fn pruneScratchRootBestEffort(
    io: std.Io,
    allocator: std.mem.Allocator,
    scratch_root: []const u8,
    current_path: []const u8,
    max_entries: usize,
) !void {
    if (max_entries == 0) return;

    const Entry = struct {
        name: []u8,
        mtime: i96,
    };

    var dir = try std.Io.Dir.cwd().openDir(io, scratch_root, .{ .iterate = true });
    defer dir.close(io);

    var items: std.ArrayList(Entry) = .empty;
    defer {
        for (items.items) |item| allocator.free(item.name);
        items.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        const owned_name = try allocator.dupe(u8, entry.name);
        items.append(allocator, .{
            .name = owned_name,
            .mtime = stat.mtime.toNanoseconds(),
        }) catch |err| {
            allocator.free(owned_name);
            return err;
        };
    }

    const current_name = std.fs.path.basename(current_path);
    while (items.items.len > max_entries) {
        var oldest_index: ?usize = null;
        var oldest_mtime: i96 = std.math.maxInt(i96);

        for (items.items, 0..) |item, index| {
            if (std.mem.eql(u8, item.name, current_name)) continue;
            if (item.mtime < oldest_mtime) {
                oldest_mtime = item.mtime;
                oldest_index = index;
            }
        }

        const victim_index = oldest_index orelse break;
        const victim = items.swapRemove(victim_index);
        dir.deleteFile(io, victim.name) catch {};
        allocator.free(victim.name);
    }
}

fn deleteFileForTest(path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
}

fn readFileForTestAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_bytes));
}

test "prepareSource duplicates file input path" {
    const allocator = std.testing.allocator;

    var prepared = try prepareSource(std.testing.io, allocator, null, .{
        .source_path = "/tmp/example/main.zig",
        .filetype = "zig",
    });
    defer prepared.deinit(allocator);

    try std.testing.expectEqualStrings("/tmp/example/main.zig", prepared.execution_path);
    try std.testing.expect(prepared.cleanup_command == null);
}

test "prepareSource requires selection payload for selection input" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.MissingSelectionPayload, prepareSource(std.testing.io, allocator, null, .{
        .source_path = "/tmp/example/main.zig",
        .filetype = "zig",
        .input_kind = .selection,
    }));
}

test "prepareSource writes stable scratch file for selection input" {
    const allocator = std.testing.allocator;

    var prepared = try prepareSource(std.testing.io, allocator, null, .{
        .source_path = "/tmp/example/main.zig",
        .filetype = "zig",
        .input_kind = .selection,
        .selection_text = "pub fn main() void {\n    return;\n}",
    });
    defer {
        deleteFileForTest(prepared.execution_path);
        prepared.deinit(allocator);
    }

    try std.testing.expect(std.mem.endsWith(u8, prepared.execution_path, ".zig"));

    const contents = try readFileForTestAlloc(allocator, prepared.execution_path, 4096);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("pub fn main() void {\n    return;\n}", contents);
}

test "prepareSource reuses selection scratch path for identical contents" {
    const allocator = std.testing.allocator;

    var first = try prepareSource(std.testing.io, allocator, null, .{
        .source_path = "/tmp/example/selection.ts",
        .filetype = "typescript",
        .input_kind = .selection,
        .selection_text = "console.log('same')\n",
    });
    defer first.deinit(allocator);

    var second = try prepareSource(std.testing.io, allocator, null, .{
        .source_path = "/tmp/example/selection.ts",
        .filetype = "typescript",
        .input_kind = .selection,
        .selection_text = "console.log('same')\n",
    });
    defer {
        deleteFileForTest(second.execution_path);
        second.deinit(allocator);
    }

    try std.testing.expectEqualStrings(first.execution_path, second.execution_path);
    try std.testing.expect(std.mem.endsWith(u8, second.execution_path, ".ts"));

    const contents = try readFileForTestAlloc(allocator, second.execution_path, 4096);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("console.log('same')\n", contents);
}

test "prepareSource uses different selection scratch paths for different contents" {
    const allocator = std.testing.allocator;

    var first = try prepareSource(std.testing.io, allocator, null, .{
        .source_path = "/tmp/example/selection.ts",
        .filetype = "typescript",
        .input_kind = .selection,
        .selection_text = "console.log('first')\n",
    });
    defer {
        deleteFileForTest(first.execution_path);
        first.deinit(allocator);
    }

    var second = try prepareSource(std.testing.io, allocator, null, .{
        .source_path = "/tmp/example/selection.ts",
        .filetype = "typescript",
        .input_kind = .selection,
        .selection_text = "console.log('second')\n",
    });
    defer {
        deleteFileForTest(second.execution_path);
        second.deinit(allocator);
    }

    try std.testing.expect(!std.mem.eql(u8, first.execution_path, second.execution_path));
    try std.testing.expect(std.mem.endsWith(u8, first.execution_path, ".ts"));
    try std.testing.expect(std.mem.endsWith(u8, second.execution_path, ".ts"));
}

test "prepareSource supports selection input without a persisted source path" {
    const allocator = std.testing.allocator;

    var prepared = try prepareSource(std.testing.io, allocator, null, .{
        .source_path = "",
        .filetype = "zig",
        .buffer_id = 77,
        .input_kind = .selection,
        .selection_text = "pub fn main() void {}\n",
    });
    defer {
        deleteFileForTest(prepared.execution_path);
        prepared.deinit(allocator);
    }

    try std.testing.expect(std.mem.endsWith(u8, prepared.execution_path, ".zig"));
}

test "prepareSource supports buffer input without a persisted source path" {
    const allocator = std.testing.allocator;

    var prepared = try prepareSource(std.testing.io, allocator, null, .{
        .source_path = "",
        .filetype = "zig",
        .buffer_id = 12,
        .input_kind = .buffer,
        .selection_text = "pub fn main() void {}\n",
    });
    defer {
        deleteFileForTest(prepared.execution_path);
        prepared.deinit(allocator);
    }

    try std.testing.expect(std.mem.endsWith(u8, prepared.execution_path, ".zig"));
}

test "prepareSource materializes zig file input with a non-zig extension" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.txt",
        .data = "pub fn main() void {}\n",
    });

    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "main.txt", allocator);
    defer allocator.free(source_path);

    var prepared = try prepareSource(std.testing.io, allocator, null, .{
        .source_path = source_path,
        .filetype = "zig",
        .input_kind = .file,
    });
    defer {
        deleteFileForTest(prepared.execution_path);
        prepared.deinit(allocator);
    }

    try std.testing.expect(!std.mem.eql(u8, source_path, prepared.execution_path));
    try std.testing.expect(std.mem.endsWith(u8, prepared.execution_path, ".zig"));

    const contents = try readFileForTestAlloc(allocator, prepared.execution_path, 4096);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("pub fn main() void {}\n", contents);
}

test "pruneScratchRootBestEffort keeps current file and bounds entry count" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);

    var current_path: ?[]u8 = null;
    defer if (current_path) |path| allocator.free(path);

    var index: usize = 0;
    while (index < 6) : (index += 1) {
        const name = try std.fmt.allocPrint(allocator, "scratch-{d}.zig", .{index});
        defer allocator.free(name);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "pub fn main() void {}\n" });
        if (index == 5) {
            current_path = try std.fs.path.join(allocator, &.{ root, name });
        }
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
    }

    try pruneScratchRootBestEffort(std.testing.io, allocator, root, current_path.?, 4);

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
    defer dir.close(std.testing.io);

    var count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next(std.testing.io)) |entry| {
        if (entry.kind == .file) count += 1;
    }

    try std.testing.expect(count <= 4);
    const contents = try dir.readFileAlloc(std.testing.io, std.fs.path.basename(current_path.?), allocator, .limited(4096));
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("pub fn main() void {}\n", contents);
}
