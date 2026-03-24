-- luacheck: globals project_root config init ui state job_results quickfix_results notify_results mock_jobs
-- luacheck: globals command_to_string reset_job_results reset_quickfix_results reset_notify_results
-- luacheck: globals count_quickfix_backend_jobs count_quickfix_daemon_jobs
-- luacheck: globals count_detect_backend_jobs count_detect_backend_requests
-- luacheck: globals count_project_backend_jobs count_project_backend_requests
-- luacheck: globals get_upvalue_by_name detect_backend_tool_commands is_detect_daemon_cmd parse_detect_daemon_request
-- luacheck: globals is_project_daemon_cmd parse_project_daemon_request
-- luacheck: ignore 631


local function test_c_detected_make_targets_in_picker()
    init.setup({
        build_commands = {},
        detect_runtime = {
            async_picker = false,
        },
    })

    vim.bo.filetype = "c"
    local original_expand = vim.fn.expand
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
    local original_filereadable = vim.fn.filereadable
    local original_open_win = vim.api.nvim_open_win
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local picker_opened = false
    local rendered_lines = {}

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/cdetect/main.c" end
        return original_expand(expr)
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
        if type(cmd) == "table" and cmd[2] == "--project-parse" and cmd[3] == "--kind=c-family-auto" then
            vim.v.shell_error = 0
            return {
                "SYSTEM\tmake",
                "ROOT\t/tmp/cdetect",
                "COMMAND\tbench\tmake bench",
                "COMMAND\ttest\tmake test",
            }
        end
        if original_systemlist then
            return original_systemlist(cmd)
        end
        return {}
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
    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable
    vim.api.nvim_open_win = original_open_win
    vim.api.nvim_buf_set_lines = original_buf_set_lines

    print("✓ C detected Makefile targets in picker test passed")
end

-- Test Makefile target parsing can use the Zig project parser path.
local function test_make_targets_use_zig_project_parser()
    init.setup({
        build_commands = {},
    })

    local make_parser = require("zignite.build.project_query")
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
        assert(type(cmd) == "table", "Zig project parser should execute via argv")
        assert(cmd[2] == "--project-parse", "Make parser should call the Zig project parser mode")
        assert(cmd[3] == "--kind=c-family-auto", "Make parser should use the c-family-auto parser kind")
        assert(cmd[4] == "--path=/tmp/cdetect/main.c", "Make parser should target the current source path")
        return {
            "SYSTEM\tmake",
            "ROOT\t/tmp/cdetect",
            "COMMAND\tbench\tmake bench",
            "COMMAND\ttest\tmake test",
        }
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

    local result = make_parser.detect_c_family_build_result("/tmp/cdetect/main.c")
    assert(result ~= nil and result.system == "make", "Zig c-family parser should resolve a Make project")
    assert(result.commands.bench == "make bench", "Zig Make parser should return bench target")
    assert(result.commands.test == "make test", "Zig Make parser should return test target")

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

    local cmake_parser = require("zignite.build.project_query")
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
        assert(cmd[3] == "--kind=c-family-auto", "CMake parser should use the c-family-auto parser kind")
        assert(cmd[4] == "--path=/tmp/cmakeproj/src/main.cpp", "CMake parser should target the current source path")
        return {
            "SYSTEM\tcmake",
            "ROOT\t/tmp/cmakeproj",
            "BUILD_READY\t1",
            "COMMAND\tcmake-config\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1",
            "COMMAND\tcmake-clean\tcmake --build build --target clean",
            "COMMAND\tcmake-debug\tcmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
            "COMMAND\tcmake-release\tcmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
            "COMMAND\tcmake-test\tctest --test-dir build",
            "COMMAND\tinstall\tcmake --build build --target install",
            "TARGET\tapp\t1",
            "COMMAND\tcmake-build-app\tcmake --build build --target app",
            "COMMAND\tcmake-run-app\tcmake --build build --target app && ./build/bin/app",
            "RUN_PATH\tapp\t./build/bin/app",
            "PREFERRED\tconfig\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1",
            "PREFERRED\tclean\tcmake --build build --target clean",
            "PREFERRED\tdebug\tcmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
            "PREFERRED\trelease\tcmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
            "PREFERRED\ttest\tctest --test-dir build",
            "PREFERRED\tinstall\tcmake --build build --target install",
            "PREFERRED\tbuild\tcmake --build build",
            "PRIMARY_TARGET\tapp",
            "PRIMARY_RUN_PATH\t./build/bin/app",
            "PREFERRED\trun\tcmake --build build --target app && ./build/bin/app",
        }
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

    local cmake_result = cmake_parser.detect_c_family_build_result("/tmp/cmakeproj/src/main.cpp")
    local commands = cmake_result and cmake_result.commands or {}
    assert(
        commands["cmake-build-app"] == "cmake --build build --target app",
        "Zig CMake parser should build the target"
    )
    assert(
        commands["cmake-run-app"] == "cmake --build build --target app && ./build/bin/app",
        "Zig CMake parser should use the discovered run path directly"
    )
    assert(cmake_result ~= nil and cmake_result.system == "cmake", "Zig c-family parser should resolve CMake")

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

    local meson_parser = require("zignite.build.project_query")
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
        assert(cmd[3] == "--kind=c-family-auto", "Meson parser should use the c-family-auto parser kind")
        assert(cmd[4] == "--path=/tmp/mesonproj/src/main.cpp", "Meson parser should target the current source path")
        return {
            "SYSTEM\tmeson",
            "ROOT\t/tmp/mesonproj",
            "BUILD_READY\t1",
            "COMMAND\tmeson-setup\tmeson setup build",
            "COMMAND\tmeson-clean\tmeson compile -C build --clean",
            "COMMAND\tmeson-test\tmeson test -C build",
            "COMMAND\tinstall\tmeson install -C build",
            "TARGET\tdemo-app\t1",
            "COMMAND\tmeson-build-demo-app\tmeson compile -C build demo-app",
            "COMMAND\tmeson-run-demo-app\tmeson compile -C build demo-app && ./build/demo-app",
            "RUN_PATH\tdemo-app\t./build/demo-app",
            "PREFERRED\tsetup\tmeson setup build",
            "PREFERRED\tclean\tmeson compile -C build --clean",
            "PREFERRED\ttest\tmeson test -C build",
            "PREFERRED\tinstall\tmeson install -C build",
            "PREFERRED\tbuild\tmeson compile -C build",
            "PRIMARY_TARGET\tdemo-app",
            "PRIMARY_RUN_PATH\t./build/demo-app",
            "PREFERRED\trun\tmeson compile -C build demo-app && ./build/demo-app",
        }
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

    local meson_result = meson_parser.detect_c_family_build_result("/tmp/mesonproj/src/main.cpp")
    local commands = meson_result and meson_result.commands or {}
    assert(
        commands["meson-build-demo-app"] == "meson compile -C build demo-app",
        "Zig Meson parser should build the target"
    )
    assert(
        commands["meson-run-demo-app"] == "meson compile -C build demo-app && ./build/demo-app",
        "Zig Meson parser should use the discovered run path directly"
    )
    assert(meson_result ~= nil and meson_result.system == "meson", "Zig c-family parser should resolve Meson")

    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.v.shell_error = 0

    print("✓ Zig Meson parser test passed")
end

-- Test CMake target inference is Zig-only when the backend is unavailable.
local function test_cmake_targets_use_basic_lua_fallback()
    init.setup({
        build_commands = {},
    })

    local cmake_parser = require("zignite.build.project_query")
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
    local cmake_result = cmake_parser.detect_c_family_build_result("/tmp/cmakefallback/src/main.cpp")
    assert(cmake_result ~= nil and cmake_result.system == "cmake", "CMake fallback should still detect the project")
    assert(next(cmake_result.commands) == nil, "CMake target inference should be unavailable without Zig backend records")

    vim.fn.executable = original_executable
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile

    print("✓ CMake no-backend parser test passed")
end

-- Test Meson target inference is Zig-only when the backend is unavailable.
local function test_meson_targets_use_basic_lua_fallback()
    init.setup({
        build_commands = {},
    })

    local meson_parser = require("zignite.build.project_query")
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
    local meson_result = meson_parser.detect_c_family_build_result("/tmp/mesonfallback/src/main.cpp")
    assert(meson_result ~= nil and meson_result.system == "meson", "Meson fallback should still detect the project")
    assert(next(meson_result.commands) == nil, "Meson target inference should be unavailable without Zig backend records")

    vim.fn.executable = original_executable
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile

    print("✓ Meson no-backend parser test passed")
end

-- Test Maven project parsing can use the Zig project parser path.
local function test_maven_project_uses_zig_project_parser()
    init.setup({
        build_commands = {},
    })

    local jvm_parser = require("zignite.build.project_query")
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
        assert(type(cmd) == "table", "Zig Maven parser should execute via argv")
        assert(cmd[2] == "--project-parse", "Maven parser should call the Zig project parser mode")
        assert(cmd[3] == "--kind=jvm-auto", "JVM parser should use the jvm-auto parser kind")
        return {
            "COMMAND\tmvn-build\tmvn compile",
            "COMMAND\tmvn-test\tmvn test",
            "COMMAND\tmvn-package\tmvn package",
            "COMMAND\tmvn-run\tmvn spring-boot:run",
            "COMMAND\tbuild\tmvn compile",
            "COMMAND\ttest\tmvn test",
            "COMMAND\trun\tmvn spring-boot:run",
            "PRIMARY_RUN\tmvn spring-boot:run",
            "PREFERRED\tbuild\tmvn compile",
            "PREFERRED\ttest\tmvn test",
            "PREFERRED\trun\tmvn spring-boot:run",
        }
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
    assert(commands.build == "mvn compile", "Zig Maven parser should expose preferred generic build")
    assert(commands.test == "mvn test", "Zig Maven parser should expose preferred generic test")
    assert(commands.run == "mvn spring-boot:run", "Zig Maven parser should expose preferred generic run")

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

    local jvm_parser = require("zignite.build.project_query")
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
        assert(type(cmd) == "table", "Zig Gradle parser should execute via argv")
        assert(cmd[2] == "--project-parse", "Gradle parser should call the Zig project parser mode")
        assert(cmd[3] == "--kind=jvm-auto", "JVM parser should use the jvm-auto parser kind")
        return {
            "COMMAND\tgradle-build\t./gradlew build",
            "COMMAND\tgradle-test\t./gradlew test",
            "COMMAND\tgradle-clean\t./gradlew clean",
            "COMMAND\tgradle-run\t./gradlew bootRun",
            "COMMAND\tbuild\t./gradlew build",
            "COMMAND\ttest\t./gradlew test",
            "COMMAND\tclean\t./gradlew clean",
            "COMMAND\trun\t./gradlew bootRun",
            "PRIMARY_RUN\t./gradlew bootRun",
            "PREFERRED\tbuild\t./gradlew build",
            "PREFERRED\ttest\t./gradlew test",
            "PREFERRED\trun\t./gradlew bootRun",
        }
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
    assert(commands.build == "./gradlew build", "Zig Gradle parser should expose preferred generic build")
    assert(commands.test == "./gradlew test", "Zig Gradle parser should expose preferred generic test")
    assert(commands.run == "./gradlew bootRun", "Zig Gradle parser should expose preferred generic run")

    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.v.shell_error = 0

    print("✓ Zig Gradle parser test passed")
end

-- Test Maven project commands are Zig-owned and do not fall back to local inference.
local function test_maven_project_requires_zig_parser()
    init.setup({
        build_commands = {},
    })

    local jvm_parser = require("zignite.build.project_query")
    local original_executable = vim.fn.executable
    local original_filereadable = vim.fn.filereadable

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
    assert(vim.tbl_isempty(commands), "Maven project parsing should not infer commands without Zig")

    vim.fn.executable = original_executable
    vim.fn.filereadable = original_filereadable

    print("✓ Maven project parser requires Zig test passed")
end

-- Test Gradle project commands are Zig-owned and do not fall back to local inference.
local function test_gradle_project_requires_zig_parser()
    init.setup({
        build_commands = {},
    })

    local jvm_parser = require("zignite.build.project_query")
    local original_executable = vim.fn.executable
    local original_filereadable = vim.fn.filereadable

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
    assert(vim.tbl_isempty(commands), "Gradle project parsing should not infer commands without Zig")

    vim.fn.executable = original_executable
    vim.fn.filereadable = original_filereadable

    print("✓ Gradle project parser requires Zig test passed")
end

-- Test Cargo target parsing can use the Zig project parser path.
local function test_cargo_targets_use_zig_project_parser()
    init.setup({
        build_commands = {},
    })

    local cargo_parser = require("zignite.build.project_query")
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
        assert(cmd[3] == "--kind=cargo-auto", "Cargo parser should use the cargo-auto parser kind")
        return {
            "BIN\tdemo\t1",
            "BIN\ttool\t0",
            "COMMAND\tcargo-build-demo\tcargo build --bin 'demo'",
            "COMMAND\tcargo-run-demo\tcargo run --bin 'demo'",
            "COMMAND\tcargo-test-demo\tcargo test --bin 'demo'",
            "COMMAND\tcargo-build-tool\tcargo build --bin 'tool'",
            "COMMAND\tcargo-run-tool\tcargo run --bin 'tool'",
            "COMMAND\tcargo-test-tool\tcargo test --bin 'tool'",
            "COMMAND\trun\tcargo run --bin 'demo'",
            "COMMAND\trelease-run\tcargo run --release --bin 'demo'",
            "PRIMARY_BIN\tdemo",
            "PRIMARY_RUN\tcargo run --bin 'demo'",
            "PRIMARY_RELEASE_RUN\tcargo run --release --bin 'demo'",
            "PREFERRED\trun\tcargo run --bin 'demo'",
            "PREFERRED\trelease-run\tcargo run --release --bin 'demo'",
        }
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

    local commands, cargo_info = cargo_parser.detect_cargo_project_commands("/tmp/rustproj/src/main.rs")
    assert(commands["cargo-build-demo"] == "cargo build --bin 'demo'", "Zig Cargo parser should build the inferred bin")
    assert(commands["cargo-run-demo"] == "cargo run --bin 'demo'", "Zig Cargo parser should run the inferred bin")
    assert(cargo_info == nil, "Lua should not decode redundant Cargo parser metadata on the backend path")

    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.v.shell_error = 0

    print("✓ Zig Cargo parser test passed")
end

-- Test Cargo project commands are Zig-owned and do not fall back to local inference.
local function test_cargo_targets_require_zig_parser()
    init.setup({
        build_commands = {},
    })

    local cargo_parser = require("zignite.build.project_query")
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

    local commands, cargo_info = cargo_parser.detect_cargo_project_commands("/tmp/rustfallback/src/bin/tool.rs")
    assert(vim.tbl_isempty(commands), "Cargo project parsing should not infer commands without Zig")
    assert(cargo_info == nil, "Cargo project parsing should not return metadata without Zig")

    local main_commands, main_primary = cargo_parser.detect_cargo_project_commands("/tmp/rustfallback/src/main.rs")
    assert(vim.tbl_isempty(main_commands), "Cargo project parsing should stay empty without Zig")
    assert(main_primary == nil, "Cargo project parsing should not set a primary bin without Zig")

    vim.fn.executable = original_executable
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile

    print("✓ Cargo project parser requires Zig test passed")
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

    local go_parser = require("zignite.build.project_query")
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
        assert(cmd[3] == "--kind=go-auto", "Go parser should use the go-auto parser kind")
        return {
            "MODULE\texample.com/app",
            "PRIMARY_SELECTOR\t./app/cmd/web",
            "COMMAND\tgo-build-package\tgo build './app/cmd/web'",
            "COMMAND\tgo-run-package\tgo run './app/cmd/web'",
            "COMMAND\tgo-test-package\tgo test './app/cmd/web'",
            "COMMAND\tbuild\tgo build './app/cmd/web'",
            "COMMAND\trun\tgo run './app/cmd/web'",
            "COMMAND\ttest\tgo test './app/cmd/web'",
            "PRIMARY_BUILD\tgo build './app/cmd/web'",
            "PRIMARY_RUN\tgo run './app/cmd/web'",
            "PRIMARY_TEST\tgo test './app/cmd/web'",
            "PREFERRED\tbuild\tgo build './app/cmd/web'",
            "PREFERRED\trun\tgo run './app/cmd/web'",
            "PREFERRED\ttest\tgo test './app/cmd/web'",
        }
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

    local commands, go_info = go_parser.detect_go_project_commands("/tmp/gowork/app/cmd/web/main.go")
    assert(
        commands["go-run-package"] == "go run './app/cmd/web'",
        "Zig Go parser should build package-relative run commands from go.work"
    )
    assert(go_info == nil, "Lua should not decode redundant Go parser metadata on the backend path")

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

    local make_parser = require("zignite.build.project_query")
    local utils_module = require("zignite.utils")
    local detect_backend = require("zignite.build.detect.backend")
    local original_get_project_root = utils_module.get_project_root
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile
    local original_wait = vim.wait

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
    vim.fn.systemlist = function(cmd)
        if type(cmd) == "table" and cmd[2] == "--project-parse" and cmd[3] == "--kind=c-family-auto" then
            vim.v.shell_error = 0
            return {
                "SYSTEM\tmake",
                "ROOT\t/tmp/cdetect",
                "COMMAND\tbench\tmake bench",
                "COMMAND\ttest\tmake test",
            }
        end
        error("Unexpected one-shot project parse path")
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
    local result = make_parser.detect_c_family_build_result("/tmp/cdetect/main.c")
    assert(result ~= nil and result.system == "make", "Project daemon should resolve a Make project")
    assert(result.commands.bench == "make bench", "Project daemon should return parsed Make target")
    assert(result.commands.test == "make test", "Project daemon should return parsed Make target")
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

-- Test project parsing falls back to one-shot parsing when the daemon times out.
local function test_make_targets_fall_back_after_project_daemon_timeout()
    init.setup({
        build_commands = {},
    })

    local make_parser = require("zignite.build.project_query")
    local utils_module = require("zignite.utils")
    local detect_backend = require("zignite.build.detect.backend")
    local original_get_project_root = utils_module.get_project_root
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile
    local original_wait = vim.wait
    local original_chansend = vim.fn.chansend

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
    vim.wait = function()
        return false
    end
    vim.fn.systemlist = function(cmd)
        vim.v.shell_error = 0
        if type(cmd) == "table" and cmd[2] == "--project-parse" and cmd[3] == "--kind=c-family-auto" then
            return {
                "SYSTEM\tmake",
                "ROOT\t/tmp/cdetect",
                "COMMAND\tbench\tmake bench",
                "COMMAND\ttest\tmake test",
            }
        end
        error("Expected one-shot project parse fallback to use systemlist")
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/cdetect/Makefile" then
            return 1
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/cdetect/Makefile" then
            error("Lua Makefile parser should not be used when one-shot Zig fallback succeeds")
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end
    vim.fn.chansend = function(job_id, data)
        local job = mock_jobs[job_id]
        if job and is_project_daemon_cmd(job.cmd) then
            state.project_backend_request_count = state.project_backend_request_count + 1
            job.input = job.input .. tostring(data or "")
            return 1
        end
        if original_chansend then
            return original_chansend(job_id, data)
        end
        return 0
    end

    detect_backend.reset()
    reset_job_results()
    local result = make_parser.detect_c_family_build_result("/tmp/cdetect/main.c")
    assert(result ~= nil and result.system == "make", "Timed out daemon fallback should still detect Make")
    assert(result.commands.bench == "make bench", "Timed out project daemon should fall back to one-shot parsing")
    assert(result.commands.test == "make test", "Timed out project daemon should still return parsed targets")
    assert(
        count_project_backend_requests() == 1,
        "Timed out daemon path should still issue one request before fallback"
    )

    vim.fn.chansend = original_chansend
    utils_module.get_project_root = original_get_project_root
    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.wait = original_wait
    vim.v.shell_error = 0
    detect_backend.reset()
    reset_job_results()

    print("✓ Zig project daemon timeout fallback test passed")
end

-- Test buffered project-daemon output can be reassembled across split stdout chunks.
local function test_make_targets_use_buffered_project_daemon_chunks()
    init.setup({
        build_commands = {},
    })

    local make_parser = require("zignite.build.project_query")
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
    vim.fn.systemlist = function(cmd)
        if type(cmd) == "table" and cmd[2] == "--project-parse" and cmd[3] == "--kind=c-family-auto" then
            vim.v.shell_error = 0
            return {
                "SYSTEM\tmake",
                "ROOT\t/tmp/cdetect",
                "COMMAND\tbench\tmake bench",
                "COMMAND\ttest\tmake test",
            }
        end
        error("Unexpected one-shot project parse path")
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/cdetect/Makefile" then
            return 1
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/cdetect/Makefile" then
            error("Lua Makefile parser should not be used when buffered daemon parsing succeeds")
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end
    state.next_project_backend_stdout_chunks = {
        { "@@ZPRJ_RES_BEG" },
        { "IN 1\n\tbench\n\tt" },
        { "est\n@@ZPRJ_RES_E" },
        { "ND 1\n" },
    }

    detect_backend.reset()
    reset_job_results()
    local result = make_parser.detect_c_family_build_result("/tmp/cdetect/main.c")
    assert(result ~= nil and result.system == "make", "Buffered daemon chunks should still detect Make")
    assert(result.commands.bench == "make bench", "Buffered daemon chunks should still decode the first Make target")
    assert(result.commands.test == "make test", "Buffered daemon chunks should still decode the second Make target")

    utils_module.get_project_root = original_get_project_root
    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.wait = original_wait
    detect_backend.reset()
    reset_job_results()

    print("✓ Zig project daemon buffered chunk test passed")
end

-- Test project daemon parsing handles multi-line stdout callbacks without losing line boundaries.
local function test_make_targets_use_multiline_project_daemon_response()
    init.setup({
        build_commands = {},
    })

    local make_parser = require("zignite.build.project_query")
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
    vim.fn.systemlist = function(cmd)
        if type(cmd) == "table" and cmd[2] == "--project-parse" and cmd[3] == "--kind=c-family-auto" then
            vim.v.shell_error = 0
            return {
                "SYSTEM\tmake",
                "ROOT\t/tmp/cdetect",
                "COMMAND\tbench\tmake bench",
                "COMMAND\ttest\tmake test",
            }
        end
        vim.v.shell_error = 0
        return {}
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/cdetect/Makefile" then
            return 1
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/cdetect/Makefile" then
            error("Lua Makefile parser should not be used when the project daemon succeeds")
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end

    state.next_project_backend_stdout_chunks = {
        {
            "@@ZPRJ_RES_BEGIN 1",
            "\tCOMMAND\tbench\tmake bench",
            "\tCOMMAND\ttest\tmake test",
            "@@ZPRJ_RES_END 1",
            "",
        },
    }

    detect_backend.reset()
    reset_job_results()
    local result = make_parser.detect_c_family_build_result("/tmp/cdetect/main.c")
    assert(result ~= nil and result.system == "make", "Project daemon multiline path should still detect Make")
    assert(result.commands.bench == "make bench", "Project daemon should decode bench from multiline stdout callback")
    assert(result.commands.test == "make test", "Project daemon should decode test from multiline stdout callback")
    assert(count_project_backend_requests() == 1, "Project daemon should send one request for multiline stdout")

    utils_module.get_project_root = original_get_project_root
    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.wait = original_wait
    state.next_project_backend_stdout_chunks = nil
    detect_backend.reset()
    reset_job_results()

    print("✓ Zig project daemon multiline response test passed")
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
test_maven_project_requires_zig_parser()
test_gradle_project_requires_zig_parser()
test_cargo_targets_use_zig_project_parser()
test_cargo_targets_require_zig_parser()
test_pyproject_tools_use_zig_project_parser()
test_go_project_commands_use_zig_project_parser()
test_make_targets_use_zig_project_daemon()
test_make_targets_fall_back_after_project_daemon_timeout()
test_make_targets_use_buffered_project_daemon_chunks()
test_make_targets_use_multiline_project_daemon_response()
