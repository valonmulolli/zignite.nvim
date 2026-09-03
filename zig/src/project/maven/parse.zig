const std = @import("std");
const common = @import("../core/common.zig");

pub fn parseGoals(
    allocator: std.mem.Allocator,
    contents: []const u8,
    names: *std.ArrayList([]u8),
) !void {
    const source = try stripXmlCommentsAlloc(allocator, contents);
    defer allocator.free(source);

    try common.pushUniqueName(allocator, names, "compile");
    try common.pushUniqueName(allocator, names, "test");
    try common.pushUniqueName(allocator, names, "package");
    try common.pushUniqueName(allocator, names, "verify");
    try common.pushUniqueName(allocator, names, "install");

    if (containsSpringBootRun(source)) {
        try common.pushUniqueName(allocator, names, "spring-boot:run");
    }
    if (containsExecJava(source)) {
        try common.pushUniqueName(allocator, names, "exec:java");
    }
    if (containsIntegrationTest(source)) {
        try common.pushUniqueName(allocator, names, "integration-test");
    }
    if (containsSpotlessApply(source)) {
        try common.pushUniqueName(allocator, names, "spotless:apply");
    }
}

fn stripXmlCommentsAlloc(allocator: std.mem.Allocator, contents: []const u8) ![]u8 {
    const source = try allocator.alloc(u8, contents.len);
    errdefer allocator.free(source);

    var input_index: usize = 0;
    var output_index: usize = 0;
    var comment = false;

    while (input_index < contents.len) {
        if (!comment and input_index + 3 < contents.len and
            std.mem.eql(u8, contents[input_index .. input_index + 4], "<!--"))
        {
            @memset(source[output_index .. output_index + 4], ' ');
            output_index += 4;
            input_index += 4;
            comment = true;
            continue;
        }

        if (comment) {
            if (input_index + 2 < contents.len and
                std.mem.eql(u8, contents[input_index .. input_index + 3], "-->"))
            {
                @memset(source[output_index .. output_index + 3], ' ');
                output_index += 3;
                input_index += 3;
                comment = false;
            } else {
                source[output_index] = if (contents[input_index] == '\n') '\n' else ' ';
                output_index += 1;
                input_index += 1;
            }
            continue;
        }

        source[output_index] = contents[input_index];
        output_index += 1;
        input_index += 1;
    }

    return source;
}

fn containsExecJava(contents: []const u8) bool {
    return std.mem.find(u8, contents, "<artifactId>exec-maven-plugin</artifactId>") != null or std.mem.find(u8, contents, "<goal>java</goal>") != null;
}

fn containsSpringBootRun(contents: []const u8) bool {
    return std.mem.find(u8, contents, "<artifactId>spring-boot-maven-plugin</artifactId>") != null or std.mem.find(u8, contents, "spring-boot:run") != null;
}

fn containsIntegrationTest(contents: []const u8) bool {
    return std.mem.find(u8, contents, "<artifactId>maven-failsafe-plugin</artifactId>") != null or std.mem.find(u8, contents, "<goal>integration-test</goal>") != null or std.mem.find(u8, contents, "<goal>verify</goal>") != null;
}

fn containsSpotlessApply(contents: []const u8) bool {
    return std.mem.find(u8, contents, "<artifactId>spotless-maven-plugin</artifactId>") != null or std.mem.find(u8, contents, "spotless:apply") != null or std.mem.find(u8, contents, "<goal>apply</goal>") != null;
}

test "parse maven goals" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);

    try parseGoals(allocator,
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

test "parse maven goals ignores XML comments" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);

    try parseGoals(allocator,
        \\<!--
        \\  <artifactId>spring-boot-maven-plugin</artifactId>
        \\  <artifactId>exec-maven-plugin</artifactId>
        \\  <artifactId>maven-failsafe-plugin</artifactId>
        \\  <artifactId>spotless-maven-plugin</artifactId>
        \\  <goal>java</goal>
        \\  <goal>integration-test</goal>
        \\  <goal>apply</goal>
        \\  spring-boot:run
        \\-->
        \\<project><description>real pom</description></project>
    , &names);

    try std.testing.expectEqual(@as(usize, 5), names.items.len);
    try std.testing.expect(!containsName(names.items, "spring-boot:run"));
    try std.testing.expect(!containsName(names.items, "exec:java"));
    try std.testing.expect(!containsName(names.items, "integration-test"));
    try std.testing.expect(!containsName(names.items, "spotless:apply"));
}

fn containsName(names: []const []u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}
