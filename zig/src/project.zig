const std = @import("std");
const build_common = @import("build/common.zig");
const build_system = @import("build/system.zig");
const bazel = @import("project/bazel.zig");
const cargo = @import("project/cargo.zig");
const cmake = @import("project/cmake.zig");
const common = @import("project/common.zig");
const gradle = @import("project/gradle.zig");
const go_mod = @import("project/go_mod.zig");
const go = @import("project/go.zig");
const go_work = @import("project/go_work.zig");
const make = @import("project/make.zig");
const maven = @import("project/maven.zig");
const meson = @import("project/meson.zig");
const package_json = @import("project/package_json.zig");
const pyproject = @import("project/pyproject.zig");

pub const Kind = enum {
    make,
    package_json,
    maven,
    gradle,
    cmake,
    bazel,
    meson,
    cargo,
    pyproject,
    go,
    go_mod,
    go_work,
    system,
};

pub const Options = struct {
    kind: Kind,
    path: []const u8,
    match_path: ?[]const u8 = null,
    package_path: []const u8 = "",
    query: ?build_system.Query = null,
    project_root: ?[]const u8 = null,
};

const ProjectDaemonRequestHeader = struct {
    request_id: u64,
};

const PROJECT_DAEMON_REQ_BEGIN = "@@ZPRJ_REQ_BEGIN";
const PROJECT_DAEMON_REQ_END = "@@ZPRJ_REQ_END";
const PROJECT_DAEMON_RES_BEGIN = "@@ZPRJ_RES_BEGIN";
const PROJECT_DAEMON_RES_END = "@@ZPRJ_RES_END";
const PROJECT_DAEMON_RES_ERR = "@@ZPRJ_RES_ERR";
const PROJECT_DAEMON_MAX_LINE = 16384;

pub fn parseArgs(args: []const []const u8) !Options {
    var kind: ?Kind = null;
    var path: ?[]const u8 = null;
    var match_path: ?[]const u8 = null;
    var package_path: []const u8 = "";
    var query: ?build_system.Query = null;
    var project_root: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--project-parse")) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "--kind=")) {
            kind = try parseKind(arg["--kind=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--path=")) {
            path = arg["--path=".len..];
        } else if (std.mem.startsWith(u8, arg, "--match-path=")) {
            match_path = arg["--match-path=".len..];
        } else if (std.mem.startsWith(u8, arg, "--package-path=")) {
            package_path = arg["--package-path=".len..];
        } else if (std.mem.startsWith(u8, arg, "--query=")) {
            query = try build_system.parseQuery(arg["--query=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--project-root=")) {
            project_root = arg["--project-root=".len..];
        } else {
            return error.InvalidProjectParseFlag;
        }
    }

    return .{
        .kind = kind orelse return error.MissingProjectParseKind,
        .path = path orelse return error.MissingProjectParsePath,
        .match_path = match_path,
        .package_path = package_path,
        .query = query,
        .project_root = project_root,
    };
}

pub fn runMode(allocator: std.mem.Allocator, options: Options) !void {
    const contents = try readProjectFile(allocator, options.kind, options.path);
    defer allocator.free(contents);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try writeOutput(stdout, allocator, options, contents);
}

pub fn runDaemon(allocator: std.mem.Allocator) !void {
    var reader = std.fs.File.stdin().deprecatedReader();
    var stdout = std.fs.File.stdout().deprecatedWriter();

    while (true) {
        const maybe_begin = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', PROJECT_DAEMON_MAX_LINE);
        if (maybe_begin == null) break;
        const begin_owned = maybe_begin.?;
        defer allocator.free(begin_owned);
        const begin_line = stripTrailingCR(begin_owned);

        if (!std.mem.startsWith(u8, begin_line, PROJECT_DAEMON_REQ_BEGIN)) {
            continue;
        }

        const header = parseProjectDaemonBegin(begin_line) catch continue;
        var request_args: std.ArrayList([]u8) = .empty;
        defer {
            for (request_args.items) |arg| allocator.free(arg);
            request_args.deinit(allocator);
        }

        var completed = false;
        while (true) {
            const maybe_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', PROJECT_DAEMON_MAX_LINE);
            if (maybe_line == null) break;
            const line_owned = maybe_line.?;
            defer allocator.free(line_owned);
            const line = stripTrailingCR(line_owned);

            if (isProjectDaemonEndLine(line, header.request_id)) {
                completed = true;
                break;
            }

            if (line.len > 0 and line[0] == '\t') {
                try request_args.append(allocator, try allocator.dupe(u8, line[1..]));
            } else if (line.len > 0) {
                try request_args.append(allocator, try allocator.dupe(u8, line));
            }
        }

        if (!completed) break;

        try stdout.print("{s} {d}\n", .{ PROJECT_DAEMON_RES_BEGIN, header.request_id });
        const options = parseArgs(request_args.items);
        if (options) |parsed| {
            const contents = readProjectFile(allocator, parsed.kind, parsed.path);
            if (contents) |payload| {
                defer allocator.free(payload);
                writeOutput(stdout, allocator, parsed, payload) catch |err| {
                    try stdout.print("{s} {d} {s}\n", .{ PROJECT_DAEMON_RES_ERR, header.request_id, @errorName(err) });
                };
            } else |err| {
                try stdout.print("{s} {d} {s}\n", .{ PROJECT_DAEMON_RES_ERR, header.request_id, @errorName(err) });
            }
        } else |err| {
            try stdout.print("{s} {d} {s}\n", .{ PROJECT_DAEMON_RES_ERR, header.request_id, @errorName(err) });
        }
        try stdout.print("{s} {d}\n", .{ PROJECT_DAEMON_RES_END, header.request_id });
    }
}

fn parseKind(value: []const u8) !Kind {
    if (std.ascii.eqlIgnoreCase(value, "make")) return .make;
    if (std.ascii.eqlIgnoreCase(value, "package-json")) return .package_json;
    if (std.ascii.eqlIgnoreCase(value, "maven")) return .maven;
    if (std.ascii.eqlIgnoreCase(value, "gradle")) return .gradle;
    if (std.ascii.eqlIgnoreCase(value, "cmake")) return .cmake;
    if (std.ascii.eqlIgnoreCase(value, "bazel")) return .bazel;
    if (std.ascii.eqlIgnoreCase(value, "meson")) return .meson;
    if (std.ascii.eqlIgnoreCase(value, "cargo")) return .cargo;
    if (std.ascii.eqlIgnoreCase(value, "pyproject")) return .pyproject;
    if (std.ascii.eqlIgnoreCase(value, "go")) return .go;
    if (std.ascii.eqlIgnoreCase(value, "go-mod")) return .go_mod;
    if (std.ascii.eqlIgnoreCase(value, "go-work")) return .go_work;
    if (std.ascii.eqlIgnoreCase(value, "system")) return .system;
    return error.InvalidProjectParseKind;
}

fn parseProjectDaemonBegin(line: []const u8) !ProjectDaemonRequestHeader {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return error.InvalidProjectDaemonHeader;
    if (!std.mem.eql(u8, marker, PROJECT_DAEMON_REQ_BEGIN)) {
        return error.InvalidProjectDaemonHeader;
    }

    const request_id = try std.fmt.parseInt(u64, it.next() orelse return error.InvalidProjectDaemonHeader, 10);
    if (it.next() != null) {
        return error.InvalidProjectDaemonHeader;
    }

    return .{ .request_id = request_id };
}

fn isProjectDaemonEndLine(line: []const u8, request_id: u64) bool {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return false;
    if (!std.mem.eql(u8, marker, PROJECT_DAEMON_REQ_END)) {
        return false;
    }

    const raw_id = it.next() orelse return false;
    if (it.next() != null) {
        return false;
    }
    const parsed = std.fmt.parseInt(u64, raw_id, 10) catch return false;
    return parsed == request_id;
}

fn stripTrailingCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

pub fn readProjectFile(allocator: std.mem.Allocator, kind: Kind, path: []const u8) ![]u8 {
    if (path.len == 0) {
        return allocator.dupe(u8, "");
    }
    if (kind == .system) {
        return allocator.dupe(u8, "");
    }
    return common.readFileAlloc(allocator, path);
}

pub fn writeOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !void {
    if (options.kind == .system) {
        const query = options.query orelse return error.MissingSystemQuery;
        const result = try build_system.detect(allocator, query, options.path, options.project_root);
        defer build_system.freeOwnedResult(allocator, result);

        if (result.root) |root| {
            try stdout.print("ROOT\t{s}\n", .{root});
        }
        if (result.system) |name| {
            try stdout.print("SYSTEM\t{s}\n", .{name});
        }
        if (result.build_ready) |ready| {
            try stdout.print("BUILD_READY\t{d}\n", .{if (ready) @as(u8, 1) else @as(u8, 0)});
        }
        return;
    }

    if (options.kind == .cmake) {
        const items = try cmake.parseTargets(allocator, contents, options.path, options.match_path);
        defer cmake.freeOwnedTargets(allocator, items);
        var primary_target: ?[]const u8 = null;
        for (items) |item| {
            if (item.matched and primary_target == null) {
                primary_target = item.name;
            }
        }
        if (primary_target == null and items.len > 0) {
            primary_target = items[0].name;
        }

        const root = std.fs.path.dirname(options.path) orelse "";
        const cmake_config_command = "cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1";
        const cmake_clean_command = if (build_common.hasCmakeBuildTree(root))
            "cmake --build build --target clean"
        else
            "cmake -E rm -rf build";
        const cmake_debug_command =
            "cmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build";
        const cmake_release_command =
            "cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build";
        const cmake_test_command = "ctest --test-dir build";
        const cmake_install_command = "cmake --build build --target install";
        try stdout.print("COMMAND\tcmake-config\t{s}\n", .{cmake_config_command});
        try stdout.print(
            "COMMAND\tcmake-clean\t{s}\n",
            .{cmake_clean_command},
        );
        try stdout.print(
            "COMMAND\tcmake-debug\t{s}\n",
            .{cmake_debug_command},
        );
        try stdout.print(
            "COMMAND\tcmake-release\t{s}\n",
            .{cmake_release_command},
        );
        try stdout.print("COMMAND\tcmake-test\t{s}\n", .{cmake_test_command});
        try stdout.print("COMMAND\tinstall\t{s}\n", .{cmake_install_command});
        try stdout.print("PREFERRED\tconfig\t{s}\n", .{cmake_config_command});
        try stdout.print("PREFERRED\tclean\t{s}\n", .{cmake_clean_command});
        try stdout.print("PREFERRED\tdebug\t{s}\n", .{cmake_debug_command});
        try stdout.print("PREFERRED\trelease\t{s}\n", .{cmake_release_command});
        try stdout.print("PREFERRED\ttest\t{s}\n", .{cmake_test_command});
        try stdout.print("PREFERRED\tinstall\t{s}\n", .{cmake_install_command});
        var primary_run_path: ?[]u8 = null;
        defer if (primary_run_path) |value| allocator.free(value);

        for (items) |item| {
            try stdout.print("TARGET\t{s}\t{d}\n", .{ item.name, if (item.matched) @as(u8, 1) else @as(u8, 0) });
            const run_path = try build_common.discoverBuildRunPathAlloc(allocator, root, item.name);
            defer if (run_path) |value| allocator.free(value);
            const build_command = try build_common.cmakeBuildCommandAlloc(allocator, root, item.name);
            defer allocator.free(build_command);
            try stdout.print("COMMAND\tcmake-build-{s}\t{s}\n", .{ item.name, build_command });

            const run_command = try build_common.cmakeRunCommandAlloc(allocator, root, item.name, run_path);
            defer allocator.free(run_command);
            try stdout.print("COMMAND\tcmake-run-{s}\t{s}\n", .{ item.name, run_command });

            if (run_path) |value| {
                try stdout.print("RUN_PATH\t{s}\t{s}\n", .{ item.name, value });
                if (primary_target != null and std.mem.eql(u8, item.name, primary_target.?) and primary_run_path == null) {
                    primary_run_path = try allocator.dupe(u8, value);
                }
            }
        }
        if (primary_target) |name| {
            const preferred_build = try build_common.cmakeBuildCommandAlloc(allocator, root, null);
            defer allocator.free(preferred_build);
            try stdout.print("COMMAND\tcmake-build\t{s}\n", .{preferred_build});
            try stdout.print("PREFERRED\tbuild\t{s}\n", .{preferred_build});

            try stdout.print("PRIMARY_TARGET\t{s}\n", .{name});
            if (primary_run_path) |value| {
                try stdout.print("PRIMARY_RUN_PATH\t{s}\n", .{value});
            }
            const preferred_run = try build_common.cmakeRunCommandAlloc(allocator, root, name, primary_run_path);
            defer allocator.free(preferred_run);
            try stdout.print("COMMAND\tcmake-run\t{s}\n", .{preferred_run});
            try stdout.print("PREFERRED\trun\t{s}\n", .{preferred_run});
        }
        return;
    }

    if (options.kind == .meson) {
        const items = try meson.parseTargets(allocator, contents, options.path, options.match_path);
        defer meson.freeOwnedTargets(allocator, items);
        var primary_target: ?[]const u8 = null;
        for (items) |item| {
            if (item.matched and primary_target == null) {
                primary_target = item.name;
            }
        }
        if (primary_target == null and items.len > 0) {
            primary_target = items[0].name;
        }

        const root = std.fs.path.dirname(options.path) orelse "";
        const meson_setup_command = "meson setup build";
        const meson_clean_command = if (build_common.hasMesonBuildTree(root))
            "meson compile -C build --clean"
        else
            "cmake -E rm -rf build";
        const meson_test_command = "meson test -C build";
        const meson_install_command = "meson install -C build";
        try stdout.print("COMMAND\tmeson-setup\t{s}\n", .{meson_setup_command});
        try stdout.print(
            "COMMAND\tmeson-clean\t{s}\n",
            .{meson_clean_command},
        );
        try stdout.print("COMMAND\tmeson-test\t{s}\n", .{meson_test_command});
        try stdout.print("COMMAND\tinstall\t{s}\n", .{meson_install_command});
        try stdout.print("PREFERRED\tsetup\t{s}\n", .{meson_setup_command});
        try stdout.print("PREFERRED\tclean\t{s}\n", .{meson_clean_command});
        try stdout.print("PREFERRED\ttest\t{s}\n", .{meson_test_command});
        try stdout.print("PREFERRED\tinstall\t{s}\n", .{meson_install_command});
        var primary_run_path: ?[]u8 = null;
        defer if (primary_run_path) |value| allocator.free(value);

        for (items) |item| {
            try stdout.print("TARGET\t{s}\t{d}\n", .{ item.name, if (item.matched) @as(u8, 1) else @as(u8, 0) });
            const run_path = try build_common.discoverBuildRunPathAlloc(allocator, root, item.name);
            defer if (run_path) |value| allocator.free(value);
            const build_command = try build_common.mesonBuildCommandAlloc(allocator, root, item.name);
            defer allocator.free(build_command);
            try stdout.print("COMMAND\tmeson-build-{s}\t{s}\n", .{ item.name, build_command });

            const run_command = try build_common.mesonRunCommandAlloc(allocator, root, item.name, run_path);
            defer allocator.free(run_command);
            try stdout.print("COMMAND\tmeson-run-{s}\t{s}\n", .{ item.name, run_command });

            if (run_path) |value| {
                try stdout.print("RUN_PATH\t{s}\t{s}\n", .{ item.name, value });
                if (primary_target != null and std.mem.eql(u8, item.name, primary_target.?) and primary_run_path == null) {
                    primary_run_path = try allocator.dupe(u8, value);
                }
            }
        }
        if (primary_target) |name| {
            const preferred_build = try build_common.mesonBuildCommandAlloc(allocator, root, null);
            defer allocator.free(preferred_build);
            try stdout.print("COMMAND\tmeson-build\t{s}\n", .{preferred_build});
            try stdout.print("PREFERRED\tbuild\t{s}\n", .{preferred_build});

            try stdout.print("PRIMARY_TARGET\t{s}\n", .{name});
            if (primary_run_path) |value| {
                try stdout.print("PRIMARY_RUN_PATH\t{s}\n", .{value});
            }
            const preferred_run = try build_common.mesonRunCommandAlloc(allocator, root, name, primary_run_path);
            defer allocator.free(preferred_run);
            try stdout.print("COMMAND\tmeson-run\t{s}\n", .{preferred_run});
            try stdout.print("PREFERRED\trun\t{s}\n", .{preferred_run});
        }
        return;
    }

    if (options.kind == .cargo) {
        const items = try cargo.parseTargets(allocator, contents, options.path, options.match_path);
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
            try stdout.print("PREFERRED\trun\tcargo run --bin {s}\n", .{quoted});
            try stdout.print("PREFERRED\trelease-run\tcargo run --release --bin {s}\n", .{quoted});
        }
        return;
    }

    if (options.kind == .go) {
        const info = try go.parseInfo(allocator, contents, options.path, options.match_path);
        defer go.freeOwnedInfo(allocator, info);

        if (info.module_name) |name| {
            try stdout.print("MODULE\t{s}\n", .{name});
        }
        if (info.primary_selector) |selector| {
            try stdout.print("PRIMARY_SELECTOR\t{s}\n", .{selector});
        }
        if (info.primary_build) |command| {
            try stdout.print("COMMAND\tgo-build-package\t{s}\n", .{command});
            try stdout.print("PRIMARY_BUILD\t{s}\n", .{command});
            try stdout.print("PREFERRED\tbuild\t{s}\n", .{command});
        }
        if (info.primary_run) |command| {
            try stdout.print("COMMAND\tgo-run-package\t{s}\n", .{command});
            try stdout.print("PRIMARY_RUN\t{s}\n", .{command});
            try stdout.print("PREFERRED\trun\t{s}\n", .{command});
        }
        if (info.primary_test) |command| {
            try stdout.print("COMMAND\tgo-test-package\t{s}\n", .{command});
            try stdout.print("PRIMARY_TEST\t{s}\n", .{command});
            try stdout.print("PREFERRED\ttest\t{s}\n", .{command});
        }
        return;
    }

    if (options.kind == .pyproject) {
        var names: std.ArrayList([]u8) = .empty;
        defer common.freeOwnedNameList(allocator, names.items);
        try pyproject.parseTools(allocator, contents, &names);
        for (names.items) |name| {
            try stdout.print("TOOL\t{s}\n", .{name});
        }
        return;
    }

    if (options.kind == .go_mod) {
        const maybe_name = try go_mod.parseModuleName(allocator, contents);
        defer if (maybe_name) |name| allocator.free(name);
        if (maybe_name) |name| {
            try stdout.print("MODULE\t{s}\n", .{name});
        }
        return;
    }

    if (options.kind == .go_work) {
        const items = try go_work.parseUses(allocator, contents, options.path, options.match_path);
        defer go_work.freeOwnedUses(allocator, items);
        for (items) |item| {
            try stdout.print("USE\t{s}\t{d}\n", .{ item.path, if (item.matched) @as(u8, 1) else @as(u8, 0) });
        }
        return;
    }

    if (options.kind == .bazel) {
        const items = try bazel.parseTargets(allocator, contents);
        defer bazel.freeOwnedTargets(allocator, items);
        const info = try bazel.buildCommandInfo(
            allocator,
            items,
            options.path,
            options.package_path,
            options.match_path,
        );
        defer bazel.freeOwnedCommandInfo(allocator, info);
        for (items) |item| {
            try stdout.print("TARGET\t{s}\t{s}\t{d}\t{d}", .{
                item.rule_name,
                item.name,
                if (item.supports_run) @as(u8, 1) else @as(u8, 0),
                if (item.supports_test) @as(u8, 1) else @as(u8, 0),
            });
            for (item.source_entries) |entry| {
                try stdout.print("\t{s}", .{entry});
            }
            try stdout.writeByte('\n');
        }
        for (info.commands) |entry| {
            try stdout.print("COMMAND\t{s}\t{s}\n", .{ entry.name, entry.command });
        }
        if (info.primary_build) |command| {
            try stdout.print("PRIMARY_BUILD\t{s}\n", .{command});
            try stdout.print("PREFERRED\tbuild\t{s}\n", .{command});
        }
        if (info.primary_run) |command| {
            try stdout.print("PRIMARY_RUN\t{s}\n", .{command});
            try stdout.print("PREFERRED\trun\t{s}\n", .{command});
        }
        if (info.primary_test) |command| {
            try stdout.print("PRIMARY_TEST\t{s}\n", .{command});
            try stdout.print("PREFERRED\ttest\t{s}\n", .{command});
        }
        return;
    }

    if (options.kind == .maven) {
        var names: std.ArrayList([]u8) = .empty;
        defer common.freeOwnedNameList(allocator, names.items);
        try maven.parseGoals(allocator, contents, &names);

        try stdout.print("COMMAND\tmvn-build\tmvn compile\n", .{});
        try stdout.print("COMMAND\tmvn-test\tmvn test\n", .{});
        try stdout.print("COMMAND\tmvn-package\tmvn package\n", .{});
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
            try stdout.print("PRIMARY_RUN\t{s}\n", .{command});
            try stdout.print("PREFERRED\trun\t{s}\n", .{command});
        }
        return;
    }

    if (options.kind == .gradle) {
        var names: std.ArrayList([]u8) = .empty;
        defer common.freeOwnedNameList(allocator, names.items);
        try gradle.parseTasks(allocator, contents, &names);

        const root = std.fs.path.dirname(options.path) orelse "";
        const wrapper_path = try std.fs.path.join(allocator, &.{ root, "gradlew" });
        defer allocator.free(wrapper_path);
        const prefix: []const u8 = if (pathExists(wrapper_path)) "./gradlew" else "gradle";

        const build_command = try std.fmt.allocPrint(allocator, "{s} build", .{prefix});
        defer allocator.free(build_command);
        const test_command = try std.fmt.allocPrint(allocator, "{s} test", .{prefix});
        defer allocator.free(test_command);
        const clean_command = try std.fmt.allocPrint(allocator, "{s} clean", .{prefix});
        defer allocator.free(clean_command);

        try stdout.print("COMMAND\tgradle-build\t{s}\n", .{build_command});
        try stdout.print("COMMAND\tgradle-test\t{s}\n", .{test_command});
        try stdout.print("COMMAND\tgradle-clean\t{s}\n", .{clean_command});
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
            try stdout.print("PRIMARY_RUN\t{s}\n", .{run_command});
            try stdout.print("PREFERRED\trun\t{s}\n", .{run_command});
        }
        return;
    }

    const names = try parseNames(allocator, options.kind, contents);
    defer common.freeOwnedNameList(allocator, names);
    for (names) |name| {
        try stdout.print("{s}\n", .{name});
    }
}

fn parseNames(allocator: std.mem.Allocator, kind: Kind, contents: []const u8) ![][]u8 {
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    switch (kind) {
        .make => try make.parseTargets(allocator, contents, &names),
        .package_json => try package_json.parseScripts(allocator, contents, &names),
        .maven => try maven.parseGoals(allocator, contents, &names),
        .gradle => try gradle.parseTasks(allocator, contents, &names),
        .cmake => return error.InvalidProjectParseKind,
        .bazel => return error.InvalidProjectParseKind,
        .meson => return error.InvalidProjectParseKind,
        .cargo => return error.InvalidProjectParseKind,
        .pyproject => return error.InvalidProjectParseKind,
        .go => return error.InvalidProjectParseKind,
        .go_mod => return error.InvalidProjectParseKind,
        .go_work => return error.InvalidProjectParseKind,
        .system => return error.InvalidProjectParseKind,
    }

    return try names.toOwnedSlice(allocator);
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

test "writeOutput emits cargo primary run metadata with quoted bin names" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try writeOutput(out.writer(allocator), allocator, .{
        .kind = .cargo,
        .path = "/tmp/rustproj/Cargo.toml",
        .match_path = "/tmp/rustproj/src/bin/demo's-tool.rs",
    },
        \\[package]
        \\name = "demo"
    );

    try std.testing.expect(std.mem.indexOf(u8, out.items, "BIN\tdemo's-tool\t1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_BIN\tdemo's-tool\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_RUN\tcargo run --bin 'demo'\"'\"'s-tool'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_RELEASE_RUN\tcargo run --release --bin 'demo'\"'\"'s-tool'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\trun\tcargo run --bin 'demo'\"'\"'s-tool'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\trelease-run\tcargo run --release --bin 'demo'\"'\"'s-tool'\n") != null);
}

test "writeOutput emits go primary command metadata" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try writeOutput(out.writer(allocator), allocator, .{
        .kind = .go,
        .path = "/tmp/goproj/go.mod",
        .match_path = "/tmp/goproj/cmd/api/main.go",
    },
        \\module example.com/demo
        \\
        \\go 1.24.0
    );

    try std.testing.expect(std.mem.indexOf(u8, out.items, "MODULE\texample.com/demo\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_SELECTOR\t./cmd/api\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_BUILD\tgo build './cmd/api'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_RUN\tgo run './cmd/api'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_TEST\tgo test './cmd/api'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tbuild\tgo build './cmd/api'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\trun\tgo run './cmd/api'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\ttest\tgo test './cmd/api'\n") != null);
}

test "writeOutput emits maven command records" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try writeOutput(out.writer(allocator), allocator, .{
        .kind = .maven,
        .path = "/tmp/mavenproj/pom.xml",
    },
        \\<project>
        \\  <build>
        \\    <plugins>
        \\      <plugin>
        \\        <artifactId>spring-boot-maven-plugin</artifactId>
        \\      </plugin>
        \\    </plugins>
        \\  </build>
        \\</project>
    );

    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tmvn-build\tmvn compile\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tmvn-test\tmvn test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tmvn-package\tmvn package\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tmvn-run\tmvn spring-boot:run\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_RUN\tmvn spring-boot:run\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tbuild\tmvn compile\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\ttest\tmvn test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\trun\tmvn spring-boot:run\n") != null);
}

test "writeOutput emits gradle command records" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "gradlew",
        .data = "",
    });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const gradle_path = try std.fs.path.join(allocator, &.{ root, "build.gradle.kts" });
    defer allocator.free(gradle_path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try writeOutput(out.writer(allocator), allocator, .{
        .kind = .gradle,
        .path = gradle_path,
    },
        \\plugins {
        \\    id("application")
        \\    id("org.springframework.boot") version "3.5.0"
        \\}
    );

    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tgradle-build\t./gradlew build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tgradle-test\t./gradlew test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tgradle-clean\t./gradlew clean\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tgradle-run\t./gradlew bootRun\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_RUN\t./gradlew bootRun\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tbuild\t./gradlew build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\ttest\t./gradlew test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\trun\t./gradlew bootRun\n") != null);
}

test "writeOutput emits cmake primary target and discovered run path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("build/bin");
    try tmp.dir.writeFile(.{
        .sub_path = "build/bin/demo-app",
        .data = "",
    });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const cmake_path = try std.fs.path.join(allocator, &.{ root, "CMakeLists.txt" });
    defer allocator.free(cmake_path);
    const match_path = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(match_path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try writeOutput(out.writer(allocator), allocator, .{
        .kind = .cmake,
        .path = cmake_path,
        .match_path = match_path,
    },
        \\project(demo-app)
        \\add_executable(${PROJECT_NAME} src/main.cpp)
    );

    try std.testing.expect(std.mem.indexOf(u8, out.items, "TARGET\tdemo-app\t1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tcmake-build-demo-app\tcmake --build build --target demo-app\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tcmake-run-demo-app\tcmake --build build --target demo-app && ./build/bin/demo-app\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "RUN_PATH\tdemo-app\t./build/bin/demo-app\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_TARGET\tdemo-app\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_RUN_PATH\t./build/bin/demo-app\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tconfig\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tclean\tcmake --build build --target clean\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tdebug\tcmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\trelease\tcmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\ttest\tctest --test-dir build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tinstall\tcmake --build build --target install\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tbuild\tcmake --build build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\trun\tcmake --build build --target demo-app && ./build/bin/demo-app\n") != null);
}

test "writeOutput emits meson preferred command aliases" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("build");
    try tmp.dir.writeFile(.{
        .sub_path = "meson.build",
        .data =
            \\project('demo', 'cpp')
            \\executable('demo-app', 'src/main.cpp')
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "build/build.ninja",
        .data = "",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "build/demo-app",
        .data = "",
    });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const meson_path = try std.fs.path.join(allocator, &.{ root, "meson.build" });
    defer allocator.free(meson_path);
    const match_path = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(match_path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try writeOutput(out.writer(allocator), allocator, .{
        .kind = .meson,
        .path = meson_path,
        .match_path = match_path,
    },
        \\project('demo', 'cpp')
        \\executable('demo-app', 'src/main.cpp')
    );

    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tsetup\tmeson setup build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tclean\tmeson compile -C build --clean\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\ttest\tmeson test -C build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tinstall\tmeson install -C build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tbuild\tmeson compile -C build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\trun\tmeson compile -C build demo-app && ./build/demo-app\n") != null);
}

test "writeOutput emits bazel commands and primary targets" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try writeOutput(out.writer(allocator), allocator, .{
        .kind = .bazel,
        .path = "/tmp/bazelzig/app/BUILD.bazel",
        .match_path = "/tmp/bazelzig/app/main.cc",
        .package_path = "app",
    },
        \\cc_binary(
        \\    name = "main",
        \\    srcs = ["main.cc"],
        \\)
        \\
        \\cc_test(
        \\    name = "main_test",
        \\    srcs = ["main_test.cc"],
        \\)
    );

    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-build-main\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-run-main\tbazel run //app:main\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-test-main_test\tbazel test //app:main_test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_BUILD\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_RUN\tbazel run //app:main\n") != null);
}
