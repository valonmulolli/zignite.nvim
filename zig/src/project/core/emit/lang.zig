const std = @import("std");
const cargo = @import("../../cargo/api.zig");
const common = @import("../common.zig");
const go = @import("../../go/api.zig");
const gradle = @import("../../gradle/api.zig");
const make = @import("../../make/api.zig");
const maven = @import("../../maven/api.zig");
const package_json = @import("../../package_json/api.zig");
const project_io = @import("../io.zig");
const pyproject = @import("../../pyproject/api.zig");
const types = @import("../types.zig");

const Options = types.Options;

pub fn writeLanguageOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !bool {
    switch (options.kind) {
        .cargo => {
            try writeCargoOutput(stdout, allocator, options.path, contents, options.match_path);
            return true;
        },
        .go => {
            try writeGoOutput(stdout, allocator, options.path, contents, options.match_path);
            return true;
        },
        .maven => {
            try writeMavenOutput(stdout, allocator, contents);
            return true;
        },
        .gradle => {
            try writeGradleOutput(stdout, allocator, options.path, contents);
            return true;
        },
        .make, .make_auto => {
            var names: std.ArrayList([]u8) = .empty;
            defer common.freeOwnedNameList(allocator, names.items);
            try make.parseTargets(allocator, contents, &names);
            for (names.items) |name| {
                try stdout.print("COMMAND\t{s}\tmake {s}\n", .{ name, name });
            }
            return true;
        },
        .package_json, .package_json_auto => {
            var names: std.ArrayList([]u8) = .empty;
            defer common.freeOwnedNameList(allocator, names.items);
            try package_json.parseScripts(allocator, contents, &names);
            const manager = options.package_manager orelse "npm";
            for (names.items) |name| {
                const command = try package_json.formatScriptCommandAlloc(allocator, manager, name);
                defer allocator.free(command);
                try stdout.print("COMMAND\t{s}\t{s}\n", .{ name, command });
            }
            return true;
        },
        .pyproject => {
            var names: std.ArrayList([]u8) = .empty;
            defer common.freeOwnedNameList(allocator, names.items);
            try pyproject.parseTools(allocator, contents, &names);
            for (names.items) |name| {
                try stdout.print("TOOL\t{s}\n", .{name});
            }
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

fn writeMavenOutput(stdout: anytype, allocator: std.mem.Allocator, contents: []const u8) !void {
    var names: std.ArrayList([]u8) = .empty;
    defer common.freeOwnedNameList(allocator, names.items);
    try maven.parseGoals(allocator, contents, &names);

    try stdout.print("COMMAND\tmvn-build\tmvn compile\n", .{});
    try stdout.print("COMMAND\tmvn-test\tmvn test\n", .{});
    try stdout.print("COMMAND\tmvn-package\tmvn package\n", .{});
    try stdout.print("COMMAND\tbuild\tmvn compile\n", .{});
    try stdout.print("COMMAND\ttest\tmvn test\n", .{});
    try stdout.print("PREFERRED\tbuild\tmvn compile\n", .{});
    try stdout.print("PREFERRED\ttest\tmvn test\n", .{});

    var run_command: ?[]const u8 = null;
    for (names.items) |name| {
        if (std.mem.eql(u8, name, "spring-boot:run")) {
            run_command = "mvn spring-boot:run";
            break;
        }
        if (run_command == null and std.mem.eql(u8, name, "exec:java")) {
            run_command = "mvn exec:java";
        }
    }

    if (run_command) |command| {
        try stdout.print("COMMAND\tmvn-run\t{s}\n", .{command});
        try stdout.print("COMMAND\trun\t{s}\n", .{command});
        try stdout.print("PRIMARY_RUN\t{s}\n", .{command});
        try stdout.print("PREFERRED\trun\t{s}\n", .{command});
    }
}

fn writeGradleOutput(stdout: anytype, allocator: std.mem.Allocator, build_file_path: []const u8, contents: []const u8) !void {
    var names: std.ArrayList([]u8) = .empty;
    defer common.freeOwnedNameList(allocator, names.items);
    try gradle.parseTasks(allocator, contents, &names);

    const root = std.fs.path.dirname(build_file_path) orelse "";
    const wrapper_path = try std.fs.path.join(allocator, &.{ root, "gradlew" });
    defer allocator.free(wrapper_path);
    const prefix: []const u8 = if (project_io.pathExists(wrapper_path)) "./gradlew" else "gradle";

    const build_command = try std.fmt.allocPrint(allocator, "{s} build", .{prefix});
    defer allocator.free(build_command);
    const test_command = try std.fmt.allocPrint(allocator, "{s} test", .{prefix});
    defer allocator.free(test_command);
    const clean_command = try std.fmt.allocPrint(allocator, "{s} clean", .{prefix});
    defer allocator.free(clean_command);

    try stdout.print("COMMAND\tgradle-build\t{s}\n", .{build_command});
    try stdout.print("COMMAND\tgradle-test\t{s}\n", .{test_command});
    try stdout.print("COMMAND\tgradle-clean\t{s}\n", .{clean_command});
    try stdout.print("COMMAND\tbuild\t{s}\n", .{build_command});
    try stdout.print("COMMAND\ttest\t{s}\n", .{test_command});
    try stdout.print("COMMAND\tclean\t{s}\n", .{clean_command});
    try stdout.print("PREFERRED\tbuild\t{s}\n", .{build_command});
    try stdout.print("PREFERRED\ttest\t{s}\n", .{test_command});

    var run_task: ?[]const u8 = null;
    for (names.items) |name| {
        if (std.mem.eql(u8, name, "bootRun")) {
            run_task = "bootRun";
            break;
        }
        if (run_task == null and std.mem.eql(u8, name, "run")) {
            run_task = "run";
        }
    }

    if (run_task) |task| {
        const run_command = try std.fmt.allocPrint(allocator, "{s} {s}", .{ prefix, task });
        defer allocator.free(run_command);
        try stdout.print("COMMAND\tgradle-run\t{s}\n", .{run_command});
        try stdout.print("COMMAND\trun\t{s}\n", .{run_command});
        try stdout.print("PRIMARY_RUN\t{s}\n", .{run_command});
        try stdout.print("PREFERRED\trun\t{s}\n", .{run_command});
    }
}

fn writeCargoOutput(stdout: anytype, allocator: std.mem.Allocator, cargo_toml_path: []const u8, contents: []const u8, match_path: ?[]const u8) !void {
    const items = try cargo.parseTargets(allocator, contents, cargo_toml_path, match_path);
    defer cargo.freeOwnedTargets(allocator, items);
    var primary_bin: ?[]const u8 = null;
    for (items) |item| {
        if (item.matched and primary_bin == null) {
            primary_bin = item.name;
        }
        try stdout.print("BIN\t{s}\t{d}\n", .{ item.name, if (item.matched) @as(u8, 1) else @as(u8, 0) });
        const quoted = try common.quoteShellArgAlloc(allocator, item.name);
        defer allocator.free(quoted);
        try stdout.print("COMMAND\tcargo-build-{s}\tcargo build --bin {s}\n", .{ item.name, quoted });
        try stdout.print("COMMAND\tcargo-run-{s}\tcargo run --bin {s}\n", .{ item.name, quoted });
        try stdout.print("COMMAND\tcargo-test-{s}\tcargo test --bin {s}\n", .{ item.name, quoted });
    }
    if (primary_bin == null and items.len > 0) {
        primary_bin = items[0].name;
    }
    if (primary_bin) |name| {
        const quoted = try common.quoteShellArgAlloc(allocator, name);
        defer allocator.free(quoted);

        try stdout.print("PRIMARY_BIN\t{s}\n", .{name});
        try stdout.print("PRIMARY_RUN\tcargo run --bin {s}\n", .{quoted});
        try stdout.print("PRIMARY_RELEASE_RUN\tcargo run --release --bin {s}\n", .{quoted});
        try stdout.print("COMMAND\trun\tcargo run --bin {s}\n", .{quoted});
        try stdout.print("COMMAND\trelease-run\tcargo run --release --bin {s}\n", .{quoted});
        try stdout.print("PREFERRED\trun\tcargo run --bin {s}\n", .{quoted});
        try stdout.print("PREFERRED\trelease-run\tcargo run --release --bin {s}\n", .{quoted});
    }
}

fn writeGoOutput(stdout: anytype, allocator: std.mem.Allocator, project_path: []const u8, contents: []const u8, match_path: ?[]const u8) !void {
    const info = try go.parseInfo(allocator, contents, project_path, match_path);
    defer go.freeOwnedInfo(allocator, info);

    if (info.module_name) |name| {
        try stdout.print("MODULE\t{s}\n", .{name});
    }
    if (info.primary_selector) |selector| {
        try stdout.print("PRIMARY_SELECTOR\t{s}\n", .{selector});
    }
    if (info.primary_build) |command| {
        try stdout.print("COMMAND\tgo-build-package\t{s}\n", .{command});
        try stdout.print("COMMAND\tbuild\t{s}\n", .{command});
        try stdout.print("PRIMARY_BUILD\t{s}\n", .{command});
        try stdout.print("PREFERRED\tbuild\t{s}\n", .{command});
    }
    if (info.primary_run) |command| {
        try stdout.print("COMMAND\tgo-run-package\t{s}\n", .{command});
        try stdout.print("COMMAND\trun\t{s}\n", .{command});
        try stdout.print("PRIMARY_RUN\t{s}\n", .{command});
        try stdout.print("PREFERRED\trun\t{s}\n", .{command});
    }
    if (info.primary_test) |command| {
        try stdout.print("COMMAND\tgo-test-package\t{s}\n", .{command});
        try stdout.print("COMMAND\ttest\t{s}\n", .{command});
        try stdout.print("PRIMARY_TEST\t{s}\n", .{command});
        try stdout.print("PREFERRED\ttest\t{s}\n", .{command});
    }
}

test "writeLanguageOutput emits cargo primary run metadata with quoted bin names" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try std.testing.expect(try writeLanguageOutput(out.writer(allocator), allocator, .{
        .kind = .cargo,
        .path = "/tmp/rustproj/Cargo.toml",
        .match_path = "/tmp/rustproj/src/bin/demo's-tool.rs",
    },
        \\[package]
        \\name = "demo"
    ));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "BIN\tdemo's-tool\t1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_BIN\tdemo's-tool\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_RUN\tcargo run --bin 'demo'\"'\"'s-tool'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_RELEASE_RUN\tcargo run --release --bin 'demo'\"'\"'s-tool'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\trun\tcargo run --bin 'demo'\"'\"'s-tool'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\trelease-run\tcargo run --release --bin 'demo'\"'\"'s-tool'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\trun\tcargo run --bin 'demo'\"'\"'s-tool'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\trelease-run\tcargo run --release --bin 'demo'\"'\"'s-tool'\n") != null);
}

test "writeLanguageOutput emits make command records" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try std.testing.expect(try writeLanguageOutput(out.writer(allocator), allocator, .{
        .kind = .make,
        .path = "/tmp/Makefile",
    },
        "all:\n\t@echo ok\nclean:\n\t@rm -f out\nbench:\n\t@echo bench\n",
    ));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tall\tmake all\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tclean\tmake clean\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbench\tmake bench\n") != null);
}

test "writeLanguageOutput emits package script command records with package manager" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try std.testing.expect(try writeLanguageOutput(out.writer(allocator), allocator, .{
        .kind = .package_json,
        .path = "/tmp/package.json",
        .package_manager = "pnpm",
    },
        \\{ "scripts": { "dev": "vite", "build": "vite build" } }
    ));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tdev\tpnpm run dev\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbuild\tpnpm run build\n") != null);
}

test "writeLanguageOutput emits go primary command metadata" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try std.testing.expect(try writeLanguageOutput(out.writer(allocator), allocator, .{
        .kind = .go,
        .path = "/tmp/go.mod",
        .match_path = "/tmp/cmd/api/main.go",
    },
        \\module github.com/example/demo
    ));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "MODULE\tgithub.com/example/demo\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_SELECTOR\t./cmd/api\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_BUILD\tgo build ./cmd/api\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_RUN\tgo run ./cmd/api\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_TEST\tgo test ./cmd/api\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbuild\tgo build ./cmd/api\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\trun\tgo run ./cmd/api\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\ttest\tgo test ./cmd/api\n") != null);
}

test "writeLanguageOutput emits maven command records" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try std.testing.expect(try writeLanguageOutput(out.writer(allocator), allocator, .{
        .kind = .maven,
        .path = "/tmp/pom.xml",
    },
        \\| mvn compile
        \\| mvn test
        \\| mvn spring-boot:run
    ));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tmvn-build\tmvn compile\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tmvn-test\tmvn test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tmvn-package\tmvn package\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbuild\tmvn compile\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\ttest\tmvn test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tmvn-run\tmvn spring-boot:run\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\trun\tmvn spring-boot:run\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_RUN\tmvn spring-boot:run\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tbuild\tmvn compile\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\ttest\tmvn test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\trun\tmvn spring-boot:run\n") != null);
}

test "writeLanguageOutput emits gradle command records" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "gradlew", .data = "" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const gradle_path = try std.fs.path.join(allocator, &.{ root, "build.gradle.kts" });
    defer allocator.free(gradle_path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try std.testing.expect(try writeLanguageOutput(out.writer(allocator), allocator, .{
        .kind = .gradle,
        .path = gradle_path,
    },
        \\plugins {
        \\    id("application")
        \\    id("org.springframework.boot") version "3.5.0"
        \\}
    ));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tgradle-build\t./gradlew build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tgradle-test\t./gradlew test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tgradle-clean\t./gradlew clean\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tgradle-run\t./gradlew bootRun\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbuild\t./gradlew build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\ttest\t./gradlew test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tclean\t./gradlew clean\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\trun\t./gradlew bootRun\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_RUN\t./gradlew bootRun\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tbuild\t./gradlew build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\ttest\t./gradlew test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\trun\t./gradlew bootRun\n") != null);
}
