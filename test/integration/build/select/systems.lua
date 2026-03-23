-- luacheck: globals project_root config init ui state job_results quickfix_results notify_results mock_jobs
-- luacheck: globals command_to_string reset_job_results reset_quickfix_results reset_notify_results
-- luacheck: globals count_quickfix_backend_jobs count_quickfix_daemon_jobs
-- luacheck: globals count_detect_backend_jobs count_detect_backend_requests
-- luacheck: globals get_upvalue_by_name detect_backend_tool_commands is_detect_daemon_cmd parse_detect_daemon_request
-- luacheck: ignore 631

---@param cmd string[]
---@param prefix string
---@return string|nil
local function find_arg(cmd, prefix)
    for _, arg in ipairs(cmd or {}) do
        if type(arg) == "string" and arg:sub(1, #prefix) == prefix then
            return arg:sub(#prefix + 1)
        end
    end
    return nil
end

---@param kind string
---@param responder fun(cmd: string[]): string[]|nil
---@param fn fun()
---@return nil
local function with_project_parse_backend(kind, responder, fn)
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist

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
        if type(cmd) == "table" and cmd[2] == "--project-parse" and cmd[3] == "--kind=" .. kind then
            vim.v.shell_error = 0
            return responder(cmd) or {}
        end
        if original_systemlist then
            return original_systemlist(cmd)
        end
        return {}
    end

    local ok, err = xpcall(fn, debug.traceback)

    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.v.shell_error = 0

    if not ok then
        error(err)
    end
end

---@return nil
local function test_cpp_make_project_filters_irrelevant_commands()
    local original_expand = vim.fn.expand
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
    local original_filereadable = vim.fn.filereadable

    init.setup({})
    vim.bo.filetype = "cpp"

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/makeproj/main.cpp" end
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
        if type(cmd) == "table" and cmd[2] == "--project-parse" and cmd[3] == "--kind=make" then
            vim.v.shell_error = 0
            return { "COMMAND\tmain\tmake main" }
        end
        if original_systemlist then
            return original_systemlist(cmd)
        end
        return {}
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/makeproj/Makefile" then
            return 1
        end
        return 0
    end

    local commands = init.get_build_commands_for_filetype("cpp")

    assert(commands.main == "make main", "Make project should expose parsed make target")
    assert(commands.build == "make", "Make project should keep generic make build alias")
    assert(commands["cmake-build"] == nil, "Make project should hide CMake-specific commands")
    assert(commands["meson-build"] == nil, "Make project should hide Meson-specific commands")

    vim.fn.expand = original_expand
    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable

    print("✓ C++ Make project filtering test passed")
end

---@return nil
local function test_cpp_cmake_project_parses_targets_and_ignores_generated_makefiles()
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    init.setup({})
    vim.bo.filetype = "cpp"

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/cmakeproj/src/main.cpp" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/cmakeproj/CMakeLists.txt" then
            return 1
        end
        if path == "/tmp/cmakeproj/build/CMakeCache.txt" then
            return 1
        end
        if path == "/tmp/cmakeproj/Makefile" then
            return 1
        end
        return 0
    end
    vim.fn.readfile = function(path, ...)
        if path == "/tmp/cmakeproj/CMakeLists.txt" then
            return {
                "project(app)",
                "add_executable(",
                "  app",
                "  src/main.cpp",
                "  src/other.cpp",
                ")",
            }
        end
        if path == "/tmp/cmakeproj/Makefile" then
            return {
                "# CMAKE generated file: DO NOT EDIT!",
                '# Generated by "Unix Makefiles" Generator, CMake Version 4.2',
                "all: cmake_check_build_system",
                "src/main.cpp.o:",
            }
        end
        if original_readfile then
            return original_readfile(path, ...)
        end
        return {}
    end

    local commands
    with_project_parse_backend("cmake", function(cmd)
        assert(cmd[4] == "--path=/tmp/cmakeproj/CMakeLists.txt", "CMake parser should query the project file")
        assert(find_arg(cmd, "--match-path=") == "/tmp/cmakeproj/src/main.cpp", "CMake parser should send match path")
        return {
            "COMMAND\tcmake-config\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1",
            "COMMAND\tcmake-clean\tcmake --build build --target clean",
            "COMMAND\tcmake-debug\tcmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
            "COMMAND\tcmake-release\tcmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
            "COMMAND\tcmake-test\tctest --test-dir build",
            "COMMAND\tinstall\tcmake --build build --target install",
            "COMMAND\tconfig\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1",
            "COMMAND\tclean\tcmake --build build --target clean",
            "COMMAND\tdebug\tcmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
            "COMMAND\trelease\tcmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
            "COMMAND\ttest\tctest --test-dir build",
            "TARGET\tapp\t1",
            "COMMAND\tcmake-build\tcmake --build build",
            "COMMAND\tcmake-run\tcmake --build build --target app && for ZIGNITE_CANDIDATE in ./build/app ./build/app.exe ./build/bin/app ./build/bin/app.exe ./build/Debug/app ./build/Debug/app.exe ./build/Release/app ./build/Release/app.exe ./build/RelWithDebInfo/app ./build/RelWithDebInfo/app.exe ./build/MinSizeRel/app ./build/MinSizeRel/app.exe ./build/bin/Debug/app ./build/bin/Debug/app.exe ./build/bin/Release/app ./build/bin/Release/app.exe ./build/bin/RelWithDebInfo/app ./build/bin/RelWithDebInfo/app.exe ./build/bin/MinSizeRel/app ./build/bin/MinSizeRel/app.exe; do if [ -x \"$ZIGNITE_CANDIDATE\" ]; then \"$ZIGNITE_CANDIDATE\"; exit $?; fi; done; ZIGNITE_BIN=$(find build -type f \\( -name app -o -name app.exe \\) ! -path '*/CMakeFiles/*' ! -path '*/meson-private/*' ! -path '*/meson-logs/*' | head -n 1) && if [ -n \"$ZIGNITE_BIN\" ] && [ -x \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; elif [ -n \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; else ./build/app; fi",
            "COMMAND\tbuild\tcmake --build build",
            "COMMAND\trun\tcmake --build build --target app && for ZIGNITE_CANDIDATE in ./build/app ./build/app.exe ./build/bin/app ./build/bin/app.exe ./build/Debug/app ./build/Debug/app.exe ./build/Release/app ./build/Release/app.exe ./build/RelWithDebInfo/app ./build/RelWithDebInfo/app.exe ./build/MinSizeRel/app ./build/MinSizeRel/app.exe ./build/bin/Debug/app ./build/bin/Debug/app.exe ./build/bin/Release/app ./build/bin/Release/app.exe ./build/bin/RelWithDebInfo/app ./build/bin/RelWithDebInfo/app.exe ./build/bin/MinSizeRel/app ./build/bin/MinSizeRel/app.exe; do if [ -x \"$ZIGNITE_CANDIDATE\" ]; then \"$ZIGNITE_CANDIDATE\"; exit $?; fi; done; ZIGNITE_BIN=$(find build -type f \\( -name app -o -name app.exe \\) ! -path '*/CMakeFiles/*' ! -path '*/meson-private/*' ! -path '*/meson-logs/*' | head -n 1) && if [ -n \"$ZIGNITE_BIN\" ] && [ -x \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; elif [ -n \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; else ./build/app; fi",
            "COMMAND\tcmake-build-app\tcmake --build build --target app",
            "COMMAND\tcmake-run-app\tcmake --build build --target app && for ZIGNITE_CANDIDATE in ./build/app ./build/app.exe ./build/bin/app ./build/bin/app.exe ./build/Debug/app ./build/Debug/app.exe ./build/Release/app ./build/Release/app.exe ./build/RelWithDebInfo/app ./build/RelWithDebInfo/app.exe ./build/MinSizeRel/app ./build/MinSizeRel/app.exe ./build/bin/Debug/app ./build/bin/Debug/app.exe ./build/bin/Release/app ./build/bin/Release/app.exe ./build/bin/RelWithDebInfo/app ./build/bin/RelWithDebInfo/app.exe ./build/bin/MinSizeRel/app ./build/bin/MinSizeRel/app.exe; do if [ -x \"$ZIGNITE_CANDIDATE\" ]; then \"$ZIGNITE_CANDIDATE\"; exit $?; fi; done; ZIGNITE_BIN=$(find build -type f \\( -name app -o -name app.exe \\) ! -path '*/CMakeFiles/*' ! -path '*/meson-private/*' ! -path '*/meson-logs/*' | head -n 1) && if [ -n \"$ZIGNITE_BIN\" ] && [ -x \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; elif [ -n \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; else ./build/app; fi",
            "PREFERRED\tbuild\tcmake --build build",
            "PRIMARY_TARGET\tapp",
            "PREFERRED\trun\tcmake --build build --target app && for ZIGNITE_CANDIDATE in ./build/app ./build/app.exe ./build/bin/app ./build/bin/app.exe ./build/Debug/app ./build/Debug/app.exe ./build/Release/app ./build/Release/app.exe ./build/RelWithDebInfo/app ./build/RelWithDebInfo/app.exe ./build/MinSizeRel/app ./build/MinSizeRel/app.exe ./build/bin/Debug/app ./build/bin/Debug/app.exe ./build/bin/Release/app ./build/bin/Release/app.exe ./build/bin/RelWithDebInfo/app ./build/bin/RelWithDebInfo/app.exe ./build/bin/MinSizeRel/app ./build/bin/MinSizeRel/app.exe; do if [ -x \"$ZIGNITE_CANDIDATE\" ]; then \"$ZIGNITE_CANDIDATE\"; exit $?; fi; done; ZIGNITE_BIN=$(find build -type f \\( -name app -o -name app.exe \\) ! -path '*/CMakeFiles/*' ! -path '*/meson-private/*' ! -path '*/meson-logs/*' | head -n 1) && if [ -n \"$ZIGNITE_BIN\" ] && [ -x \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; elif [ -n \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; else ./build/app; fi",
        }
    end, function()
        commands = init.get_build_commands_for_filetype("cpp")
    end)

    assert(
        commands["cmake-build-app"] == "cmake --build build --target app",
        "CMake target build command should be inferred"
    )
    assert(
        commands["cmake-run-app"]:match("^cmake %-%-build build %-%-target app && "),
        "CMake target run command should build the inferred target first"
    )
    assert(
        commands["cmake-run-app"]:match("find build %-type f"),
        "CMake target run command should discover the built executable inside build/"
    )
    assert(
        commands["cmake-run-app"]:match("%./build/app"),
        "CMake target run command should keep a build/app fallback"
    )
    assert(
        commands["cmake-run-app"]:match("%./build/Debug/app"),
        "CMake target run command should check common multi-config output directories"
    )
    assert(
        commands["cmake-run-app"]:match("%./build/bin/app"),
        "CMake target run command should check common bin output directories"
    )
    assert(
        commands["cmake-run"] == commands["cmake-run-app"],
        "Generic cmake-run should use the inferred executable target"
    )
    assert(commands["cmake-build"] == "cmake --build build", "Generic cmake-build should be direct")
    assert(commands["cmake-clean"] == "cmake --build build --target clean", "Generic cmake-clean should be direct")
    assert(commands.run == commands["cmake-run-app"], "Generic run should follow the inferred CMake target")
    assert(commands.build == commands["cmake-build"], "Generic build should map to cmake-build in CMake projects")
    assert(commands["all"] == nil, "Generated CMake Makefile targets should not leak into command list")
    assert(commands["src/main.cpp.o"] == nil, "Generated CMake object targets should not leak into command list")
    assert(commands["meson-build"] == nil, "CMake project should hide Meson-specific commands")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile

    print("✓ C++ CMake target inference test passed")
end

---@return nil
local function test_cpp_cmake_project_bootstraps_missing_build_dir()
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    init.setup({})
    vim.bo.filetype = "cpp"

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/cmakebootstrap/src/main.cpp" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/cmakebootstrap/CMakeLists.txt" then
            return 1
        end
        return 0
    end
    vim.fn.readfile = function(path, ...)
        if path == "/tmp/cmakebootstrap/CMakeLists.txt" then
            return {
                "project(app)",
                "add_executable(app src/main.cpp)",
            }
        end
        if original_readfile then
            return original_readfile(path, ...)
        end
        return {}
    end

    local commands
    with_project_parse_backend("cmake", function(cmd)
        assert(cmd[4] == "--path=/tmp/cmakebootstrap/CMakeLists.txt", "CMake parser should query the project file")
        assert(find_arg(cmd, "--match-path=") == "/tmp/cmakebootstrap/src/main.cpp", "CMake parser should send match path")
        return {
            "COMMAND\tcmake-config\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1",
            "COMMAND\tcmake-clean\tcmake -E rm -rf build",
            "COMMAND\tcmake-debug\tcmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
            "COMMAND\tcmake-release\tcmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
            "COMMAND\tcmake-test\tctest --test-dir build",
            "COMMAND\tinstall\tcmake --build build --target install",
            "COMMAND\tconfig\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1",
            "COMMAND\tclean\tcmake -E rm -rf build",
            "COMMAND\tdebug\tcmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
            "COMMAND\trelease\tcmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
            "COMMAND\ttest\tctest --test-dir build",
            "TARGET\tapp\t1",
            "COMMAND\tcmake-build\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
            "COMMAND\tcmake-run\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build --target app && for ZIGNITE_CANDIDATE in ./build/app ./build/app.exe ./build/bin/app ./build/bin/app.exe ./build/Debug/app ./build/Debug/app.exe ./build/Release/app ./build/Release/app.exe ./build/RelWithDebInfo/app ./build/RelWithDebInfo/app.exe ./build/MinSizeRel/app ./build/MinSizeRel/app.exe ./build/bin/Debug/app ./build/bin/Debug/app.exe ./build/bin/Release/app ./build/bin/Release/app.exe ./build/bin/RelWithDebInfo/app ./build/bin/RelWithDebInfo/app.exe ./build/bin/MinSizeRel/app ./build/bin/MinSizeRel/app.exe; do if [ -x \"$ZIGNITE_CANDIDATE\" ]; then \"$ZIGNITE_CANDIDATE\"; exit $?; fi; done; ZIGNITE_BIN=$(find build -type f \\( -name app -o -name app.exe \\) ! -path '*/CMakeFiles/*' ! -path '*/meson-private/*' ! -path '*/meson-logs/*' | head -n 1) && if [ -n \"$ZIGNITE_BIN\" ] && [ -x \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; elif [ -n \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; else ./build/app; fi",
            "COMMAND\tbuild\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
            "COMMAND\trun\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build --target app && for ZIGNITE_CANDIDATE in ./build/app ./build/app.exe ./build/bin/app ./build/bin/app.exe ./build/Debug/app ./build/Debug/app.exe ./build/Release/app ./build/Release/app.exe ./build/RelWithDebInfo/app ./build/RelWithDebInfo/app.exe ./build/MinSizeRel/app ./build/MinSizeRel/app.exe ./build/bin/Debug/app ./build/bin/Debug/app.exe ./build/bin/Release/app ./build/bin/Release/app.exe ./build/bin/RelWithDebInfo/app ./build/bin/RelWithDebInfo/app.exe ./build/bin/MinSizeRel/app ./build/bin/MinSizeRel/app.exe; do if [ -x \"$ZIGNITE_CANDIDATE\" ]; then \"$ZIGNITE_CANDIDATE\"; exit $?; fi; done; ZIGNITE_BIN=$(find build -type f \\( -name app -o -name app.exe \\) ! -path '*/CMakeFiles/*' ! -path '*/meson-private/*' ! -path '*/meson-logs/*' | head -n 1) && if [ -n \"$ZIGNITE_BIN\" ] && [ -x \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; elif [ -n \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; else ./build/app; fi",
            "COMMAND\tcmake-build-app\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build --target app",
            "COMMAND\tcmake-run-app\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build --target app && for ZIGNITE_CANDIDATE in ./build/app ./build/app.exe ./build/bin/app ./build/bin/app.exe ./build/Debug/app ./build/Debug/app.exe ./build/Release/app ./build/Release/app.exe ./build/RelWithDebInfo/app ./build/RelWithDebInfo/app.exe ./build/MinSizeRel/app ./build/MinSizeRel/app.exe ./build/bin/Debug/app ./build/bin/Debug/app.exe ./build/bin/Release/app ./build/bin/Release/app.exe ./build/bin/RelWithDebInfo/app ./build/bin/RelWithDebInfo/app.exe ./build/bin/MinSizeRel/app ./build/bin/MinSizeRel/app.exe; do if [ -x \"$ZIGNITE_CANDIDATE\" ]; then \"$ZIGNITE_CANDIDATE\"; exit $?; fi; done; ZIGNITE_BIN=$(find build -type f \\( -name app -o -name app.exe \\) ! -path '*/CMakeFiles/*' ! -path '*/meson-private/*' ! -path '*/meson-logs/*' | head -n 1) && if [ -n \"$ZIGNITE_BIN\" ] && [ -x \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; elif [ -n \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; else ./build/app; fi",
            "PREFERRED\tbuild\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
            "PRIMARY_TARGET\tapp",
            "PREFERRED\trun\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build --target app && for ZIGNITE_CANDIDATE in ./build/app ./build/app.exe ./build/bin/app ./build/bin/app.exe ./build/Debug/app ./build/Debug/app.exe ./build/Release/app ./build/Release/app.exe ./build/RelWithDebInfo/app ./build/RelWithDebInfo/app.exe ./build/MinSizeRel/app ./build/MinSizeRel/app.exe ./build/bin/Debug/app ./build/bin/Debug/app.exe ./build/bin/Release/app ./build/bin/Release/app.exe ./build/bin/RelWithDebInfo/app ./build/bin/RelWithDebInfo/app.exe ./build/bin/MinSizeRel/app ./build/bin/MinSizeRel/app.exe; do if [ -x \"$ZIGNITE_CANDIDATE\" ]; then \"$ZIGNITE_CANDIDATE\"; exit $?; fi; done; ZIGNITE_BIN=$(find build -type f \\( -name app -o -name app.exe \\) ! -path '*/CMakeFiles/*' ! -path '*/meson-private/*' ! -path '*/meson-logs/*' | head -n 1) && if [ -n \"$ZIGNITE_BIN\" ] && [ -x \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; elif [ -n \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; else ./build/app; fi",
        }
    end, function()
        commands = init.get_build_commands_for_filetype("cpp")
    end)

    assert(
        commands["cmake-build"] == "cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
        "CMake build should bootstrap missing build dir"
    )
    assert(
        commands["cmake-run-app"]
            :match("^cmake %-B build %-DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake %-%-build build %-%-target app && "),
        "CMake target run should bootstrap missing build dir before execution"
    )
    assert(
        commands["cmake-run-app"]:match("find build %-type f"),
        "Bootstrapped CMake target run should discover the built executable"
    )
    assert(commands.run == commands["cmake-run-app"], "Generic run should follow bootstrapped CMake target")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile

    print("✓ C++ CMake bootstrap test passed")
end

---@return nil
local function test_cpp_meson_project_parses_targets()
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    init.setup({})
    vim.bo.filetype = "cpp"

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/mesonproj/src/main.cpp" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/mesonproj/meson.build" then
            return 1
        end
        if path == "/tmp/mesonproj/build/build.ninja" then
            return 1
        end
        return 0
    end
    vim.fn.readfile = function(path, ...)
        if path == "/tmp/mesonproj/meson.build" then
            return {
                "project('demo', 'cpp')",
                "executable(",
                "  'demo-app',",
                "  [",
                "    'src/main.cpp',",
                "    'src/other.cpp',",
                "  ],",
                ")",
            }
        end
        if original_readfile then
            return original_readfile(path, ...)
        end
        return {}
    end

    local commands
    with_project_parse_backend("meson", function(cmd)
        assert(cmd[4] == "--path=/tmp/mesonproj/meson.build", "Meson parser should query the project file")
        assert(find_arg(cmd, "--match-path=") == "/tmp/mesonproj/src/main.cpp", "Meson parser should send match path")
        return {
            "COMMAND\tmeson-setup\tmeson setup build",
            "COMMAND\tmeson-clean\tmeson compile -C build --clean",
            "COMMAND\tmeson-test\tmeson test -C build",
            "COMMAND\tinstall\tmeson install -C build",
            "COMMAND\tsetup\tmeson setup build",
            "COMMAND\tclean\tmeson compile -C build --clean",
            "COMMAND\ttest\tmeson test -C build",
            "TARGET\tdemo-app\t1",
            "COMMAND\tmeson-build\tmeson compile -C build",
            "COMMAND\tmeson-run\tmeson compile -C build demo-app && for ZIGNITE_CANDIDATE in ./build/demo-app ./build/demo-app.exe ./build/bin/demo-app ./build/bin/demo-app.exe ./build/Debug/demo-app ./build/Debug/demo-app.exe ./build/Release/demo-app ./build/Release/demo-app.exe ./build/RelWithDebInfo/demo-app ./build/RelWithDebInfo/demo-app.exe ./build/MinSizeRel/demo-app ./build/MinSizeRel/demo-app.exe ./build/bin/Debug/demo-app ./build/bin/Debug/demo-app.exe ./build/bin/Release/demo-app ./build/bin/Release/demo-app.exe ./build/bin/RelWithDebInfo/demo-app ./build/bin/RelWithDebInfo/demo-app.exe ./build/bin/MinSizeRel/demo-app ./build/bin/MinSizeRel/demo-app.exe; do if [ -x \"$ZIGNITE_CANDIDATE\" ]; then \"$ZIGNITE_CANDIDATE\"; exit $?; fi; done; ZIGNITE_BIN=$(find build -type f \\( -name demo-app -o -name demo-app.exe \\) ! -path '*/CMakeFiles/*' ! -path '*/meson-private/*' ! -path '*/meson-logs/*' | head -n 1) && if [ -n \"$ZIGNITE_BIN\" ] && [ -x \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; elif [ -n \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; else ./build/demo-app; fi",
            "COMMAND\tbuild\tmeson compile -C build",
            "COMMAND\trun\tmeson compile -C build demo-app && for ZIGNITE_CANDIDATE in ./build/demo-app ./build/demo-app.exe ./build/bin/demo-app ./build/bin/demo-app.exe ./build/Debug/demo-app ./build/Debug/demo-app.exe ./build/Release/demo-app ./build/Release/demo-app.exe ./build/RelWithDebInfo/demo-app ./build/RelWithDebInfo/demo-app.exe ./build/MinSizeRel/demo-app ./build/MinSizeRel/demo-app.exe ./build/bin/Debug/demo-app ./build/bin/Debug/demo-app.exe ./build/bin/Release/demo-app ./build/bin/Release/demo-app.exe ./build/bin/RelWithDebInfo/demo-app ./build/bin/RelWithDebInfo/demo-app.exe ./build/bin/MinSizeRel/demo-app ./build/bin/MinSizeRel/demo-app.exe; do if [ -x \"$ZIGNITE_CANDIDATE\" ]; then \"$ZIGNITE_CANDIDATE\"; exit $?; fi; done; ZIGNITE_BIN=$(find build -type f \\( -name demo-app -o -name demo-app.exe \\) ! -path '*/CMakeFiles/*' ! -path '*/meson-private/*' ! -path '*/meson-logs/*' | head -n 1) && if [ -n \"$ZIGNITE_BIN\" ] && [ -x \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; elif [ -n \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; else ./build/demo-app; fi",
            "COMMAND\tmeson-build-demo-app\tmeson compile -C build demo-app",
            "COMMAND\tmeson-run-demo-app\tmeson compile -C build demo-app && for ZIGNITE_CANDIDATE in ./build/demo-app ./build/demo-app.exe ./build/bin/demo-app ./build/bin/demo-app.exe ./build/Debug/demo-app ./build/Debug/demo-app.exe ./build/Release/demo-app ./build/Release/demo-app.exe ./build/RelWithDebInfo/demo-app ./build/RelWithDebInfo/demo-app.exe ./build/MinSizeRel/demo-app ./build/MinSizeRel/demo-app.exe ./build/bin/Debug/demo-app ./build/bin/Debug/demo-app.exe ./build/bin/Release/demo-app ./build/bin/Release/demo-app.exe ./build/bin/RelWithDebInfo/demo-app ./build/bin/RelWithDebInfo/demo-app.exe ./build/bin/MinSizeRel/demo-app ./build/bin/MinSizeRel/demo-app.exe; do if [ -x \"$ZIGNITE_CANDIDATE\" ]; then \"$ZIGNITE_CANDIDATE\"; exit $?; fi; done; ZIGNITE_BIN=$(find build -type f \\( -name demo-app -o -name demo-app.exe \\) ! -path '*/CMakeFiles/*' ! -path '*/meson-private/*' ! -path '*/meson-logs/*' | head -n 1) && if [ -n \"$ZIGNITE_BIN\" ] && [ -x \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; elif [ -n \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; else ./build/demo-app; fi",
            "PREFERRED\tbuild\tmeson compile -C build",
            "PRIMARY_TARGET\tdemo-app",
            "PREFERRED\trun\tmeson compile -C build demo-app && for ZIGNITE_CANDIDATE in ./build/demo-app ./build/demo-app.exe ./build/bin/demo-app ./build/bin/demo-app.exe ./build/Debug/demo-app ./build/Debug/demo-app.exe ./build/Release/demo-app ./build/Release/demo-app.exe ./build/RelWithDebInfo/demo-app ./build/RelWithDebInfo/demo-app.exe ./build/MinSizeRel/demo-app ./build/MinSizeRel/demo-app.exe ./build/bin/Debug/demo-app ./build/bin/Debug/demo-app.exe ./build/bin/Release/demo-app ./build/bin/Release/demo-app.exe ./build/bin/RelWithDebInfo/demo-app ./build/bin/RelWithDebInfo/demo-app.exe ./build/bin/MinSizeRel/demo-app ./build/bin/MinSizeRel/demo-app.exe; do if [ -x \"$ZIGNITE_CANDIDATE\" ]; then \"$ZIGNITE_CANDIDATE\"; exit $?; fi; done; ZIGNITE_BIN=$(find build -type f \\( -name demo-app -o -name demo-app.exe \\) ! -path '*/CMakeFiles/*' ! -path '*/meson-private/*' ! -path '*/meson-logs/*' | head -n 1) && if [ -n \"$ZIGNITE_BIN\" ] && [ -x \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; elif [ -n \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; else ./build/demo-app; fi",
        }
    end, function()
        commands = init.get_build_commands_for_filetype("cpp")
    end)

    assert(
        commands["meson-build-demo-app"] == "meson compile -C build demo-app",
        "Meson target build command should be inferred"
    )
    assert(
        commands["meson-run-demo-app"]:match("^meson compile %-C build demo%-app && "),
        "Meson target run command should build the inferred target first"
    )
    assert(
        commands["meson-run-demo-app"]:match("find build %-type f"),
        "Meson target run command should discover the built executable inside build/"
    )
    assert(
        commands["meson-run-demo-app"]:match("%./build/demo%-app"),
        "Meson target run command should keep a build/demo-app fallback"
    )
    assert(
        commands["meson-run-demo-app"]:match("%./build/Debug/demo%-app"),
        "Meson target run command should check common multi-config output directories"
    )
    assert(
        commands["meson-run-demo-app"]:match("%./build/bin/demo%-app"),
        "Meson target run command should check common bin output directories"
    )
    assert(commands["meson-build"] == "meson compile -C build", "Generic meson-build should be direct")
    assert(commands["meson-clean"] == "meson compile -C build --clean", "Generic meson-clean should be direct")
    assert(commands["meson-run"] == commands["meson-run-demo-app"], "Generic meson-run should use inferred target")
    assert(commands.run == commands["meson-run-demo-app"], "Generic run should follow the inferred Meson target")
    assert(commands.build == commands["meson-build"], "Generic build should map to meson-build in Meson projects")
    assert(commands["cmake-build"] == nil, "Meson project should hide CMake-specific commands")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile

    print("✓ C++ Meson target inference test passed")
end

---@return nil
local function test_cpp_meson_project_bootstraps_missing_build_dir()
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    init.setup({})
    vim.bo.filetype = "cpp"

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/mesonbootstrap/src/main.cpp" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/mesonbootstrap/meson.build" then
            return 1
        end
        return 0
    end
    vim.fn.readfile = function(path, ...)
        if path == "/tmp/mesonbootstrap/meson.build" then
            return {
                "project('demo', 'cpp')",
                "executable('demo-app', 'src/main.cpp')",
            }
        end
        if original_readfile then
            return original_readfile(path, ...)
        end
        return {}
    end

    local commands
    with_project_parse_backend("meson", function(cmd)
        assert(cmd[4] == "--path=/tmp/mesonbootstrap/meson.build", "Meson parser should query the project file")
        assert(find_arg(cmd, "--match-path=") == "/tmp/mesonbootstrap/src/main.cpp", "Meson parser should send match path")
        return {
            "COMMAND\tmeson-setup\tmeson setup build",
            "COMMAND\tmeson-clean\tcmake -E rm -rf build",
            "COMMAND\tmeson-test\tmeson test -C build",
            "COMMAND\tinstall\tmeson install -C build",
            "COMMAND\tsetup\tmeson setup build",
            "COMMAND\tclean\tcmake -E rm -rf build",
            "COMMAND\ttest\tmeson test -C build",
            "TARGET\tdemo-app\t1",
            "COMMAND\tmeson-build\tmeson setup build && meson compile -C build",
            "COMMAND\tmeson-run\tmeson setup build && meson compile -C build demo-app && for ZIGNITE_CANDIDATE in ./build/demo-app ./build/demo-app.exe ./build/bin/demo-app ./build/bin/demo-app.exe ./build/Debug/demo-app ./build/Debug/demo-app.exe ./build/Release/demo-app ./build/Release/demo-app.exe ./build/RelWithDebInfo/demo-app ./build/RelWithDebInfo/demo-app.exe ./build/MinSizeRel/demo-app ./build/MinSizeRel/demo-app.exe ./build/bin/Debug/demo-app ./build/bin/Debug/demo-app.exe ./build/bin/Release/demo-app ./build/bin/Release/demo-app.exe ./build/bin/RelWithDebInfo/demo-app ./build/bin/RelWithDebInfo/demo-app.exe ./build/bin/MinSizeRel/demo-app ./build/bin/MinSizeRel/demo-app.exe; do if [ -x \"$ZIGNITE_CANDIDATE\" ]; then \"$ZIGNITE_CANDIDATE\"; exit $?; fi; done; ZIGNITE_BIN=$(find build -type f \\( -name demo-app -o -name demo-app.exe \\) ! -path '*/CMakeFiles/*' ! -path '*/meson-private/*' ! -path '*/meson-logs/*' | head -n 1) && if [ -n \"$ZIGNITE_BIN\" ] && [ -x \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; elif [ -n \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; else ./build/demo-app; fi",
            "COMMAND\tbuild\tmeson setup build && meson compile -C build",
            "COMMAND\trun\tmeson setup build && meson compile -C build demo-app && for ZIGNITE_CANDIDATE in ./build/demo-app ./build/demo-app.exe ./build/bin/demo-app ./build/bin/demo-app.exe ./build/Debug/demo-app ./build/Debug/demo-app.exe ./build/Release/demo-app ./build/Release/demo-app.exe ./build/RelWithDebInfo/demo-app ./build/RelWithDebInfo/demo-app.exe ./build/MinSizeRel/demo-app ./build/MinSizeRel/demo-app.exe ./build/bin/Debug/demo-app ./build/bin/Debug/demo-app.exe ./build/bin/Release/demo-app ./build/bin/Release/demo-app.exe ./build/bin/RelWithDebInfo/demo-app ./build/bin/RelWithDebInfo/demo-app.exe ./build/bin/MinSizeRel/demo-app ./build/bin/MinSizeRel/demo-app.exe; do if [ -x \"$ZIGNITE_CANDIDATE\" ]; then \"$ZIGNITE_CANDIDATE\"; exit $?; fi; done; ZIGNITE_BIN=$(find build -type f \\( -name demo-app -o -name demo-app.exe \\) ! -path '*/CMakeFiles/*' ! -path '*/meson-private/*' ! -path '*/meson-logs/*' | head -n 1) && if [ -n \"$ZIGNITE_BIN\" ] && [ -x \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; elif [ -n \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; else ./build/demo-app; fi",
            "COMMAND\tmeson-build-demo-app\tmeson setup build && meson compile -C build demo-app",
            "COMMAND\tmeson-run-demo-app\tmeson setup build && meson compile -C build demo-app && for ZIGNITE_CANDIDATE in ./build/demo-app ./build/demo-app.exe ./build/bin/demo-app ./build/bin/demo-app.exe ./build/Debug/demo-app ./build/Debug/demo-app.exe ./build/Release/demo-app ./build/Release/demo-app.exe ./build/RelWithDebInfo/demo-app ./build/RelWithDebInfo/demo-app.exe ./build/MinSizeRel/demo-app ./build/MinSizeRel/demo-app.exe ./build/bin/Debug/demo-app ./build/bin/Debug/demo-app.exe ./build/bin/Release/demo-app ./build/bin/Release/demo-app.exe ./build/bin/RelWithDebInfo/demo-app ./build/bin/RelWithDebInfo/demo-app.exe ./build/bin/MinSizeRel/demo-app ./build/bin/MinSizeRel/demo-app.exe; do if [ -x \"$ZIGNITE_CANDIDATE\" ]; then \"$ZIGNITE_CANDIDATE\"; exit $?; fi; done; ZIGNITE_BIN=$(find build -type f \\( -name demo-app -o -name demo-app.exe \\) ! -path '*/CMakeFiles/*' ! -path '*/meson-private/*' ! -path '*/meson-logs/*' | head -n 1) && if [ -n \"$ZIGNITE_BIN\" ] && [ -x \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; elif [ -n \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; else ./build/demo-app; fi",
            "PREFERRED\tbuild\tmeson setup build && meson compile -C build",
            "PRIMARY_TARGET\tdemo-app",
            "PREFERRED\trun\tmeson setup build && meson compile -C build demo-app && for ZIGNITE_CANDIDATE in ./build/demo-app ./build/demo-app.exe ./build/bin/demo-app ./build/bin/demo-app.exe ./build/Debug/demo-app ./build/Debug/demo-app.exe ./build/Release/demo-app ./build/Release/demo-app.exe ./build/RelWithDebInfo/demo-app ./build/RelWithDebInfo/demo-app.exe ./build/MinSizeRel/demo-app ./build/MinSizeRel/demo-app.exe ./build/bin/Debug/demo-app ./build/bin/Debug/demo-app.exe ./build/bin/Release/demo-app ./build/bin/Release/demo-app.exe ./build/bin/RelWithDebInfo/demo-app ./build/bin/RelWithDebInfo/demo-app.exe ./build/bin/MinSizeRel/demo-app ./build/bin/MinSizeRel/demo-app.exe; do if [ -x \"$ZIGNITE_CANDIDATE\" ]; then \"$ZIGNITE_CANDIDATE\"; exit $?; fi; done; ZIGNITE_BIN=$(find build -type f \\( -name demo-app -o -name demo-app.exe \\) ! -path '*/CMakeFiles/*' ! -path '*/meson-private/*' ! -path '*/meson-logs/*' | head -n 1) && if [ -n \"$ZIGNITE_BIN\" ] && [ -x \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; elif [ -n \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; else ./build/demo-app; fi",
        }
    end, function()
        commands = init.get_build_commands_for_filetype("cpp")
    end)

    assert(
        commands["meson-build"] == "meson setup build && meson compile -C build",
        "Meson build should bootstrap missing build dir"
    )
    assert(
        commands["meson-run-demo-app"]:match("^meson setup build && meson compile %-C build demo%-app && "),
        "Meson target run should bootstrap missing build dir before execution"
    )
    assert(
        commands["meson-run-demo-app"]:match("find build %-type f"),
        "Bootstrapped Meson target run should discover the built executable"
    )
    assert(commands.run == commands["meson-run-demo-app"], "Generic run should follow bootstrapped Meson target")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile

    print("✓ C++ Meson bootstrap test passed")
end

---@return nil
local function test_cpp_cmake_target_cache_is_file_specific()
    local build = require("zignite.build")
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    init.setup({})
    build.reset()
    vim.bo.filetype = "cpp"

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/cmakecache/hello_c.c" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/cmakecache/CMakeLists.txt" or path == "/tmp/cmakecache/build/CMakeCache.txt" then
            return 1
        end
        return 0
    end
    vim.fn.readfile = function(path, ...)
        if path == "/tmp/cmakecache/CMakeLists.txt" then
            return {
                "project(cache)",
                "add_executable(hello_c hello_c.c)",
                "add_executable(hello_cpp hello_cpp.cpp)",
            }
        end
        if original_readfile then
            return original_readfile(path, ...)
        end
        return {}
    end

    local first
    local second
    with_project_parse_backend("cmake", function(cmd)
        local match_path = find_arg(cmd, "--match-path=")
        assert(cmd[4] == "--path=/tmp/cmakecache/CMakeLists.txt", "CMake parser should query the project file")
        if match_path == "/tmp/cmakecache/hello_c.c" then
            return {
                "TARGET\thello_c\t1",
                "COMMAND\tbuild\tcmake --build build",
                "COMMAND\trun\tcmake --build build --target hello_c && ./build/hello_c",
                "COMMAND\tcmake-build-hello_c\tcmake --build build --target hello_c",
                "COMMAND\tcmake-run-hello_c\tcmake --build build --target hello_c && ./build/hello_c",
                "PREFERRED\tbuild\tcmake --build build",
                "PRIMARY_TARGET\thello_c",
                "PREFERRED\trun\tcmake --build build --target hello_c && ./build/hello_c",
            }
        end
        if match_path == "/tmp/cmakecache/hello_cpp.cpp" then
            return {
                "TARGET\thello_cpp\t1",
                "COMMAND\tbuild\tcmake --build build",
                "COMMAND\trun\tcmake --build build --target hello_cpp && ./build/hello_cpp",
                "COMMAND\tcmake-build-hello_cpp\tcmake --build build --target hello_cpp",
                "COMMAND\tcmake-run-hello_cpp\tcmake --build build --target hello_cpp && ./build/hello_cpp",
                "PREFERRED\tbuild\tcmake --build build",
                "PRIMARY_TARGET\thello_cpp",
                "PREFERRED\trun\tcmake --build build --target hello_cpp && ./build/hello_cpp",
            }
        end
        return {}
    end, function()
        first = build.get_build_commands_for_filetype("cpp", "/tmp/cmakecache/hello_c.c")
        second = build.get_build_commands_for_filetype("cpp", "/tmp/cmakecache/hello_cpp.cpp")
    end)

    assert(first.run == first["cmake-run-hello_c"], "First CMake lookup should target hello_c")
    assert(second.run == second["cmake-run-hello_cpp"], "Second CMake lookup should target hello_cpp")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile

    print("✓ C++ CMake file-specific cache test passed")
end

---@return nil
local function test_cpp_meson_target_cache_is_file_specific()
    local build = require("zignite.build")
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    init.setup({})
    build.reset()
    vim.bo.filetype = "cpp"

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/mesoncache/hello_c.c" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/mesoncache/meson.build" or path == "/tmp/mesoncache/build/build.ninja" then
            return 1
        end
        return 0
    end
    vim.fn.readfile = function(path, ...)
        if path == "/tmp/mesoncache/meson.build" then
            return {
                "project('cache', 'c', 'cpp')",
                "executable('hello_c', 'hello_c.c')",
                "executable('hello_cpp', 'hello_cpp.cpp')",
            }
        end
        if original_readfile then
            return original_readfile(path, ...)
        end
        return {}
    end

    local first
    local second
    with_project_parse_backend("meson", function(cmd)
        local match_path = find_arg(cmd, "--match-path=")
        assert(cmd[4] == "--path=/tmp/mesoncache/meson.build", "Meson parser should query the project file")
        if match_path == "/tmp/mesoncache/hello_c.c" then
            return {
                "TARGET\thello_c\t1",
                "COMMAND\tbuild\tmeson compile -C build",
                "COMMAND\trun\tmeson compile -C build hello_c && ./build/hello_c",
                "COMMAND\tmeson-build-hello_c\tmeson compile -C build hello_c",
                "COMMAND\tmeson-run-hello_c\tmeson compile -C build hello_c && ./build/hello_c",
                "PREFERRED\tbuild\tmeson compile -C build",
                "PRIMARY_TARGET\thello_c",
                "PREFERRED\trun\tmeson compile -C build hello_c && ./build/hello_c",
            }
        end
        if match_path == "/tmp/mesoncache/hello_cpp.cpp" then
            return {
                "TARGET\thello_cpp\t1",
                "COMMAND\tbuild\tmeson compile -C build",
                "COMMAND\trun\tmeson compile -C build hello_cpp && ./build/hello_cpp",
                "COMMAND\tmeson-build-hello_cpp\tmeson compile -C build hello_cpp",
                "COMMAND\tmeson-run-hello_cpp\tmeson compile -C build hello_cpp && ./build/hello_cpp",
                "PREFERRED\tbuild\tmeson compile -C build",
                "PRIMARY_TARGET\thello_cpp",
                "PREFERRED\trun\tmeson compile -C build hello_cpp && ./build/hello_cpp",
            }
        end
        return {}
    end, function()
        first = build.get_build_commands_for_filetype("cpp", "/tmp/mesoncache/hello_c.c")
        second = build.get_build_commands_for_filetype("cpp", "/tmp/mesoncache/hello_cpp.cpp")
    end)

    assert(first.run == first["meson-run-hello_c"], "First Meson lookup should target hello_c")
    assert(second.run == second["meson-run-hello_cpp"], "Second Meson lookup should target hello_cpp")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile

    print("✓ C++ Meson file-specific cache test passed")
end

test_cpp_make_project_filters_irrelevant_commands()
test_cpp_cmake_project_parses_targets_and_ignores_generated_makefiles()
test_cpp_cmake_project_bootstraps_missing_build_dir()
test_cpp_cmake_target_cache_is_file_specific()
test_cpp_meson_project_parses_targets()
test_cpp_meson_project_bootstraps_missing_build_dir()
test_cpp_meson_target_cache_is_file_specific()
