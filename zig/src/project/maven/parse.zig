const std = @import("std");
const common = @import("../core/common.zig");

pub fn parseGoals(
    allocator: std.mem.Allocator,
    contents: []const u8,
    names: *std.ArrayList([]u8),
) !void {
    try common.pushUniqueName(allocator, names, "compile");
    try common.pushUniqueName(allocator, names, "test");
    try common.pushUniqueName(allocator, names, "package");
    try common.pushUniqueName(allocator, names, "verify");
    try common.pushUniqueName(allocator, names, "install");

    if (containsSpringBootRun(contents)) {
        try common.pushUniqueName(allocator, names, "spring-boot:run");
    }
    if (containsExecJava(contents)) {
        try common.pushUniqueName(allocator, names, "exec:java");
    }
    if (containsIntegrationTest(contents)) {
        try common.pushUniqueName(allocator, names, "integration-test");
    }
    if (containsSpotlessApply(contents)) {
        try common.pushUniqueName(allocator, names, "spotless:apply");
    }
}

fn containsExecJava(contents: []const u8) bool {
    return std.mem.find(u8, contents, "<artifactId>exec-maven-plugin</artifactId>") != null
        or std.mem.find(u8, contents, "<goal>java</goal>") != null;
}

fn containsSpringBootRun(contents: []const u8) bool {
    return std.mem.find(u8, contents, "<artifactId>spring-boot-maven-plugin</artifactId>") != null
        or std.mem.find(u8, contents, "spring-boot:run") != null;
}

fn containsIntegrationTest(contents: []const u8) bool {
    return std.mem.find(u8, contents, "<artifactId>maven-failsafe-plugin</artifactId>") != null
        or std.mem.find(u8, contents, "<goal>integration-test</goal>") != null
        or std.mem.find(u8, contents, "<goal>verify</goal>") != null;
}

fn containsSpotlessApply(contents: []const u8) bool {
    return std.mem.find(u8, contents, "<artifactId>spotless-maven-plugin</artifactId>") != null
        or std.mem.find(u8, contents, "spotless:apply") != null
        or std.mem.find(u8, contents, "<goal>apply</goal>") != null;
}

test "parse maven goals" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);

    try parseGoals(
        allocator,
        \\<project>
        \\  <build>
        \\    <plugins>
        \\      <plugin>
        \\        <artifactId>exec-maven-plugin</artifactId>
        \\      </plugin>
        \\      <plugin>
        \\        <artifactId>maven-failsafe-plugin</artifactId>
        \\      </plugin>
        \\      <plugin>
        \\        <artifactId>spotless-maven-plugin</artifactId>
        \\      </plugin>
        \\    </plugins>
        \\  </build>
        \\</project>
    , &names);

    try std.testing.expectEqual(@as(usize, 8), names.items.len);
    try std.testing.expectEqualStrings("compile", names.items[0]);
    try std.testing.expectEqualStrings("test", names.items[1]);
    try std.testing.expectEqualStrings("package", names.items[2]);
    try std.testing.expectEqualStrings("verify", names.items[3]);
    try std.testing.expectEqualStrings("install", names.items[4]);
    try std.testing.expectEqualStrings("exec:java", names.items[5]);
    try std.testing.expectEqualStrings("integration-test", names.items[6]);
    try std.testing.expectEqualStrings("spotless:apply", names.items[7]);
}
