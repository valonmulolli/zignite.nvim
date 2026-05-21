const std = @import("std");
const ansi = @import("quickfix/ansi.zig");
const build_resolve = @import("build/resolve.zig");
const build_command = @import("build/resolve/command.zig");
const config_store = @import("config/store.zig");
const daemon = @import("daemon.zig");
const quickfix = @import("quickfix.zig");
const quickfix_tail = @import("quickfix/tail.zig");
const runtime_resolve = @import("runtime/resolve.zig");
const runtime_materialize = @import("runtime/resolve/materialize.zig");

const CaseFn = *const fn (std.mem.Allocator, *const Fixtures) anyerror!void;

const Case = struct {
    name: []const u8,
    threshold_us: ?f64 = null,
    run: CaseFn,
};

const Fixtures = struct {
    allocator: std.mem.Allocator,
    root: []u8,
    ts_path: []u8,
    py_path: []u8,
    cpp_path: []u8,
    zig_path: []u8,
    typescript_path_line: []u8,
    typescript_filetype_line: []u8,
    typescript_context_line: []u8,
    // quickfix benchmark data
    qf_large_input: []const u8,
    qf_ansi_input: []const u8,
    qf_mixed_input: []const u8,

    fn deinit(self: *Fixtures) void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        std.Io.Dir.cwd().deleteTree(threaded.io(), self.root) catch {};
        self.allocator.free(self.typescript_context_line);
        self.allocator.free(self.typescript_filetype_line);
        self.allocator.free(self.typescript_path_line);
        self.allocator.free(self.zig_path);
        self.allocator.free(self.cpp_path);
        self.allocator.free(self.py_path);
        self.allocator.free(self.ts_path);
        self.allocator.free(self.root);
        self.allocator.free(self.qf_large_input);
        self.allocator.free(self.qf_ansi_input);
        self.allocator.free(self.qf_mixed_input);
    }
};

const BenchReader = struct {
    lines: []const []const u8,
    index: usize = 0,

    pub fn readUntilDelimiterOrEofAlloc(
        self: *BenchReader,
        allocator: std.mem.Allocator,
        delimiter: u8,
        max_line: usize,
    ) !?[]u8 {
        _ = delimiter;
        if (self.index >= self.lines.len) return null;
        const line = self.lines[self.index];
        self.index += 1;
        if (line.len > max_line) return error.StreamTooLong;
        return try allocator.dupe(u8, line);
    }
};

const BenchStdout = struct {
    allocator: std.mem.Allocator,
    out: *std.Io.Writer.Allocating,

    pub fn writeAll(self: *BenchStdout, bytes: []const u8) !void {
        try self.out.writer.writeAll(bytes);
    }

    pub fn writeByte(self: *BenchStdout, byte: u8) !void {
        try self.out.writer.writeByte(byte);
    }

    pub fn print(self: *BenchStdout, comptime fmt: []const u8, args: anytype) !void {
        try self.out.writer.print(fmt, args);
    }

    pub fn flush(self: *BenchStdout) !void {
        try self.out.writer.flush();
    }
};

const Stats = struct {
    count: usize,
    total_ns: u64,
    avg_us: f64,
    min_us: f64,
    max_us: f64,
    p50_us: f64,
    p95_us: f64,
    p99_us: f64,
    stddev_us: f64,
    ops_per_sec: f64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const options = try parseOptions(
        allocator,
        try init.minimal.args.toSlice(init.arena.allocator()),
        init.environ_map,
    );

    defer config_store.reset();
    try config_store.setSyncedConfigJson(
        \\{"runners":{"typescript":"bun $file","python":"python3 -u $file"},"build_commands":{"zig":{"fetch":"zig fetch $zignite_args"},"typescript":{"lint":"npm run lint"}},"detect":{"c_cpp_make":true,"js_package_scripts":true,"java_kotlin_project":true,"bazel_project":true},"revision":1}
    , 1);

    var fixtures = try createFixtures(allocator);
    defer fixtures.deinit();

    const cases = [_]Case{
        .{ .name = "build.resolve.typescript", .threshold_us = 20_000, .run = benchBuildResolveTypescript },
        .{ .name = "build.command.zig.fetch", .threshold_us = 20_000, .run = benchBuildCommandZigFetch },
        .{ .name = "run.resolve.typescript", .threshold_us = 20_000, .run = benchRunResolveTypescript },
        .{ .name = "run.resolve.python", .threshold_us = 20_000, .run = benchRunResolvePython },
        .{ .name = "build.resolve.cpp", .threshold_us = 20_000, .run = benchBuildResolveCpp },
        .{ .name = "daemon.build.resolve.ts", .threshold_us = 25_000, .run = benchDaemonBuildResolveTypescript },
        .{ .name = "daemon.run.resolve.ts", .threshold_us = 25_000, .run = benchDaemonRunResolveTypescript },
        .{ .name = "quickfix.tail.collect", .threshold_us = 5_000, .run = benchQuickfixTailCollect },
        .{ .name = "quickfix.ansi.strip", .threshold_us = 150_000, .run = benchQuickfixAnsiStrip },
        .{ .name = "quickfix.full.pipeline", .threshold_us = 100_000, .run = benchQuickfixFullPipeline },
    };

    std.debug.print("Zignite Zig backend benchmark\n", .{});
    std.debug.print("iterations: {d}\n", .{options.iterations});
    std.debug.print("warmup: {d}\n\n", .{options.warmup});
    std.debug.print("{s:<26}  {s:>7}  {s:>7}  {s:>7}  {s:>7}  {s:>7}  {s:>7}  {s:>6}\n", .{ "case", "avg/us", "min/us", "p50/us", "p95/us", "max/us", "stddev", "ops/s" });
    std.debug.print("{s:->75}\n", .{""});

    for (cases) |case| {
        var i: usize = 0;
        while (i < options.warmup) : (i += 1) {
            try case.run(allocator, &fixtures);
        }

        const stats = try measureCase(allocator, &fixtures, case, options.iterations);
        std.debug.print(
            "{s:<26}  {d:>7.2}  {d:>7.2}  {d:>7.2}  {d:>7.2}  {d:>7.2}  {d:>7.2}  {d:>6.0}\n",
            .{
                case.name,
                stats.avg_us,
                stats.min_us,
                stats.p50_us,
                stats.p95_us,
                stats.max_us,
                stats.stddev_us,
                stats.ops_per_sec,
            },
        );

        if (options.hard_fail and case.threshold_us != null and stats.avg_us > case.threshold_us.?) {
            std.debug.print(
                "benchmark regression: {s} average {d:.2} us exceeded threshold {d:.2} us\n",
                .{ case.name, stats.avg_us, case.threshold_us.? },
            );
            return error.BenchmarkRegression;
        }
    }
}

const Options = struct {
    iterations: usize,
    warmup: usize,
    hard_fail: bool,
};

fn parseOptions(
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
    environ_map: *const std.process.Environ.Map,
) !Options {
    _ = allocator;
    var iterations: usize = 3000;
    var warmup: usize = 200;
    var hard_fail = false;

    if (args.len >= 2) {
        iterations = try std.fmt.parseInt(usize, args[1], 10);
    }
    if (args.len >= 3) {
        warmup = try std.fmt.parseInt(usize, args[2], 10);
    }
    if (environ_map.get("ZIGNITE_BENCH_HARD_FAIL")) |value| {
        hard_fail = value.len != 0 and !std.mem.eql(u8, value, "0");
    }

    return .{
        .iterations = iterations,
        .warmup = warmup,
        .hard_fail = hard_fail,
    };
}

fn createFixtures(allocator: std.mem.Allocator) !Fixtures {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/zignite-bench-{d}", .{std.Io.Clock.real.now(io).toNanoseconds()});
    errdefer allocator.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);

    const ts_dir = try joinPath(allocator, root, "web/src");
    defer allocator.free(ts_dir);
    try std.Io.Dir.cwd().createDirPath(io, ts_dir);
    const ts_path = try joinPath(allocator, root, "web/src/main.ts");
    errdefer allocator.free(ts_path);
    try writeFile(ts_path,
        \\console.log("hello");
        \\
    );
    const package_json = try joinPath(allocator, root, "web/package.json");
    defer allocator.free(package_json);
    try writeFile(package_json,
        \\{
        \\  "scripts": {
        \\    "dev": "vite",
        \\    "build": "vite build",
        \\    "test": "vitest"
        \\  }
        \\}
        \\
    );

    const py_dir = try joinPath(allocator, root, "py");
    defer allocator.free(py_dir);
    try std.Io.Dir.cwd().createDirPath(io, py_dir);
    const py_path = try joinPath(allocator, root, "py/main.py");
    errdefer allocator.free(py_path);
    try writeFile(py_path,
        \\print("hello")
        \\
    );
    const pyproject = try joinPath(allocator, root, "py/pyproject.toml");
    defer allocator.free(pyproject);
    try writeFile(pyproject,
        \\[project]
        \\name = "bench"
        \\version = "0.1.0"
        \\
        \\[tool.uv]
        \\
    );

    const cpp_dir = try joinPath(allocator, root, "cpp");
    defer allocator.free(cpp_dir);
    try std.Io.Dir.cwd().createDirPath(io, cpp_dir);
    const cpp_path = try joinPath(allocator, root, "cpp/main.cpp");
    errdefer allocator.free(cpp_path);
    try writeFile(cpp_path,
        \\int main() { return 0; }
        \\
    );
    const cmake_lists = try joinPath(allocator, root, "cpp/CMakeLists.txt");
    defer allocator.free(cmake_lists);
    try writeFile(cmake_lists,
        \\cmake_minimum_required(VERSION 3.20)
        \\project(bench)
        \\add_executable(app main.cpp)
        \\
    );

    const zig_dir = try joinPath(allocator, root, "zigproj");
    defer allocator.free(zig_dir);
    try std.Io.Dir.cwd().createDirPath(io, zig_dir);
    const zig_path = try joinPath(allocator, root, "zigproj/build.zig");
    errdefer allocator.free(zig_path);
    try writeFile(zig_path,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void { _ = b; }
        \\
    );

    const typescript_path_line = try std.fmt.allocPrint(allocator, "\t--path={s}", .{ts_path});
    errdefer allocator.free(typescript_path_line);
    const typescript_filetype_line = try allocator.dupe(u8, "\t--filetype=typescript");
    errdefer allocator.free(typescript_filetype_line);
    const typescript_context_line = try std.fmt.allocPrint(allocator, "\t--context-path={s}", .{ts_path});
    errdefer allocator.free(typescript_context_line);

    var qf_large: std.ArrayList(u8) = .empty;
    errdefer qf_large.deinit(allocator);
    {
        var i: usize = 0;
        while (i < 3000) : (i += 1) {
            const line = try std.fmt.allocPrint(allocator, "src/path/file_{d}.ts:{d}:{d}: error TS2345: Type 'X' is not assignable\n", .{ i % 50 + 1, i % 200 + 1, i % 80 + 1 });
            defer allocator.free(line);
            try qf_large.appendSlice(allocator, line);
        }
    }

    var qf_ansi: std.ArrayList(u8) = .empty;
    errdefer qf_ansi.deinit(allocator);
    {
        var i: usize = 0;
        while (i < 1000) : (i += 1) {
            const line = try std.fmt.allocPrint(allocator,
                "\x1b[31merror\x1b[0m \x1b[1msrc/file_{d}.ts\x1b[0m:\x1b[33m{d}\x1b[0m:\x1b[33m{d}\x1b[0m - \x1b[1mTS2345\x1b[0m: \x1b[39mtype\x1b[0m\n",
                .{ i % 50 + 1, i % 200 + 1, i % 80 + 1 },
            );
            defer allocator.free(line);
            try qf_ansi.appendSlice(allocator, line);
        }
    }

    var qf_mixed: std.ArrayList(u8) = .empty;
    errdefer qf_mixed.deinit(allocator);
    {
        var i: usize = 0;
        while (i < 2000) : (i += 1) {
            const line = if (i % 3 == 0)
                try std.fmt.allocPrint(allocator, "\x1b[31merror\x1b[0m \x1b[1msrc/file.ts\x1b[0m(\x1b[33m{d}\x1b[0m,\x1b[33m{d}\x1b[0m): \x1b[1mTS2345\x1b[0m\n", .{ i % 200 + 1, i % 80 + 1 })
            else if (i % 3 == 1)
                try std.fmt.allocPrint(allocator, "\x1b[33mwarning\x1b[0m: unused variable 'x_{d}'\n", .{i})
            else
                try std.fmt.allocPrint(allocator, "src/other.ts:{d}:{d}: note: see here\n", .{ i % 200 + 1, i % 80 + 1 });
            defer allocator.free(line);
            try qf_mixed.appendSlice(allocator, line);
        }
    }

    return .{
        .allocator = allocator,
        .root = root,
        .ts_path = ts_path,
        .py_path = py_path,
        .cpp_path = cpp_path,
        .zig_path = zig_path,
        .typescript_path_line = typescript_path_line,
        .typescript_filetype_line = typescript_filetype_line,
        .typescript_context_line = typescript_context_line,
        .qf_large_input = try qf_large.toOwnedSlice(allocator),
        .qf_ansi_input = try qf_ansi.toOwnedSlice(allocator),
        .qf_mixed_input = try qf_mixed.toOwnedSlice(allocator),
    };
}

fn joinPath(allocator: std.mem.Allocator, left: []const u8, right: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ left, right });
}

fn writeFile(path: []const u8, contents: []const u8) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    try std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = path, .data = contents });
}

fn measureCase(
    allocator: std.mem.Allocator,
    fixtures: *const Fixtures,
    case: Case,
    iterations: usize,
) !Stats {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var timings: std.ArrayListUnmanaged(u64) = .empty;
    try timings.ensureTotalCapacity(allocator, iterations);
    defer timings.deinit(allocator);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const t0 = std.Io.Timestamp.now(io, .awake);
        try case.run(allocator, fixtures);
        const ns: u64 = @intCast(t0.untilNow(io, .awake).toNanoseconds());
        timings.appendAssumeCapacity(ns);
    }

    std.mem.sortUnstable(u64, timings.items, {}, comptime std.sort.asc(u64));

    const sorted = timings.items;
    const count = sorted.len;
    var total_ns: u64 = 0;
    for (sorted) |t| total_ns += t;

    const avg_ns = total_ns / @as(u64, @intCast(count));
    const avg_us = @as(f64, @floatFromInt(avg_ns)) / 1000.0;
    const min_us = @as(f64, @floatFromInt(sorted[0])) / 1000.0;
    const max_us = @as(f64, @floatFromInt(sorted[count - 1])) / 1000.0;
    const p50_us = @as(f64, @floatFromInt(sorted[count / 2])) / 1000.0;
    const p95_us = @as(f64, @floatFromInt(sorted[@intCast(@as(u64, @intCast(count)) * 95 / 100)])) / 1000.0;
    const p99_us = @as(f64, @floatFromInt(sorted[@intCast(@as(u64, @intCast(count)) * 99 / 100)])) / 1000.0;

    var variance_sum: u128 = 0;
    for (sorted) |t| {
        const diff = if (t > avg_ns) t - avg_ns else avg_ns - t;
        variance_sum += @as(u128, @intCast(diff)) * @as(u128, @intCast(diff));
    }
    const stddev_us = @sqrt(@as(f64, @floatFromInt(variance_sum)) / @as(f64, @floatFromInt(count))) / 1000.0;

    const ops_per_sec = @as(f64, @floatFromInt(count)) / (@as(f64, @floatFromInt(total_ns)) / 1_000_000_000.0);

    return Stats{
        .count = count,
        .total_ns = total_ns,
        .avg_us = avg_us,
        .min_us = min_us,
        .max_us = max_us,
        .p50_us = p50_us,
        .p95_us = p95_us,
        .p99_us = p99_us,
        .stddev_us = stddev_us,
        .ops_per_sec = ops_per_sec,
    };
}

fn benchBuildResolveTypescript(allocator: std.mem.Allocator, fixtures: *const Fixtures) !void {
    var resolved = try build_resolve.resolveOutput(allocator, .{
        .path = fixtures.ts_path,
        .filetype = "typescript",
    });
    defer resolved.deinit(allocator);
    if (build_resolve.findCommand(resolved.commands.items, "build") == null) {
        return error.MissingBenchmarkCommand;
    }
}

fn benchBuildCommandZigFetch(allocator: std.mem.Allocator, fixtures: *const Fixtures) !void {
    var resolved = try build_resolve.resolveOutput(allocator, .{
        .path = fixtures.zig_path,
        .filetype = "zig",
    });
    defer resolved.deinit(allocator);

    const template = build_resolve.findCommand(resolved.commands.items, "fetch") orelse return error.MissingBenchmarkCommand;
    const command = try build_command.resolveCommandTemplate(allocator, "zig", "fetch", template, "owner/repo");
    defer allocator.free(command);

    var argv = try runtime_materialize.tokenizeCommand(allocator, command);
    defer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }
    if (argv.items.len == 0) return error.MissingBenchmarkArgv;
}

fn benchRunResolveTypescript(allocator: std.mem.Allocator, fixtures: *const Fixtures) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var resolved = try runtime_resolve.resolveRunner(threaded.io(), allocator, null, .{
        .path = fixtures.ts_path,
        .filetype = "typescript",
        .context_path = fixtures.ts_path,
    });
    defer resolved.deinit(allocator);
    if (resolved.command == null or resolved.argv.items.len == 0) return error.MissingBenchmarkRunner;
}

fn benchRunResolvePython(allocator: std.mem.Allocator, fixtures: *const Fixtures) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var resolved = try runtime_resolve.resolveRunner(threaded.io(), allocator, null, .{
        .path = fixtures.py_path,
        .filetype = "python",
        .context_path = fixtures.py_path,
    });
    defer resolved.deinit(allocator);
    if (resolved.command == null or resolved.argv.items.len == 0) return error.MissingBenchmarkRunner;
}

fn benchBuildResolveCpp(allocator: std.mem.Allocator, fixtures: *const Fixtures) !void {
    var resolved = try build_resolve.resolveOutput(allocator, .{
        .path = fixtures.cpp_path,
        .filetype = "cpp",
    });
    defer resolved.deinit(allocator);
    if (build_resolve.findCommand(resolved.commands.items, "build") == null) {
        return error.MissingBenchmarkCommand;
    }
}

fn benchDaemonBuildResolveTypescript(allocator: std.mem.Allocator, fixtures: *const Fixtures) !void {
    var reader = BenchReader{
        .lines = &.{
            "@@ZBR_REQ_BEGIN 1",
            "\t--build-resolve",
            fixtures.typescript_path_line,
            fixtures.typescript_filetype_line,
            "@@ZBR_REQ_END 1",
        },
    };

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var stdout = BenchStdout{ .allocator = allocator, .out = &out };
    var threaded: std.Io.Threaded = .init_single_threaded;

    try daemon.runWithIO(allocator, threaded.io(), null, &reader, &stdout);

    if (std.mem.find(u8, out.written(), "@@ZBR_RES_BEGIN 1\n") == null) {
        return error.MissingBenchmarkFrame;
    }
    if (std.mem.find(u8, out.written(), "COMMAND\tbuild\t") == null) {
        return error.MissingBenchmarkCommand;
    }
}

fn benchDaemonRunResolveTypescript(allocator: std.mem.Allocator, fixtures: *const Fixtures) !void {
    var reader = BenchReader{
        .lines = &.{
            "@@ZRUN_REQ_BEGIN 1",
            "\t--run-resolve",
            fixtures.typescript_path_line,
            fixtures.typescript_filetype_line,
            fixtures.typescript_context_line,
            "@@ZRUN_REQ_END 1",
        },
    };

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var stdout = BenchStdout{ .allocator = allocator, .out = &out };
    var threaded: std.Io.Threaded = .init_single_threaded;

    try daemon.runWithIO(allocator, threaded.io(), null, &reader, &stdout);

    if (std.mem.find(u8, out.written(), "@@ZRUN_RES_BEGIN 1\n") == null) {
        return error.MissingBenchmarkFrame;
    }
    if (std.mem.find(u8, out.written(), "COMMAND\tbun ") == null) {
        return error.MissingBenchmarkRunner;
    }
    if (std.mem.find(u8, out.written(), "ARGV\tbun\n") == null) {
        return error.MissingBenchmarkArgv;
    }
}

fn benchQuickfixTailCollect(allocator: std.mem.Allocator, fixtures: *const Fixtures) !void {
    var t = try quickfix_tail.collectTailLineViews(allocator, fixtures.qf_large_input, 65_536);
    defer t.deinit(allocator);
    _ = t.items.len;
}

fn benchQuickfixAnsiStrip(allocator: std.mem.Allocator, fixtures: *const Fixtures) !void {
    var t = try quickfix_tail.collectTailLineViews(allocator, fixtures.qf_ansi_input, 262_144);
    defer t.deinit(allocator);
    for (t.items) |line| {
        const stripped = try ansi.stripAnsiAlloc(allocator, line);
        allocator.free(stripped);
    }
}

fn benchQuickfixFullPipeline(allocator: std.mem.Allocator, fixtures: *const Fixtures) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try quickfix.processQuickfixPayload(allocator, fixtures.qf_mixed_input, .{
        .max_lines = 500,
        .max_bytes = 131_072,
        .strip_ansi = true,
        .strip_max_lines = 400,
        .parse_diagnostics = true,
    }, false, &out.writer);
}
