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

    if (containsSpringBootRun(contents)) {
        try common.pushUniqueName(allocator, names, "spring-boot:run");
        return;
    }
    if (containsExecJava(contents)) {
        try common.pushUniqueName(allocator, names, "exec:java");
    }
}

fn containsExecJava(contents: []const u8) bool {
    return std.mem.indexOf(u8, contents, "<artifactId>exec-maven-plugin</artifactId>") != null
        or std.mem.indexOf(u8, contents, "<goal>java</goal>") != null;
}

fn containsSpringBootRun(contents: []const u8) bool {
    return std.mem.indexOf(u8, contents, "<artifactId>spring-boot-maven-plugin</artifactId>") != null
        or std.mem.indexOf(u8, contents, "spring-boot:run") != null;
}

test "parse maven goals" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.freeOwnedNameList(allocator, names.items);

    try parseGoals(
        allocator,
        \\<project>
        \\  <build>
        \\    <plugins>
        \\      <plugin>
        \\        <artifactId>exec-maven-plugin</artifactId>
        \\      </plugin>
        \\    </plugins>
        \\  </build>
        \\</project>
    , &names);

    try std.testing.expectEqual(@as(usize, 4), names.items.len);
    try std.testing.expectEqualStrings("compile", names.items[0]);
    try std.testing.expectEqualStrings("test", names.items[1]);
    try std.testing.expectEqualStrings("package", names.items[2]);
    try std.testing.expectEqualStrings("exec:java", names.items[3]);
}
