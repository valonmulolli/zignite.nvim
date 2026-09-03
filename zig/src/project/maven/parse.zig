const std = @import("std");
const common = @import("../core/common.zig");

pub fn parseGoals(
    allocator: std.mem.Allocator,
    contents: []const u8,
    names: *std.ArrayList([]u8),
) !void {
    const source = try sanitizeXmlAlloc(allocator, contents);
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

fn sanitizeXmlAlloc(allocator: std.mem.Allocator, contents: []const u8) ![]u8 {
    const source = try allocator.alloc(u8, contents.len);
    errdefer allocator.free(source);

    var input_index: usize = 0;
    var output_index: usize = 0;
    var comment = false;
    var cdata = false;

    while (input_index < contents.len) {
        if (!comment and !cdata and input_index + 3 < contents.len and
            std.mem.eql(u8, contents[input_index .. input_index + 4], "<!--"))
        {
            @memset(source[output_index .. output_index + 4], ' ');
            output_index += 4;
            input_index += 4;
            comment = true;
            continue;
        }

        if (!comment and !cdata and input_index + "<![CDATA[".len <= contents.len and
            std.mem.eql(u8, contents[input_index .. input_index + "<![CDATA[".len], "<![CDATA["))
        {
            @memset(source[output_index .. output_index + "<![CDATA[".len], ' ');
            output_index += "<![CDATA[".len;
            input_index += "<![CDATA[".len;
            cdata = true;
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

        if (cdata) {
            if (input_index + 2 < contents.len and
                std.mem.eql(u8, contents[input_index .. input_index + 3], "]]>"))
            {
                @memset(source[output_index .. output_index + 3], ' ');
                output_index += 3;
                input_index += 3;
                cdata = false;
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
    return containsPluginArtifact(contents, "exec-maven-plugin");
}

fn containsSpringBootRun(contents: []const u8) bool {
    return containsPluginArtifact(contents, "spring-boot-maven-plugin");
}

fn containsIntegrationTest(contents: []const u8) bool {
    return containsPluginArtifact(contents, "maven-failsafe-plugin");
}

fn containsSpotlessApply(contents: []const u8) bool {
    return containsPluginArtifact(contents, "spotless-maven-plugin");
}

const PluginBlock = struct {
    contents: []const u8,
    next_index: usize,
};

fn containsPluginArtifact(contents: []const u8, artifact_id: []const u8) bool {
    var search_index: usize = 0;
    while (findPluginBlock(contents, search_index)) |plugin| {
        if (containsArtifactId(plugin.contents, artifact_id)) return true;
        search_index = plugin.next_index;
    }
    return false;
}

fn findPluginBlock(contents: []const u8, start_index: usize) ?PluginBlock {
    var search_index = start_index;
    while (std.mem.find(u8, contents[search_index..], "<plugin")) |relative_index| {
        const open_index = search_index + relative_index;
        const name_end = open_index + "<plugin".len;
        if (name_end < contents.len and
            (contents[name_end] == '>' or isXmlSpace(contents[name_end])))
        {
            const open_end = std.mem.findScalar(u8, contents[name_end..], '>') orelse return null;
            const body_start = name_end + open_end + 1;
            const close_relative = std.mem.find(u8, contents[body_start..], "</plugin>") orelse return null;
            const close_index = body_start + close_relative;
            return .{
                .contents = contents[body_start..close_index],
                .next_index = close_index + "</plugin>".len,
            };
        }
        search_index = name_end;
    }
    return null;
}

fn containsArtifactId(contents: []const u8, expected: []const u8) bool {
    var search_index: usize = 0;
    while (std.mem.find(u8, contents[search_index..], "<artifactId")) |relative_index| {
        const open_index = search_index + relative_index;
        const name_end = open_index + "<artifactId".len;
        if (name_end < contents.len and
            (contents[name_end] == '>' or isXmlSpace(contents[name_end])))
        {
            const open_end = std.mem.findScalar(u8, contents[name_end..], '>') orelse return false;
            const value_start = name_end + open_end + 1;
            const close_relative = std.mem.find(u8, contents[value_start..], "</artifactId>") orelse return false;
            const value_end = value_start + close_relative;
            if (std.mem.eql(u8, std.mem.trim(u8, contents[value_start..value_end], " \t\r\n"), expected)) return true;
            search_index = value_end + "</artifactId>".len;
        } else {
            search_index = name_end;
        }
    }
    return false;
}

fn isXmlSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
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

test "parse maven goals ignores markers outside plugin blocks" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);

    try parseGoals(allocator,
        \\<project>
        \\  <description>spring-boot:run and &lt;goal&gt;apply&lt;/goal&gt;</description>
        \\  <properties><![CDATA[<plugin><artifactId>spring-boot-maven-plugin</artifactId></plugin>]]></properties>
        \\  <build>
        \\    <plugins>
        \\      <plugin>
        \\        <artifactId>maven-compiler-plugin</artifactId>
        \\        <executions><execution><goals><goal>java</goal><goal>verify</goal><goal>apply</goal></goals></execution></executions>
        \\      </plugin>
        \\    </plugins>
        \\  </build>
        \\</project>
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
