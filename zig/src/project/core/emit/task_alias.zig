const std = @import("std");

pub const canonical_aliases = [_][]const u8{
    "build",
    "run",
    "live",
    "test",
    "clean",
    "release",
    "check",
    "fmt",
    "lint",
    "bench",
    "package",
    "dist",
    "bundle",
    "e2e",
    "smoke",
    "integration-test",
};

pub fn findSourceName(names: []const []u8, alias: []const u8) ?[]const u8 {
    if (containsName(names, alias)) return alias;

    const candidates = aliasCandidates(alias) orelse return null;
    for (candidates) |candidate| {
        if (containsName(names, candidate)) return candidate;
    }
    return null;
}

pub fn containsName(names: []const []u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

fn aliasCandidates(alias: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, alias, "build")) return &.{ "all", "default", "compile", "assemble", "package", "dist", "bundle" };
    if (std.mem.eql(u8, alias, "run")) return &.{ "start", "serve", "preview", "bootRun", "spring-boot:run", "exec:java" };
    if (std.mem.eql(u8, alias, "live")) return &.{ "dev", "watch", "serve", "preview", "dev:watch", "dev:server", "start:dev", "serve:dev" };
    if (std.mem.eql(u8, alias, "test")) return &.{ "verify", "check", "integrationTest", "integration-test", "unitTest", "unit-test", "e2e", "smoke", "smokeTest", "smoke-test" };
    if (std.mem.eql(u8, alias, "clean")) return &.{ "distclean", "mrproper" };
    if (std.mem.eql(u8, alias, "release")) return &.{ "package", "assemble", "dist", "bundle" };
    if (std.mem.eql(u8, alias, "check")) return &.{ "verify", "validate" };
    if (std.mem.eql(u8, alias, "fmt")) return &.{ "format", "spotlessApply", "spotless:apply" };
    if (std.mem.eql(u8, alias, "lint")) return &.{ "eslint", "checkstyle", "checkstyle:check", "detekt", "ktlintCheck" };
    if (std.mem.eql(u8, alias, "bench")) return &.{ "benchmark", "perf", "performance" };
    if (std.mem.eql(u8, alias, "package")) return &.{ "assemble", "dist", "bundle" };
    if (std.mem.eql(u8, alias, "dist")) return &.{ "bundle", "package" };
    if (std.mem.eql(u8, alias, "bundle")) return &.{ "dist", "package" };
    if (std.mem.eql(u8, alias, "e2e")) return &.{ "integrationTest", "integration-test", "smoke", "smokeTest", "smoke-test" };
    if (std.mem.eql(u8, alias, "smoke")) return &.{ "smokeTest", "smoke-test", "integrationTest", "integration-test" };
    if (std.mem.eql(u8, alias, "integration-test")) return &.{ "integrationTest", "e2e" };
    return null;
}

test "findSourceName resolves canonical aliases conservatively" {
    const names = [_][]u8{
        @constCast("all"),
        @constCast("serve"),
        @constCast("verify"),
        @constCast("format"),
        @constCast("benchmark"),
        @constCast("bundle"),
        @constCast("preview"),
        @constCast("spotlessApply"),
        @constCast("spotless:apply"),
        @constCast("smokeTest"),
    };

    try std.testing.expectEqualStrings("all", findSourceName(&names, "build").?);
    try std.testing.expectEqualStrings("serve", findSourceName(&names, "run").?);
    try std.testing.expectEqualStrings("serve", findSourceName(&names, "live").?);
    try std.testing.expectEqualStrings("verify", findSourceName(&names, "test").?);
    try std.testing.expectEqualStrings("verify", findSourceName(&names, "check").?);
    try std.testing.expectEqualStrings("format", findSourceName(&names, "fmt").?);
    try std.testing.expectEqualStrings("benchmark", findSourceName(&names, "bench").?);
    try std.testing.expectEqualStrings("bundle", findSourceName(&names, "release").?);
    try std.testing.expectEqualStrings("bundle", findSourceName(&names, "dist").?);
    try std.testing.expectEqualStrings("smokeTest", findSourceName(&names, "e2e").?);
    try std.testing.expect(findSourceName(&names, "lint") == null);
}
