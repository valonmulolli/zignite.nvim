const std = @import("std");

const cmake_cmakelists = @embedFile("../../../test/fixtures/backend/cmake/CMakeLists.txt");
const cmake_main = @embedFile("../../../test/fixtures/backend/cmake/src/main.cpp");

const meson_build = @embedFile("../../../test/fixtures/backend/meson/meson.build");
const meson_main = @embedFile("../../../test/fixtures/backend/meson/src/main.cpp");

const bazel_module = @embedFile("../../../test/fixtures/backend/bazel/MODULE.bazel");
const bazel_build = @embedFile("../../../test/fixtures/backend/bazel/app/BUILD.bazel");
const bazel_main = @embedFile("../../../test/fixtures/backend/bazel/app/main.cc");

const cargo_toml = @embedFile("../../../test/fixtures/backend/cargo/Cargo.toml");
const cargo_main = @embedFile("../../../test/fixtures/backend/cargo/src/main.rs");
const cargo_bin = @embedFile("../../../test/fixtures/backend/cargo/src/bin/api.rs");

const go_mod = @embedFile("../../../test/fixtures/backend/go/go.mod");
const go_main = @embedFile("../../../test/fixtures/backend/go/cmd/api/main.go");

const go_work = @embedFile("../../../test/fixtures/backend/go_work/go.work");
const go_work_mod = @embedFile("../../../test/fixtures/backend/go_work/service/go.mod");
const go_work_main = @embedFile("../../../test/fixtures/backend/go_work/service/cmd/api/main.go");

const maven_pom = @embedFile("../../../test/fixtures/backend/maven/pom.xml");

const python_pyproject = @embedFile("../../../test/fixtures/backend/python/pyproject.toml");
const python_main = @embedFile("../../../test/fixtures/backend/python/app/main.py");
const python_uv_lock = @embedFile("../../../test/fixtures/backend/python/uv.lock");

const python_conda_env = @embedFile("../../../test/fixtures/backend/python_conda/environment.yml");
const python_conda_main = @embedFile("../../../test/fixtures/backend/python_conda/app/main.py");

const python_conda_yaml_env = @embedFile("../../../test/fixtures/backend/python_conda_yaml/environment.yaml");
const python_conda_yaml_main = @embedFile("../../../test/fixtures/backend/python_conda_yaml/app/main.py");

const python_requirements = @embedFile("../../../test/fixtures/backend/python_requirements/requirements.txt");
const python_requirements_main = @embedFile("../../../test/fixtures/backend/python_requirements/app/main.py");

const node_package_json = @embedFile("../../../test/fixtures/backend/node/package.json");
const node_pnpm_lock = @embedFile("../../../test/fixtures/backend/node/pnpm-lock.yaml");

const yarn_package_json = @embedFile("../../../test/fixtures/backend/yarn/package.json");
const yarn_lock = @embedFile("../../../test/fixtures/backend/yarn/yarn.lock");

const bun_package_json = @embedFile("../../../test/fixtures/backend/bun/package.json");
const bun_lock = @embedFile("../../../test/fixtures/backend/bun/bun.lock");
const bun_main = @embedFile("../../../test/fixtures/backend/bun/src/main.ts");

const gradle_build = @embedFile("../../../test/fixtures/backend/gradle/build.gradle.kts");
const gradle_wrapper = @embedFile("../../../test/fixtures/backend/gradle/gradlew");

fn writeFileTree(dir: std.Io.Dir, sub_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try dir.createDirPath(std.testing.io, parent);
    }
    try dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
}

pub fn writeCmakeProject(dir: std.Io.Dir) !void {
    try writeFileTree(dir, "CMakeLists.txt", cmake_cmakelists);
    try writeFileTree(dir, "src/main.cpp", cmake_main);
}

pub fn writeCmakeFileApiProject(dir: std.Io.Dir) !void {
    const allocator = std.heap.page_allocator;
    const root = try dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);

    try writeFileTree(dir, "CMakeLists.txt",
        \\project(demo-app)
        \\add_executable(helper)
        \\target_sources(helper PRIVATE tools/helper.cpp)
        \\add_executable(demo-app)
        \\target_sources(demo-app PRIVATE src/main.cpp)
    );
    try writeFileTree(dir, "src/main.cpp", cmake_main);
    try writeFileTree(dir, "tools/helper.cpp", "int helper() { return 0; }\n");
    try writeFileTree(dir, "build/CMakeCache.txt", "");
    try writeFileTree(dir, "build/.cmake/api/v1/reply/index-test.json",
        \\{
        \\  "reply": {
        \\    "codemodel-v2": {
        \\      "jsonFile": "codemodel-v2-test.json"
        \\    }
        \\  }
        \\}
    );
    try writeFileTree(dir, "build/.cmake/api/v1/reply/codemodel-v2-test.json",
        \\{
        \\  "configurations": [
        \\    {
        \\      "targets": [
        \\        { "name": "helper", "jsonFile": "target-helper.json" },
        \\        { "name": "demo-app", "jsonFile": "target-demo-app.json" }
        \\      ]
        \\    }
        \\  ]
        \\}
    );

    const helper_target = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "name": "helper",
        \\  "type": "EXECUTABLE",
        \\  "paths": {{
        \\    "source": "{s}",
        \\    "build": "{s}/build"
        \\  }},
        \\  "sources": [
        \\    {{ "path": "tools/helper.cpp" }}
        \\  ],
        \\  "artifacts": [
        \\    {{ "path": "bin/helper" }}
        \\  ]
        \\}}
    , .{ root, root });
    defer allocator.free(helper_target);
    try writeFileTree(dir, "build/.cmake/api/v1/reply/target-helper.json", helper_target);

    const demo_target = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "name": "demo-app",
        \\  "type": "EXECUTABLE",
        \\  "paths": {{
        \\    "source": "{s}",
        \\    "build": "{s}/build"
        \\  }},
        \\  "sources": [
        \\    {{ "path": "src/main.cpp" }}
        \\  ],
        \\  "artifacts": [
        \\    {{ "path": "bin/demo-app" }}
        \\  ]
        \\}}
    , .{ root, root });
    defer allocator.free(demo_target);
    try writeFileTree(dir, "build/.cmake/api/v1/reply/target-demo-app.json", demo_target);
}

pub fn writeMesonProject(dir: std.Io.Dir) !void {
    try writeFileTree(dir, "meson.build", meson_build);
    try writeFileTree(dir, "src/main.cpp", meson_main);
}

pub fn writeMesonIntroProject(dir: std.Io.Dir) !void {
    const allocator = std.heap.page_allocator;
    const root = try dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);

    try writeFileTree(dir, "meson.build",
        \\project('demo', 'cpp')
        \\demo_sources = files('src/main.cpp')
        \\executable('demo-app', demo_sources)
        \\executable('helper', 'tools/helper.cpp')
    );
    try writeFileTree(dir, "src/main.cpp", meson_main);
    try writeFileTree(dir, "tools/helper.cpp", "int helper() { return 0; }\n");
    try writeFileTree(dir, "build/build.ninja", "");
    const intro_targets = try std.fmt.allocPrint(allocator,
        \\[
        \\  {{
        \\    "name": "helper",
        \\    "type": "executable",
        \\    "filename": ["{s}/build/helper"],
        \\    "target_sources": [
        \\      {{
        \\        "sources": ["tools/helper.cpp"]
        \\      }}
        \\    ]
        \\  }},
        \\  {{
        \\    "name": "demo-app",
        \\    "type": "executable",
        \\    "filename": ["{s}/build/demo-app"],
        \\    "target_sources": [
        \\      {{
        \\        "sources": ["src/main.cpp"]
        \\      }}
        \\    ]
        \\  }}
        \\]
    , .{ root, root });
    defer allocator.free(intro_targets);
    try writeFileTree(dir, "build/meson-info/intro-targets.json", intro_targets);
}

pub fn writeBazelWorkspace(dir: std.Io.Dir) !void {
    try writeFileTree(dir, "MODULE.bazel", bazel_module);
    try writeFileTree(dir, "app/BUILD.bazel", bazel_build);
    try writeFileTree(dir, "app/main.cc", bazel_main);
}

pub fn writeCargoProject(dir: std.Io.Dir) !void {
    try writeFileTree(dir, "Cargo.toml", cargo_toml);
    try writeFileTree(dir, "src/main.rs", cargo_main);
    try writeFileTree(dir, "src/bin/api.rs", cargo_bin);
}

pub fn writeGoProject(dir: std.Io.Dir) !void {
    try writeFileTree(dir, "go.mod", go_mod);
    try writeFileTree(dir, "cmd/api/main.go", go_main);
}

pub fn writeGoWorkspaceProject(dir: std.Io.Dir) !void {
    try writeFileTree(dir, "go.work", go_work);
    try writeFileTree(dir, "service/go.mod", go_work_mod);
    try writeFileTree(dir, "service/cmd/api/main.go", go_work_main);
}

pub fn writeMavenProject(dir: std.Io.Dir) !void {
    try writeFileTree(dir, "pom.xml", maven_pom);
}

pub fn writePythonProject(dir: std.Io.Dir) !void {
    try writeFileTree(dir, "pyproject.toml", python_pyproject);
    try writeFileTree(dir, "uv.lock", python_uv_lock);
    try writeFileTree(dir, "app/main.py", python_main);
}

pub fn writePythonCondaProject(dir: std.Io.Dir) !void {
    try writeFileTree(dir, "environment.yml", python_conda_env);
    try writeFileTree(dir, "app/main.py", python_conda_main);
}

pub fn writePythonCondaYamlProject(dir: std.Io.Dir) !void {
    try writeFileTree(dir, "environment.yaml", python_conda_yaml_env);
    try writeFileTree(dir, "app/main.py", python_conda_yaml_main);
}

pub fn writePythonRequirementsProject(dir: std.Io.Dir) !void {
    try writeFileTree(dir, "requirements.txt", python_requirements);
    try writeFileTree(dir, "app/main.py", python_requirements_main);
}

pub fn writeNodeProject(dir: std.Io.Dir) !void {
    try writeFileTree(dir, "package.json", node_package_json);
    try writeFileTree(dir, "pnpm-lock.yaml", node_pnpm_lock);
}

pub fn writeYarnProject(dir: std.Io.Dir) !void {
    try writeFileTree(dir, "package.json", yarn_package_json);
    try writeFileTree(dir, "yarn.lock", yarn_lock);
}

pub fn writeBunProject(dir: std.Io.Dir) !void {
    try writeFileTree(dir, "package.json", bun_package_json);
    try writeFileTree(dir, "bun.lock", bun_lock);
    try writeFileTree(dir, "src/main.ts", bun_main);
}

pub fn writeGradleProject(dir: std.Io.Dir) !void {
    try writeFileTree(dir, "build.gradle.kts", gradle_build);
    try writeFileTree(dir, "gradlew", gradle_wrapper);
}
