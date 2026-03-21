-- luacheck: globals project_root config init ui state job_results quickfix_results notify_results mock_jobs
-- luacheck: globals command_to_string reset_job_results reset_quickfix_results reset_notify_results
-- luacheck: globals count_quickfix_backend_jobs count_quickfix_daemon_jobs
-- luacheck: globals count_detect_backend_jobs count_detect_backend_requests
-- luacheck: globals count_project_backend_jobs count_project_backend_requests
-- luacheck: globals get_upvalue_by_name detect_backend_tool_commands is_detect_daemon_cmd parse_detect_daemon_request
-- luacheck: globals is_project_daemon_cmd parse_project_daemon_request


local function test_c_detected_make_targets_in_picker()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "c"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile
    local original_open_win = vim.api.nvim_open_win
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local picker_opened = false
    local rendered_lines = {}

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/cdetect/main.c" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/cdetect/Makefile" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/cdetect/Makefile" then
            return {
                "all: app",
                "bench test: app",
                ".PHONY: all bench test",
                "\t@echo done",
            }
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end
    vim.api.nvim_open_win = function(...)
        picker_opened = true
        return original_open_win(...)
    end
    vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
        if type(lines) == "table" and #lines > 0 then
            rendered_lines = lines
        end
        if original_buf_set_lines then
            return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
        end
    end

    init.select_build_command("float")

    assert(picker_opened, "Picker should open for detected c Makefile targets")
    local rendered = table.concat(rendered_lines, "\n")
    assert(rendered:match("bench"), "Picker should include detected Makefile target: bench")
    assert(rendered:match("test"), "Picker should include detected Makefile target: test")
    assert(rendered:match("make bench"), "Detected target should map to make bench")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.api.nvim_open_win = original_open_win
    vim.api.nvim_buf_set_lines = original_buf_set_lines

    print("✓ C detected Makefile targets in picker test passed")
end

-- Test Makefile target parsing can use the Zig project parser path.
local function test_make_targets_use_zig_project_parser()
    init.setup({
        build_commands = {},
    })

    local make_parser = require("zignite.build.parsers.make")
    local utils_module = require("zignite.utils")
    local original_get_project_root = utils_module.get_project_root
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    utils_module.get_project_root = function()
        return "/tmp/cdetect"
    end
    vim.fn.executable = function(path)
        if tostring(path):match("zignite$") then
            return 1
        end
        if original_executable then
            return original_executable(path)
        end
        return 0
    end
    vim.fn.systemlist = function(cmd)
        vim.v.shell_error = 0
        assert(type(cmd) == "table", "Zig project parser should execute via argv")
        assert(cmd[2] == "--project-parse", "Make parser should call the Zig project parser mode")
        assert(cmd[3] == "--kind=make", "Make parser should use the make parser kind")
        return { "bench", "test" }
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/cdetect/Makefile" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/cdetect/Makefile" then
            error("Lua Makefile parser should not be used when Zig parser succeeds")
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end

    local commands = make_parser.detect_makefile_targets("/tmp/cdetect/main.c")
    assert(commands.bench == "make bench", "Zig Make parser should return bench target")
    assert(commands.test == "make test", "Zig Make parser should return test target")

    utils_module.get_project_root = original_get_project_root
    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.v.shell_error = 0

    print("✓ Zig Makefile parser test passed")
end

-- Test CMake target parsing can use the Zig project parser path.
local function test_cmake_targets_use_zig_project_parser()
    init.setup({
        build_commands = {},
    })

    local cmake_parser = require("zignite.build.parsers.cmake")
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    vim.fn.executable = function(path)
        if tostring(path):match("zignite$") then
            return 1
        end
        if original_executable then
            return original_executable(path)
        end
        return 0
    end
    vim.fn.systemlist = function(cmd)
        vim.v.shell_error = 0
        assert(type(cmd) == "table", "Zig CMake parser should execute via argv")
        assert(cmd[2] == "--project-parse", "CMake parser should call the Zig project parser mode")
        assert(cmd[3] == "--kind=cmake", "CMake parser should use the cmake parser kind")
        return { "TARGET\tapp\t1" }
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/cmakeproj/CMakeLists.txt" or path == "/tmp/cmakeproj/build/CMakeCache.txt" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/cmakeproj/CMakeLists.txt" then
            error("Lua CMake parser should not be used when Zig parser succeeds")
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end

    local commands, primary_target =
        cmake_parser.detect_cmake_project_commands("/tmp/cmakeproj/src/main.cpp")
    assert(
        commands["cmake-build-app"] == "cmake --build build --target app",
        "Zig CMake parser should build the target"
    )
    assert(type(commands["cmake-run-app"]) == "string", "Zig CMake parser should create a run command")
    assert(primary_target == "app", "Zig CMake parser should preserve the primary target")

    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.v.shell_error = 0

    print("✓ Zig CMake parser test passed")
end

-- Test Meson target parsing can use the Zig project parser path.
local function test_meson_targets_use_zig_project_parser()
    init.setup({
        build_commands = {},
    })

    local meson_parser = require("zignite.build.parsers.meson")
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    vim.fn.executable = function(path)
        if tostring(path):match("zignite$") then
            return 1
        end
        if original_executable then
            return original_executable(path)
        end
        return 0
    end
    vim.fn.systemlist = function(cmd)
        vim.v.shell_error = 0
        assert(type(cmd) == "table", "Zig Meson parser should execute via argv")
        assert(cmd[2] == "--project-parse", "Meson parser should call the Zig project parser mode")
        assert(cmd[3] == "--kind=meson", "Meson parser should use the meson parser kind")
        return { "TARGET\tdemo-app\t1" }
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/mesonproj/meson.build" or path == "/tmp/mesonproj/build/build.ninja" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/mesonproj/meson.build" then
            error("Lua Meson parser should not be used when Zig parser succeeds")
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end

    local commands, primary_target =
        meson_parser.detect_meson_project_commands("/tmp/mesonproj/src/main.cpp")
    assert(
        commands["meson-build-demo-app"] == "meson compile -C build demo-app",
        "Zig Meson parser should build the target"
    )
    assert(type(commands["meson-run-demo-app"]) == "string", "Zig Meson parser should create a run command")
    assert(primary_target == "demo-app", "Zig Meson parser should preserve the primary target")

    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.v.shell_error = 0

    print("✓ Zig Meson parser test passed")
end

-- Test the Lua CMake fallback only handles literal executable targets when Zig is unavailable.
local function test_cmake_targets_use_basic_lua_fallback()
    init.setup({
        build_commands = {},
    })

    local cmake_parser = require("zignite.build.parsers.cmake")
    local original_executable = vim.fn.executable
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    vim.fn.executable = function(path)
        if tostring(path):match("zignite$") then
            return 0
        end
        if original_executable then
            return original_executable(path)
        end
        return 0
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/cmakefallback/CMakeLists.txt" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/cmakefallback/CMakeLists.txt" then
            return {
                "project(demo)",
                "add_executable(app src/main.cpp)",
                "add_executable(${PROJECT_NAME} src/ignored.cpp)",
            }
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end

    local commands, primary_target =
        cmake_parser.detect_cmake_project_commands("/tmp/cmakefallback/src/main.cpp")
    local expected_cmake_build = "cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build --target app"
    assert(
        commands["cmake-build-app"] == expected_cmake_build,
        "Lua CMake fallback should keep obvious literal targets usable"
    )
    assert(primary_target == "app", "Lua CMake fallback should preserve the matching literal target")
    assert(
        commands["cmake-build-demo"] == nil,
        "Lua CMake fallback should not resolve variable-based targets without Zig"
    )

    vim.fn.executable = original_executable
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile

    print("✓ Lua CMake fallback parser test passed")
end

-- Test the Lua Meson fallback keeps literal executable parsing when Zig is unavailable.
local function test_meson_targets_use_basic_lua_fallback()
    init.setup({
        build_commands = {},
    })

    local meson_parser = require("zignite.build.parsers.meson")
    local original_executable = vim.fn.executable
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    vim.fn.executable = function(path)
        if tostring(path):match("zignite$") then
            return 0
        end
        if original_executable then
            return original_executable(path)
        end
        return 0
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/mesonfallback/meson.build" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/mesonfallback/meson.build" then
            return {
                "project('demo', 'cpp')",
                "executable('demo-app', 'src/main.cpp')",
            }
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end

    local commands, primary_target =
        meson_parser.detect_meson_project_commands("/tmp/mesonfallback/src/main.cpp")
    assert(
        commands["meson-build-demo-app"] == "meson setup build && meson compile -C build demo-app",
        "Lua Meson fallback should keep obvious literal targets usable"
    )
    assert(primary_target == "demo-app", "Lua Meson fallback should preserve the matching literal target")

    vim.fn.executable = original_executable
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile

    print("✓ Lua Meson fallback parser test passed")
end

-- Test Maven project parsing can use the Zig project parser path.
local function test_maven_project_uses_zig_project_parser()
    init.setup({
        build_commands = {},
    })

    local jvm_parser = require("zignite.build.parsers.jvm")
    local utils_module = require("zignite.utils")
    local original_get_project_root = utils_module.get_project_root
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    utils_module.get_project_root = function()
        return "/tmp/javadetect"
    end
    vim.fn.executable = function(path)
        if tostring(path):match("zignite$") then
            return 1
        end
        if original_executable then
            return original_executable(path)
        end
        return 0
    end
    vim.fn.systemlist = function(cmd)
        vim.v.shell_error = 0
        assert(type(cmd) == "table", "Zig Maven parser should execute via argv")
        assert(cmd[2] == "--project-parse", "Maven parser should call the Zig project parser mode")
        assert(cmd[3] == "--kind=maven", "Maven parser should use the maven parser kind")
        return { "compile", "test", "package", "spring-boot:run" }
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/javadetect/pom.xml" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/javadetect/pom.xml" then
            error("Lua Maven parser should not be used when Zig parser succeeds")
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end

    local commands = jvm_parser.detect_java_like_project_commands("/tmp/javadetect/src/Main.java")
    assert(commands["mvn-build"] == "mvn compile", "Zig Maven parser should return mvn compile")
    assert(commands["mvn-test"] == "mvn test", "Zig Maven parser should return mvn test")
    assert(commands["mvn-package"] == "mvn package", "Zig Maven parser should return mvn package")
    assert(commands["mvn-run"] == "mvn spring-boot:run", "Zig Maven parser should preserve the detected run goal")

    utils_module.get_project_root = original_get_project_root
    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.v.shell_error = 0

    print("✓ Zig Maven parser test passed")
end

-- Test Gradle project parsing can use the Zig project parser path.
local function test_gradle_project_uses_zig_project_parser()
    init.setup({
        build_commands = {},
    })

    local jvm_parser = require("zignite.build.parsers.jvm")
    local utils_module = require("zignite.utils")
    local original_get_project_root = utils_module.get_project_root
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    utils_module.get_project_root = function()
        return "/tmp/gradledetect"
    end
    vim.fn.executable = function(path)
        if tostring(path):match("zignite$") then
            return 1
        end
        if original_executable then
            return original_executable(path)
        end
        return 0
    end
    vim.fn.systemlist = function(cmd)
        vim.v.shell_error = 0
        assert(type(cmd) == "table", "Zig Gradle parser should execute via argv")
        assert(cmd[2] == "--project-parse", "Gradle parser should call the Zig project parser mode")
        assert(cmd[3] == "--kind=gradle", "Gradle parser should use the gradle parser kind")
        return { "build", "test", "clean", "bootRun" }
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/gradledetect/gradlew" or path == "/tmp/gradledetect/build.gradle.kts" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/gradledetect/build.gradle.kts" then
            error("Lua Gradle parser should not be used when Zig parser succeeds")
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end

    local commands = jvm_parser.detect_java_like_project_commands("/tmp/gradledetect/src/Main.kt")
    assert(commands["gradle-build"] == "./gradlew build", "Zig Gradle parser should return gradle build")
    assert(commands["gradle-test"] == "./gradlew test", "Zig Gradle parser should return gradle test")
    assert(commands["gradle-clean"] == "./gradlew clean", "Zig Gradle parser should return gradle clean")
    assert(commands["gradle-run"] == "./gradlew bootRun", "Zig Gradle parser should preserve the detected run task")

    utils_module.get_project_root = original_get_project_root
    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.v.shell_error = 0

    print("✓ Zig Gradle parser test passed")
end

-- Test the Lua Maven fallback keeps baseline tasks but leaves run inference to Zig.
local function test_maven_project_uses_basic_lua_fallback()
    init.setup({
        build_commands = {},
    })

    local jvm_parser = require("zignite.build.parsers.jvm")
    local utils_module = require("zignite.utils")
    local original_get_project_root = utils_module.get_project_root
    local original_executable = vim.fn.executable
    local original_filereadable = vim.fn.filereadable

    utils_module.get_project_root = function()
        return "/tmp/javamin"
    end
    vim.fn.executable = function(path)
        if tostring(path):match("zignite$") then
            return 0
        end
        if original_executable then
            return original_executable(path)
        end
        return 0
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/javamin/pom.xml" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end

    local commands = jvm_parser.detect_java_like_project_commands("/tmp/javamin/src/Main.java")
    assert(commands["mvn-build"] == "mvn compile", "Lua Maven fallback should keep mvn compile")
    assert(commands["mvn-test"] == "mvn test", "Lua Maven fallback should keep mvn test")
    assert(commands["mvn-package"] == "mvn package", "Lua Maven fallback should keep mvn package")
    assert(commands["mvn-run"] == nil, "Lua Maven fallback should leave run-goal inference to Zig")

    utils_module.get_project_root = original_get_project_root
    vim.fn.executable = original_executable
    vim.fn.filereadable = original_filereadable

    print("✓ Lua Maven fallback parser test passed")
end

-- Test the Lua Gradle fallback keeps baseline tasks but leaves run-task inference to Zig.
local function test_gradle_project_uses_basic_lua_fallback()
    init.setup({
        build_commands = {},
    })

    local jvm_parser = require("zignite.build.parsers.jvm")
    local utils_module = require("zignite.utils")
    local original_get_project_root = utils_module.get_project_root
    local original_executable = vim.fn.executable
    local original_filereadable = vim.fn.filereadable

    utils_module.get_project_root = function()
        return "/tmp/gradlemin"
    end
    vim.fn.executable = function(path)
        if tostring(path):match("zignite$") then
            return 0
        end
        if original_executable then
            return original_executable(path)
        end
        return 0
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/gradlemin/gradlew" or path == "/tmp/gradlemin/build.gradle.kts" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end

    local commands = jvm_parser.detect_java_like_project_commands("/tmp/gradlemin/src/Main.kt")
    assert(commands["gradle-build"] == "./gradlew build", "Lua Gradle fallback should keep gradle build")
    assert(commands["gradle-test"] == "./gradlew test", "Lua Gradle fallback should keep gradle test")
    assert(commands["gradle-clean"] == "./gradlew clean", "Lua Gradle fallback should keep gradle clean")
    assert(commands["gradle-run"] == nil, "Lua Gradle fallback should leave run-task inference to Zig")

    utils_module.get_project_root = original_get_project_root
    vim.fn.executable = original_executable
    vim.fn.filereadable = original_filereadable

    print("✓ Lua Gradle fallback parser test passed")
end

-- Test Cargo target parsing can use the Zig project parser path.
local function test_cargo_targets_use_zig_project_parser()
    init.setup({
        build_commands = {},
    })

    local cargo_parser = require("zignite.build.parsers.cargo")
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    vim.fn.executable = function(path)
        if tostring(path):match("zignite$") then
            return 1
        end
        if original_executable then
            return original_executable(path)
        end
        return 0
    end
    vim.fn.systemlist = function(cmd)
        vim.v.shell_error = 0
        assert(type(cmd) == "table", "Zig Cargo parser should execute via argv")
        assert(cmd[2] == "--project-parse", "Cargo parser should call the Zig project parser mode")
        assert(cmd[3] == "--kind=cargo", "Cargo parser should use the cargo parser kind")
        return { "BIN\tdemo\t1", "BIN\ttool\t0" }
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/rustproj/Cargo.toml" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/rustproj/Cargo.toml" then
            error("Lua Cargo parser should not be used when Zig parser succeeds")
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end

    local commands, primary_bin = cargo_parser.detect_cargo_project_commands("/tmp/rustproj/src/main.rs")
    assert(commands["cargo-build-demo"] == "cargo build --bin demo", "Zig Cargo parser should build the inferred bin")
    assert(commands["cargo-run-demo"] == "cargo run --bin demo", "Zig Cargo parser should run the inferred bin")
    assert(primary_bin == "demo", "Zig Cargo parser should preserve the primary bin")

    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.v.shell_error = 0

    print("✓ Zig Cargo parser test passed")
end

-- Test the Lua Cargo fallback only handles obvious src/bin targets when Zig is unavailable.
local function test_cargo_targets_use_basic_lua_fallback()
    init.setup({
        build_commands = {},
    })

    local cargo_parser = require("zignite.build.parsers.cargo")
    local original_executable = vim.fn.executable
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    vim.fn.executable = function(path)
        if tostring(path):match("zignite$") then
            return 0
        end
        if original_executable then
            return original_executable(path)
        end
        return 0
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/rustfallback/Cargo.toml" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/rustfallback/Cargo.toml" then
            error("Lua Cargo fallback should not parse Cargo.toml contents")
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end

    local commands, primary_bin = cargo_parser.detect_cargo_project_commands("/tmp/rustfallback/src/bin/tool.rs")
    assert(
        commands["cargo-build-tool"] == "cargo build --bin tool",
        "Lua Cargo fallback should keep src/bin builds usable"
    )
    assert(
        commands["cargo-run-tool"] == "cargo run --bin tool",
        "Lua Cargo fallback should keep src/bin runs usable"
    )
    assert(primary_bin == "tool", "Lua Cargo fallback should preserve the obvious src/bin target")

    local main_commands, main_primary = cargo_parser.detect_cargo_project_commands("/tmp/rustfallback/src/main.rs")
    assert(vim.tbl_isempty(main_commands), "Lua Cargo fallback should not infer package-name bins from Cargo.toml")
    assert(main_primary == nil, "Lua Cargo fallback should not set a primary bin for src/main.rs without Zig")

    vim.fn.executable = original_executable
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile

    print("✓ Lua Cargo fallback parser test passed")
end

-- Test pyproject tool parsing can use the Zig project parser path.
local function test_pyproject_tools_use_zig_project_parser()
    local package_utils = require("zignite.utils.package")
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    vim.fn.executable = function(path)
        if tostring(path):match("zignite$") then
            return 1
        end
        if original_executable then
            return original_executable(path)
        end
        return 0
    end
    vim.fn.systemlist = function(cmd)
        vim.v.shell_error = 0
        assert(type(cmd) == "table", "Zig pyproject parser should execute via argv")
        assert(cmd[2] == "--project-parse", "pyproject parser should call the Zig project parser mode")
        assert(cmd[3] == "--kind=pyproject", "pyproject parser should use the pyproject parser kind")
        return { "TOOL\tuv", "TOOL\tpoetry" }
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/pyproj/pyproject.toml" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/pyproj/pyproject.toml" then
            error("Lua pyproject parser should not be used when Zig parser succeeds")
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end

    local tool = package_utils.detect_python_project_tool("/tmp/pyproj/main.py", {})
    assert(tool == "uv", "Zig pyproject parser should drive Python tool detection")

    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.v.shell_error = 0

    print("✓ Zig pyproject parser test passed")
end

-- Test Go project parsing can use the Zig go.work / go.mod parser path.
local function test_go_project_commands_use_zig_project_parser()
    init.setup({
        build_commands = {},
    })

    local go_parser = require("zignite.build.parsers.go")
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    vim.fn.executable = function(path)
        if tostring(path):match("zignite$") then
            return 1
        end
        if original_executable then
            return original_executable(path)
        end
        return 0
    end
    vim.fn.systemlist = function(cmd)
        vim.v.shell_error = 0
        assert(type(cmd) == "table", "Zig Go parser should execute via argv")
        assert(cmd[2] == "--project-parse", "Go parser should call the Zig project parser mode")
        if cmd[3] == "--kind=go-work" then
            return { "USE\t/tmp/gowork/app\t1" }
        end
        if cmd[3] == "--kind=go-mod" then
            return { "MODULE\texample.com/app" }
        end
        error("Unexpected Zig Go parser kind: " .. tostring(cmd[3]))
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/gowork/go.work" or path == "/tmp/gowork/app/go.mod" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/gowork/go.work" or path == "/tmp/gowork/app/go.mod" then
            error("Lua Go parsers should not be used when Zig parser succeeds")
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end

    local commands, primary_selector, module_name =
        go_parser.detect_go_project_commands("/tmp/gowork/app/cmd/web/main.go")
    assert(
        commands["go-run-package"] == "go run ./app/cmd/web",
        "Zig Go parser should build package-relative run commands from go.work"
    )
    assert(primary_selector == "./app/cmd/web", "Zig Go parser should preserve the primary package selector")
    assert(module_name == "example.com/app", "Zig Go parser should preserve the matched module name")

    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.v.shell_error = 0

    print("✓ Zig Go parser test passed")
end

-- Test project parsing can reuse the Zig project daemon instead of spawning
-- one-shot parser processes repeatedly.
local function test_make_targets_use_zig_project_daemon()
    init.setup({
        build_commands = {},
    })

    local make_parser = require("zignite.build.parsers.make")
    local utils_module = require("zignite.utils")
    local detect_backend = require("zignite.build.detect.backend")
    local original_get_project_root = utils_module.get_project_root
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile
    local original_wait = vim.wait

    utils_module.get_project_root = function()
        return "/tmp/cdetect"
    end
    vim.fn.executable = function(path)
        if tostring(path):match("zignite$") then
            return 1
        end
        if original_executable then
            return original_executable(path)
        end
        return 0
    end
    vim.wait = function(_, condition)
        return condition()
    end
    vim.fn.systemlist = function()
        error("systemlist should not be used when the Zig project daemon is available")
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/cdetect/Makefile" then
            return 1
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/cdetect/Makefile" then
            error("Lua Makefile parser should not be used when the Zig project daemon succeeds")
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end

    detect_backend.reset()
    reset_job_results()
    local commands = make_parser.detect_makefile_targets("/tmp/cdetect/main.c")
    assert(commands.bench == "make bench", "Project daemon should return parsed Make target")
    assert(commands.test == "make test", "Project daemon should return parsed Make target")
    assert(count_project_backend_requests() == 1, "Project parser should send one daemon request")
    local saw_project_daemon = false
    for _, job in ipairs(job_results) do
        if is_project_daemon_cmd(job.cmd) then
            saw_project_daemon = true
            break
        end
    end
    assert(saw_project_daemon, "Project parser should start the Zig project daemon")

    utils_module.get_project_root = original_get_project_root
    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.wait = original_wait
    detect_backend.reset()
    reset_job_results()

    print("✓ Zig project daemon parser test passed")
end

-- Test run_build_command can execute zig commands detected from `zig --help`.

test_c_detected_make_targets_in_picker()
test_make_targets_use_zig_project_parser()
test_cmake_targets_use_zig_project_parser()
test_meson_targets_use_zig_project_parser()
test_cmake_targets_use_basic_lua_fallback()
test_meson_targets_use_basic_lua_fallback()
test_maven_project_uses_zig_project_parser()
test_gradle_project_uses_zig_project_parser()
test_maven_project_uses_basic_lua_fallback()
test_gradle_project_uses_basic_lua_fallback()
test_cargo_targets_use_zig_project_parser()
test_cargo_targets_use_basic_lua_fallback()
test_pyproject_tools_use_zig_project_parser()
test_go_project_commands_use_zig_project_parser()
test_make_targets_use_zig_project_daemon()
