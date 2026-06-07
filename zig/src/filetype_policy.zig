const std = @import("std");
const build_system = @import("build/system.zig");
const project_types = @import("project/core/types.zig");

pub const Entry = struct {
    filetype: []const u8,
    detect_key: ?[]const u8 = null,
    auto_kind: ?project_types.Kind = null,
    system_query: ?build_system.Query = null,
};

const entries = [_]Entry{
    .{
        .filetype = "c",
        .detect_key = "c_cpp_make",
        .auto_kind = .c_family_auto,
        .system_query = .c_family,
    },
    .{
        .filetype = "cpp",
        .detect_key = "c_cpp_make",
        .auto_kind = .c_family_auto,
        .system_query = .c_family,
    },
    .{
        .filetype = "c++",
        .detect_key = "c_cpp_make",
        .auto_kind = .c_family_auto,
        .system_query = .c_family,
    },
    .{
        .filetype = "cxx",
        .detect_key = "c_cpp_make",
        .auto_kind = .c_family_auto,
        .system_query = .c_family,
    },
    .{
        .filetype = "h",
        .detect_key = "c_cpp_make",
        .auto_kind = .c_family_auto,
        .system_query = .c_family,
    },
    .{
        .filetype = "hpp",
        .detect_key = "c_cpp_make",
        .auto_kind = .c_family_auto,
        .system_query = .c_family,
    },
    .{
        .filetype = "objc",
        .detect_key = "c_cpp_make",
        .auto_kind = .c_family_auto,
        .system_query = .c_family,
    },
    .{
        .filetype = "objcpp",
        .detect_key = "c_cpp_make",
        .auto_kind = .c_family_auto,
        .system_query = .c_family,
    },
    .{
        .filetype = "cuda",
        .detect_key = "c_cpp_make",
        .auto_kind = .c_family_auto,
        .system_query = .c_family,
    },
    .{
        .filetype = "rust",
        .detect_key = "rust",
        .auto_kind = .cargo_auto,
    },
    .{
        .filetype = "go",
        .detect_key = "go",
        .auto_kind = .go_auto,
    },
    .{
        .filetype = "zig",
        .detect_key = "zig",
        .auto_kind = .zig_auto,
    },
    .{
        .filetype = "java",
        .detect_key = "java_kotlin_project",
        .auto_kind = .jvm_auto,
        .system_query = .jvm_root,
    },
    .{
        .filetype = "kotlin",
        .detect_key = "java_kotlin_project",
        .auto_kind = .jvm_auto,
        .system_query = .jvm_root,
    },
    .{
        .filetype = "groovy",
        .detect_key = "java_kotlin_project",
        .auto_kind = .jvm_auto,
        .system_query = .jvm_root,
    },
    .{
        .filetype = "javascript",
        .detect_key = "js_package_scripts",
        .auto_kind = .package_json_auto,
        .system_query = .node_root,
    },
    .{
        .filetype = "javascriptreact",
        .detect_key = "js_package_scripts",
        .auto_kind = .package_json_auto,
        .system_query = .node_root,
    },
    .{
        .filetype = "jsx",
        .detect_key = "js_package_scripts",
        .auto_kind = .package_json_auto,
        .system_query = .node_root,
    },
    .{
        .filetype = "typescript",
        .detect_key = "js_package_scripts",
        .auto_kind = .package_json_auto,
        .system_query = .node_root,
    },
    .{
        .filetype = "typescriptreact",
        .detect_key = "js_package_scripts",
        .auto_kind = .package_json_auto,
        .system_query = .node_root,
    },
    .{
        .filetype = "tsx",
        .detect_key = "js_package_scripts",
        .auto_kind = .package_json_auto,
        .system_query = .node_root,
    },
    .{
        .filetype = "python",
        .auto_kind = .python_auto,
        .system_query = .python_root,
    },
    .{
        .filetype = "bash",
        .auto_kind = null,
        .system_query = null,
    },
    .{
        .filetype = "bzl",
        .detect_key = "bazel_project",
        .auto_kind = .bazel_auto,
        .system_query = .bazel_root,
    },
};

pub fn find(filetype: []const u8) ?Entry {
    return entries_map.get(filetype);
}

pub fn detectKeyForFiletype(filetype: []const u8) ?[]const u8 {
    return if (find(filetype)) |entry| entry.detect_key else null;
}

pub fn autoKindForFiletype(filetype: []const u8) ?project_types.Kind {
    return if (find(filetype)) |entry| entry.auto_kind else null;
}

pub fn systemQueryForFiletype(filetype: []const u8) ?build_system.Query {
    return if (find(filetype)) |entry| entry.system_query else null;
}

const entries_map = blk: {
    var kvs: [entries.len]struct { []const u8, Entry } = undefined;
    for (entries, 0..) |entry, i| kvs[i] = .{ entry.filetype, entry };
    break :blk std.StaticStringMap(Entry).initComptime(&kvs);
};

test "find returns shared filetype policy entry" {
    const cpp = find("cpp").?;
    try std.testing.expectEqualStrings("c_cpp_make", cpp.detect_key.?);
    try std.testing.expectEqual(project_types.Kind.c_family_auto, cpp.auto_kind.?);
    try std.testing.expectEqual(build_system.Query.c_family, cpp.system_query.?);

    const zig = find("zig").?;
    try std.testing.expectEqualStrings("zig", zig.detect_key.?);
    try std.testing.expectEqual(project_types.Kind.zig_auto, zig.auto_kind.?);
    try std.testing.expect(zig.system_query == null);
}

test "helper lookups expose individual filetype policy fields" {
    try std.testing.expectEqualStrings("js_package_scripts", detectKeyForFiletype("javascript").?);
    try std.testing.expectEqual(project_types.Kind.zig_auto, autoKindForFiletype("zig").?);
    try std.testing.expectEqual(build_system.Query.python_root, systemQueryForFiletype("python").?);
    try std.testing.expect(systemQueryForFiletype("rust") == null);
}

test "helper lookups expose aliased frontend filetypes too" {
    try std.testing.expectEqual(build_system.Query.c_family, systemQueryForFiletype("cxx").?);
    try std.testing.expectEqual(build_system.Query.c_family, systemQueryForFiletype("objc").?);
    try std.testing.expectEqual(build_system.Query.c_family, systemQueryForFiletype("cuda").?);
    try std.testing.expectEqual(build_system.Query.jvm_root, systemQueryForFiletype("groovy").?);
    try std.testing.expectEqualStrings("js_package_scripts", detectKeyForFiletype("tsx").?);
    try std.testing.expectEqual(project_types.Kind.package_json_auto, autoKindForFiletype("javascriptreact").?);
}

test "find returns null for unknown filetypes" {
    try std.testing.expect(find("") == null);
    try std.testing.expect(find("nope") == null);
    try std.testing.expect(find("Ruby") == null);
}

test "detectKeyForFiletype returns null for filetypes without detect entries" {
    try std.testing.expect(detectKeyForFiletype("python") == null);
    try std.testing.expect(detectKeyForFiletype("bash") == null);
    try std.testing.expect(detectKeyForFiletype("unknown") == null);
}

test "autoKindForFiletype returns null for filetypes without auto entries" {
    try std.testing.expect(autoKindForFiletype("bash") == null);
    try std.testing.expect(autoKindForFiletype("unknown") == null);
}
