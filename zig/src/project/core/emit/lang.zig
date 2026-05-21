const std = @import("std");
const cargo_go = @import("lang/cargo_go.zig");
const go = @import("../../go/api.zig");
const jvm = @import("lang/jvm.zig");
const tools = @import("lang/tools.zig");
const fixtures = @import("../../../test_support/fixtures.zig");
const types = @import("../types.zig");

const Options = types.Options;

pub fn writeLanguageOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return writeLanguageOutputWithIO(threaded.io(), stdout, allocator, options, contents);
}

pub fn writeLanguageOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !bool {
    switch (options.kind) {
        .cargo => {
            try cargo_go.writeCargoOutput(stdout, allocator, options.path, contents, options.match_path);
            return true;
        },
        .go => {
            try cargo_go.writeGoOutputWithIO(io, stdout, allocator, options.path, contents, options.match_path);
            return true;
        },
        .maven => {
            try jvm.writeMavenOutput(stdout, allocator, contents);
            return true;
        },
        .gradle => {
            try jvm.writeGradleOutputWithIO(io, stdout, allocator, options.path, contents);
            return true;
        },
        .make, .make_auto => {
            try tools.writeMakeOutputWithIO(io, stdout, allocator, options.path, contents);
            return true;
        },
        .package_json, .package_json_auto => {
            return try tools.writePackageJsonOutputWithIO(
                io,
                stdout,
                allocator,
                options.path,
                contents,
                options.package_manager,
                options.kind == .package_json_auto,
            );
        },
        .pyproject => {
            try tools.writePyprojectOutput(stdout, allocator, contents);
            return true;
        },
        .python_auto => {
            try tools.writePythonAutoOutput(stdout, allocator, contents);
            return true;
        },
        .go_mod => {
            const maybe_name = try go.parseModuleName(allocator, contents);
            defer if (maybe_name) |name| allocator.free(name);
            if (maybe_name) |name| {
                try stdout.print("MODULE\t{s}\n", .{name});
            }
            return true;
        },
        .go_work => {
            const items = try go.parseUses(allocator, contents, options.path, options.match_path);
            defer go.freeOwnedUses(allocator, items);
            for (items) |item| {
                try stdout.print("USE\t{s}\t{d}\n", .{ item.path, if (item.matched) @as(u8, 1) else @as(u8, 0) });
            }
            return true;
        },
        else => return false,
    }
}

test "writeLanguageOutput emits cargo primary run metadata with quoted bin names" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .cargo,
        .path = "/tmp/rustproj/Cargo.toml",
        .match_path = "/tmp/rustproj/src/bin/demo's-tool.rs",
    },
        \\[package]
        \\name = "demo"
    ));

    try std.testing.expect(std.mem.find(u8, out.written(), "BIN\tdemo's-tool\t1\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_BIN\tdemo's-tool\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_RUN\tcargo run --bin 'demo'\"'\"'s-tool'\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_RELEASE_RUN\tcargo run --release --bin 'demo'\"'\"'s-tool'\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\tcargo run --bin 'demo'\"'\"'s-tool'\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trelease-run\tcargo run --release --bin 'demo'\"'\"'s-tool'\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\trun\tcargo run --bin 'demo'\"'\"'s-tool'\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\trelease-run\tcargo run --release --bin 'demo'\"'\"'s-tool'\n") != null);
}

test "writeLanguageOutput emits make command records" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(
        &out.writer,
        allocator,
        .{
            .kind = .make,
            .path = "/tmp/Makefile",
        },
        "all:\n\t@echo ok\nclean:\n\t@rm -f out\nbench:\n\t@echo bench\n",
    ));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tall\tmake all\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tmake\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tclean\tmake clean\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbench\tmake bench\n") != null);
}

test "writeLanguageOutput derives smarter make aliases from common target names" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(
        &out.writer,
        allocator,
        .{
            .kind = .make,
            .path = "/tmp/Makefile",
        },
        "default:\n\t@echo default\nserve:\n\t@echo serve\nverify:\n\t@echo verify\nformat:\n\t@echo format\n",
    ));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tmake default\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\tmake serve\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tlive\tmake serve\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\ttest\tmake verify\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tcheck\tmake verify\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tfmt\tmake format\n") != null);
}

test "writeLanguageOutput reads included make targets and phony aliases from file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Makefile", .data =
        \\include tasks.mk
        \\.PHONY: all
        \\all:
        \\\t@echo all
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tasks.mk", .data =
        \\.PHONY: serve verify format
        \\serve:
        \\\t@echo serve
        \\verify:
        \\\t@echo verify
        \\format:
        \\\t@echo format
    });

    const makefile_path = try tmp.dir.realPathFileAlloc(std.testing.io, "Makefile", allocator);
    defer allocator.free(makefile_path);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, "Makefile", allocator, .limited(4096));
    defer allocator.free(contents);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .make,
        .path = makefile_path,
    }, contents));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tserve\tmake serve\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\tmake serve\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tlive\tmake serve\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\ttest\tmake verify\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tfmt\tmake format\n") != null);
}

test "writeLanguageOutput preserves explicit make build target" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(
        &out.writer,
        allocator,
        .{
            .kind = .make,
            .path = "/tmp/Makefile",
        },
        "build:\n\t@echo build\nbench:\n\t@echo bench\n",
    ));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tmake build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tmake\n") == null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbench\tmake bench\n") != null);
}

test "writeLanguageOutput emits package script command records with package manager" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .package_json,
        .path = "/tmp/package.json",
        .package_manager = "pnpm",
    },
        \\{ "scripts": { "dev": "vite", "build": "vite build" } }
    ));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tinstall\tpnpm install\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tdev\tpnpm run dev\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tpnpm run build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tlive\tpnpm run dev\n") != null);
}

test "writeLanguageOutput derives smarter package aliases from script names" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .package_json,
        .path = "/tmp/package.json",
        .package_manager = "npm",
    },
        \\{ "scripts": { "compile": "vite build", "serve": "vite preview", "verify": "vitest run", "format": "prettier -w ." } }
    ));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tcompile\tnpm run compile\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tnpm run compile\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tserve\tnpm run serve\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\tnpm run serve\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tlive\tnpm run serve\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\ttest\tnpm run verify\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tcheck\tnpm run verify\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tfmt\tnpm run format\n") != null);
}

test "writeLanguageOutput emits broader package aliases from real script names" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .package_json,
        .path = "/tmp/package.json",
        .package_manager = "bun",
    },
        \\{ "scripts": {
        \\  "bundle": "vite build",
        \\  "preview": "vite preview",
        \\  "spotlessApply": "prettier -w .",
        \\  "integrationTest": "playwright test",
        \\  "smokeTest": "vitest smoke"
        \\} }
    ));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trelease\tbun run bundle\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tdist\tbun run bundle\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\tbun run preview\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tlive\tbun run preview\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tfmt\tbun run spotlessApply\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\te2e\tbun run integrationTest\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tintegration-test\tbun run integrationTest\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tsmoke\tbun run smokeTest\n") != null);
}

test "writeLanguageOutput ignores missing package_json_auto contents" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .package_json_auto,
        .path = "/tmp/demo.ts",
    }, ""));

    try std.testing.expectEqualStrings("", out.written());
}

test "writeLanguageOutput emits python auto commands for uv projects" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .python_auto,
        .path = "/tmp/pyproject.toml",
    },
        \\[project]
        \\name = "demo"
        \\
        \\[tool.uv]
    ));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\tuv run -m main\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\ttest\tuv run pytest\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tinstall\tuv sync\n") != null);
}

test "writeLanguageOutput emits go primary command metadata" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .go,
        .path = "/tmp/go.mod",
        .match_path = "/tmp/cmd/api/main.go",
    },
        \\module github.com/example/demo
    ));

    try std.testing.expect(std.mem.find(u8, out.written(), "MODULE\tgithub.com/example/demo\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_SELECTOR\t./cmd/api\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_BUILD\tgo build './cmd/api'\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_RUN\tgo run './cmd/api'\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_TEST\tgo test './cmd/api'\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tgo build './cmd/api'\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\tgo run './cmd/api'\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\ttest\tgo test './cmd/api'\n") != null);
}

test "writeLanguageOutput emits maven command records" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .maven,
        .path = "/tmp/pom.xml",
    },
        \\| mvn compile
        \\| mvn test
        \\| mvn spring-boot:run
    ));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tmvn-build\tmvn compile\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tmvn-test\tmvn test\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tmvn-package\tmvn package\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tcompile\tmvn compile\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tpackage\tmvn package\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tspring-boot:run\tmvn spring-boot:run\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tmvn compile\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\ttest\tmvn test\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tmvn-run\tmvn spring-boot:run\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\tmvn spring-boot:run\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_RUN\tmvn spring-boot:run\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\tbuild\tmvn compile\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\ttest\tmvn test\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\trun\tmvn spring-boot:run\n") != null);
}

test "writeLanguageOutput derives broader maven aliases from lifecycle and plugin goals" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .maven,
        .path = "/tmp/pom.xml",
    },
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
    ));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tverify\tmvn verify\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tinstall\tmvn install\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tintegration-test\tmvn integration-test\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\te2e\tmvn integration-test\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tfmt\tmvn spotless:apply\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\tmvn exec:java\n") != null);
}

test "writeLanguageOutput emits gradle command records" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gradlew", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const gradle_path = try std.fs.path.join(allocator, &.{ root, "build.gradle.kts" });
    defer allocator.free(gradle_path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .gradle,
        .path = gradle_path,
    },
        \\plugins {
        \\    id("application")
        \\    id("org.springframework.boot") version "3.5.0"
        \\}
    ));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tgradle-build\t./gradlew build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tgradle-test\t./gradlew test\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tgradle-clean\t./gradlew clean\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tgradle-run\t./gradlew bootRun\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbootRun\t./gradlew bootRun\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\t./gradlew run\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\t./gradlew build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\ttest\t./gradlew test\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tclean\t./gradlew clean\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\t./gradlew bootRun\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_RUN\t./gradlew bootRun\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\tbuild\t./gradlew build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\ttest\t./gradlew test\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\trun\t./gradlew bootRun\n") != null);
}

test "writeLanguageOutput derives smarter gradle aliases from discovered task names" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gradlew", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const gradle_path = try std.fs.path.join(allocator, &.{ root, "build.gradle.kts" });
    defer allocator.free(gradle_path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .gradle,
        .path = gradle_path,
    },
        \\tasks.register("integrationTest")
        \\tasks.register<Test>("spotlessApply")
        \\tasks.create("bundle")
        \\tasks.named("preview")
        \\val smokeTest by tasks.registering
    ));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tintegrationTest\t./gradlew integrationTest\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tspotlessApply\t./gradlew spotlessApply\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbundle\t./gradlew bundle\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tpreview\t./gradlew preview\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\te2e\t./gradlew integrationTest\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tintegration-test\t./gradlew integrationTest\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tfmt\t./gradlew spotlessApply\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trelease\t./gradlew bundle\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tdist\t./gradlew bundle\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\t./gradlew preview\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tlive\t./gradlew preview\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tsmoke\t./gradlew smokeTest\n") != null);
}

test "writeLanguageOutput emits package script command records from fixture project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writeNodeProject(tmp.dir);

    const package_path = try tmp.dir.realPathFileAlloc(std.testing.io, "package.json", allocator);
    defer allocator.free(package_path);

    const contents = try tmp.dir.readFileAlloc(std.testing.io, "package.json", allocator, .limited(4096));
    defer allocator.free(contents);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .package_json,
        .path = package_path,
    }, contents));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tinstall\tpnpm install\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tdev\tpnpm run dev\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tpnpm run build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tlive\tpnpm run dev\n") != null);
}

test "writeLanguageOutput emits bun package script command records from fixture project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writeBunProject(tmp.dir);

    const package_path = try tmp.dir.realPathFileAlloc(std.testing.io, "package.json", allocator);
    defer allocator.free(package_path);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, "package.json", allocator, .limited(4096));
    defer allocator.free(contents);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .package_json,
        .path = package_path,
    }, contents));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tinstall\tbun install\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tdev\tbun run dev\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tbun run build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\ttest\tbun run test\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tlive\tbun run dev\n") != null);
}

test "writeLanguageOutput emits yarn package script command records from fixture project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writeYarnProject(tmp.dir);

    const package_path = try tmp.dir.realPathFileAlloc(std.testing.io, "package.json", allocator);
    defer allocator.free(package_path);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, "package.json", allocator, .limited(4096));
    defer allocator.free(contents);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .package_json,
        .path = package_path,
    }, contents));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tinstall\tyarn install\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tdev\tyarn dev\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tyarn build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\ttest\tyarn test\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tlive\tyarn dev\n") != null);
}

test "writeLanguageOutput emits cargo command records from fixture project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writeCargoProject(tmp.dir);

    const cargo_path = try tmp.dir.realPathFileAlloc(std.testing.io, "Cargo.toml", allocator);
    defer allocator.free(cargo_path);
    const match_path = try tmp.dir.realPathFileAlloc(std.testing.io, "src/bin/api.rs", allocator);
    defer allocator.free(match_path);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, "Cargo.toml", allocator, .limited(4096));
    defer allocator.free(contents);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .cargo,
        .path = cargo_path,
        .match_path = match_path,
    }, contents));

    try std.testing.expect(std.mem.find(u8, out.written(), "BIN\tapi\t1\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_BIN\tapi\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tcargo-run-api\tcargo run --bin 'api'\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\trun\tcargo run --bin 'api'\n") != null);
}

test "writeLanguageOutput emits go command records from fixture project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writeGoProject(tmp.dir);

    const go_mod_path = try tmp.dir.realPathFileAlloc(std.testing.io, "go.mod", allocator);
    defer allocator.free(go_mod_path);
    const match_path = try tmp.dir.realPathFileAlloc(std.testing.io, "cmd/api/main.go", allocator);
    defer allocator.free(match_path);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, "go.mod", allocator, .limited(4096));
    defer allocator.free(contents);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .go,
        .path = go_mod_path,
        .match_path = match_path,
    }, contents));

    try std.testing.expect(std.mem.find(u8, out.written(), "MODULE\tgithub.com/example/demo\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_SELECTOR\t./cmd/api\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tgo build './cmd/api'\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\tgo run './cmd/api'\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\ttest\tgo test './cmd/api'\n") != null);
}

test "writeLanguageOutput emits go workspace command records from fixture project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writeGoWorkspaceProject(tmp.dir);

    const go_work_path = try tmp.dir.realPathFileAlloc(std.testing.io, "go.work", allocator);
    defer allocator.free(go_work_path);
    const match_path = try tmp.dir.realPathFileAlloc(std.testing.io, "service/cmd/api/main.go", allocator);
    defer allocator.free(match_path);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, "go.work", allocator, .limited(4096));
    defer allocator.free(contents);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .go,
        .path = go_work_path,
        .match_path = match_path,
    }, contents));

    try std.testing.expect(std.mem.find(u8, out.written(), "MODULE\tgithub.com/example/workspace-service\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_SELECTOR\t./service/cmd/api\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\tgo run './service/cmd/api'\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\ttest\tgo test './service/cmd/api'\n") != null);
}

test "writeLanguageOutput emits python auto commands from fixture project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writePythonProject(tmp.dir);

    const pyproject_path = try tmp.dir.realPathFileAlloc(std.testing.io, "pyproject.toml", allocator);
    defer allocator.free(pyproject_path);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, "pyproject.toml", allocator, .limited(4096));
    defer allocator.free(contents);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .python_auto,
        .path = pyproject_path,
    }, contents));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\tuv run -m main\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\ttest\tuv run pytest\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tinstall\tuv sync\n") != null);
}

test "writeLanguageOutput emits gradle command records from fixture project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writeGradleProject(tmp.dir);

    const gradle_path = try tmp.dir.realPathFileAlloc(std.testing.io, "build.gradle.kts", allocator);
    defer allocator.free(gradle_path);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, "build.gradle.kts", allocator, .limited(4096));
    defer allocator.free(contents);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .gradle,
        .path = gradle_path,
    }, contents));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tgradle-build\t./gradlew build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tgradle-run\t./gradlew bootRun\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\trun\t./gradlew bootRun\n") != null);
}

test "writeLanguageOutput emits maven command records from fixture project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writeMavenProject(tmp.dir);

    const pom_path = try tmp.dir.realPathFileAlloc(std.testing.io, "pom.xml", allocator);
    defer allocator.free(pom_path);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, "pom.xml", allocator, .limited(4096));
    defer allocator.free(contents);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeLanguageOutput(&out.writer, allocator, .{
        .kind = .maven,
        .path = pom_path,
    }, contents));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tmvn-build\tmvn compile\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tmvn-run\tmvn spring-boot:run\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\trun\tmvn spring-boot:run\n") != null);
}
