const build_system = @import("../../build/system.zig");

pub const Kind = enum {
    make,
    make_auto,
    package_json,
    package_json_auto,
    maven,
    jvm_auto,
    gradle,
    c_family_auto,
    cmake,
    cmake_auto,
    bazel,
    bazel_auto,
    bazel_workspace,
    meson,
    meson_auto,
    cargo,
    cargo_auto,
    pyproject,
    go,
    go_auto,
    go_mod,
    go_work,
    system,
};

pub const Options = struct {
    kind: Kind,
    path: []const u8,
    match_path: ?[]const u8 = null,
    package_path: []const u8 = "",
    package_manager: ?[]const u8 = null,
    query: ?build_system.Query = null,
    project_root: ?[]const u8 = null,
};
