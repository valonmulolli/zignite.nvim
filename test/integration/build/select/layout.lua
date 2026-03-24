-- luacheck: globals project_root config init ui state job_results quickfix_results notify_results mock_jobs
-- luacheck: globals command_to_string reset_job_results reset_quickfix_results reset_notify_results
-- luacheck: globals count_quickfix_backend_jobs count_quickfix_daemon_jobs
-- luacheck: globals count_detect_backend_jobs count_detect_backend_requests
-- luacheck: globals get_upvalue_by_name detect_backend_tool_commands is_detect_daemon_cmd parse_detect_daemon_request
-- luacheck: ignore 631

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

local function test_float_focus_behavior()
    local original_expand = vim.fn.expand
    local original_open_win = vim.api.nvim_open_win
    local original_cmd = vim.cmd
    local opened_enter = nil
    local opened_footer = nil
    local startinsert_calls = 0

    config.setup({
        mode = "float",
        float = {
            focus = false,
            startinsert = true,
            close_key = "<Esc>",
        },
    })

    vim.bo.filetype = "python"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/focus/main.py" end
        return original_expand(expr)
    end
    vim.api.nvim_open_win = function(_, enter, opts)
        opened_enter = enter
        opened_footer = opts and opts.footer or ""
        return 1
    end
    vim.cmd = function(cmd)
        if cmd == "startinsert" then
            startinsert_calls = startinsert_calls + 1
        end
    end

    init.run_code(0, "float")

    assert(opened_enter == false, "Float runner should respect float.focus=false")
    assert(startinsert_calls == 0, "Float runner should not startinsert when not focused")
    assert(opened_footer:match("Esc: close"), "Float footer should show configured close key")

    vim.fn.expand = original_expand
    vim.api.nvim_open_win = original_open_win
    vim.cmd = original_cmd
    reset_job_results()

    print("✓ Float focus behavior test passed")
end

-- Test picker warns and exits when filtering removes all build commands.
local function test_build_picker_empty_state()
    local original_expand = vim.fn.expand
    local original_open_win = vim.api.nvim_open_win
    local open_win_calls = 0

    config.setup({
        build_commands = {},
    })

    vim.bo.filetype = "testft"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/picker/main.testft" end
        return original_expand(expr)
    end
    vim.api.nvim_open_win = function(...)
        open_win_calls = open_win_calls + 1
        return original_open_win(...)
    end
    reset_notify_results()

    init.select_build_command("float")

    assert(open_win_calls == 0, "Picker should not open when no commands are available")
    assert(#notify_results > 0, "Picker should notify when command list is empty")
    assert(
        notify_results[#notify_results].msg:match("No build commands available"),
        "Picker empty warning should mention no build commands"
    )

    vim.fn.expand = original_expand
    vim.api.nvim_open_win = original_open_win
    reset_notify_results()

    print("✓ Build picker empty-state test passed")
end

-- Test non-C pickers keep generic commands visible even in mixed build-system repos.
local function test_build_picker_keeps_generic_commands_in_mixed_repo()
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local original_open_win = vim.api.nvim_open_win
    local rendered_lines = {}
    local open_win_calls = 0

    config.setup({
        build_commands = {
            testft = {
                run = "echo run",
                ["cmake-build"] = "cmake --build build",
            },
        },
    })

    vim.bo.filetype = "testft"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/mixed/main.testft" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        return path:match("CMakeLists.txt$") and 1 or 0
    end
    vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
        if type(lines) == "table" and #lines > 0 then
            rendered_lines = lines
        end
        if original_buf_set_lines then
            return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
        end
    end
    vim.api.nvim_open_win = function(...)
        open_win_calls = open_win_calls + 1
        return original_open_win(...)
    end

    init.select_build_command("float")

    local render = table.concat(rendered_lines, "\n")
    assert(open_win_calls > 0, "Picker should open when generic commands remain available")
    assert(render:match("run"), "Picker should keep generic commands visible in mixed repos")
    assert(render:match("cmake%-build"), "Picker should keep matching CMake commands visible")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    vim.api.nvim_open_win = original_open_win

    print("✓ Build picker mixed-repo generic command test passed")
end

-- Test picker window coordinates are clamped on very small editor sizes.
local function test_build_picker_window_clamped()
    local original_expand = vim.fn.expand
    local original_open_win = vim.api.nvim_open_win
    local original_columns = vim.o.columns
    local original_lines = vim.o.lines
    local captured_opts = nil

    config.setup({
        build_commands = {
            tinyft = {
                run = "echo tiny",
            },
        },
        float = {
            y = 0,
        },
    })

    vim.bo.filetype = "tinyft"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/picker/main.tinyft" end
        return original_expand(expr)
    end
    vim.o.columns = 2
    vim.o.lines = 4
    vim.api.nvim_open_win = function(_, _, opts)
        captured_opts = opts
        return 1
    end

    init.select_build_command("float")

    assert(captured_opts ~= nil, "Picker should open for available commands")
    assert(captured_opts.row >= 0, "Picker row should be clamped to non-negative values")
    assert(captured_opts.col >= 0, "Picker col should be clamped to non-negative values")

    vim.fn.expand = original_expand
    vim.api.nvim_open_win = original_open_win
    vim.o.columns = original_columns
    vim.o.lines = original_lines

    print("✓ Build picker clamp test passed")
end

-- Test build picker keeps focus by default (independent of float.focus).
local function test_build_picker_focus_behavior()
    local original_expand = vim.fn.expand
    local original_open_win = vim.api.nvim_open_win
    local opened_enter = nil

    config.setup({
        build_commands = {
            tinyft = {
                run = "echo tiny",
            },
        },
        float = {
            focus = false,
        },
    })

    vim.bo.filetype = "tinyft"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/picker/main.tinyft" end
        return original_expand(expr)
    end
    vim.api.nvim_open_win = function(_, enter, _)
        opened_enter = enter
        return 1
    end

    init.select_build_command("float")

    assert(opened_enter == true, "Build picker should focus by default even when float.focus=false")

    vim.fn.expand = original_expand
    vim.api.nvim_open_win = original_open_win

    print("✓ Build picker focus behavior test passed")
end

-- Test build picker can be explicitly unfocused via picker.focus=false.
local function test_build_picker_focus_override()
    local original_expand = vim.fn.expand
    local original_open_win = vim.api.nvim_open_win
    local opened_enter = nil

    config.setup({
        build_commands = {
            tinyft = {
                run = "echo tiny",
            },
        },
        picker = {
            focus = false,
        },
    })

    vim.bo.filetype = "tinyft"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/picker/main.tinyft" end
        return original_expand(expr)
    end
    vim.api.nvim_open_win = function(_, enter, _)
        opened_enter = enter
        return 1
    end

    init.select_build_command("float")

    assert(opened_enter == false, "Build picker should respect picker.focus=false")

    vim.fn.expand = original_expand
    vim.api.nvim_open_win = original_open_win

    print("✓ Build picker focus override test passed")
end

---@return nil
local function test_build_picker_hides_redundant_cmake_aliases()
    local original_expand = vim.fn.expand
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local original_open_win = vim.api.nvim_open_win
    local original_set_option_value = vim.api.nvim_set_option_value
    local rendered_lines = {}
    local wrap_disabled = false

    init.setup({})
    vim.bo.filetype = "cpp"

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/picker-cmake/src/main.cpp" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/picker-cmake/CMakeLists.txt" then
            return 1
        end
        if path == "/tmp/picker-cmake/build/CMakeCache.txt" then
            return 1
        end
        return 0
    end
    vim.fn.readfile = function(path, ...)
        if path == "/tmp/picker-cmake/CMakeLists.txt" then
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
    vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
        if type(lines) == "table" and #lines > 0 then
            rendered_lines = lines
        end
        if original_buf_set_lines then
            return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
        end
    end
    vim.api.nvim_open_win = function(...)
        return original_open_win(...)
    end
    vim.api.nvim_set_option_value = function(name, value, opts)
        if name == "wrap" and value == false and type(opts) == "table" and opts.win ~= nil then
            wrap_disabled = true
        end
        if original_set_option_value then
            return original_set_option_value(name, value, opts)
        end
    end

    with_project_parse_backend("c-family-auto", function(cmd)
        assert(cmd[4] == "--path=/tmp/picker-cmake/src/main.cpp", "Picker should query the current source path")
        return {
            "SYSTEM\tcmake",
            "ROOT\t/tmp/picker-cmake",
            "BUILD_READY\t1",
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
            "COMMAND\tcmake-build\tcmake --build build",
            "COMMAND\tcmake-run\tcmake --build build --target app && ./build/bin/app",
            "COMMAND\tbuild\tcmake --build build",
            "COMMAND\trun\tcmake --build build --target app && ./build/bin/app",
            "COMMAND\tcmake-build-app\tcmake --build build --target app",
            "COMMAND\tcmake-run-app\tcmake --build build --target app && ./build/bin/app",
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
    end, function()
        init.select_build_command("float")

        local render = table.concat(rendered_lines, "\n")
        assert(render:match("build"), "Picker should keep generic build alias")
        assert(render:match("cmake%-build%-app"), "Picker should keep target-specific CMake commands")
        assert(not render:match("cmake%-build%s"), "Picker should hide redundant cmake-build alias")
        assert(not render:match("cmake%-run%s"), "Picker should hide redundant cmake-run alias")
        assert(not render:match("cmake%-clean%s"), "Picker should hide redundant cmake-clean alias")
        assert(render:match("\n common\n") or render:match("^ common\n"), "Picker should render a common section")
        assert(render:match("\n targets\n"), "Picker should render a targets section")
        assert(render:match("\n profiles\n"), "Picker should render a profiles section")
        local common_pos = render:find("\n common\n", 1, true) or render:find("^ common\n")
        local targets_pos = render:find("\n targets\n", 1, true)
        local common_before_targets = common_pos and targets_pos and common_pos < targets_pos
        assert(common_before_targets, "Common commands should render before target commands")
        assert(wrap_disabled, "Picker should disable wrap to avoid broken command previews")
    end)

    vim.fn.expand = original_expand
    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    vim.api.nvim_open_win = original_open_win
    vim.api.nvim_set_option_value = original_set_option_value

    print("✓ Build picker CMake alias dedupe test passed")
end

---@return nil
local function test_build_picker_promotes_last_selected_command()
    local original_expand = vim.fn.expand
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local rendered_lines = {}

    config.setup({
        build_commands = {
            tinyft = {
                build = "echo build",
                run = "echo run",
                test = "echo test",
            },
        },
    })

    vim.bo.filetype = "tinyft"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/picker/main.tinyft" end
        return original_expand(expr)
    end
    vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
        rendered_lines = lines or {}
        if original_buf_set_lines then
            return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
        end
    end

    init.run_build_command("test", "float")
    init.select_build_command("float")

    local first_command = nil
    for _, line in ipairs(rendered_lines) do
        if type(line) == "string" and line:match("^  ") then
            first_command = line
            break
        end
    end
    assert(first_command and first_command:match("test"), "Picker should promote the last selected command to the top")

    vim.fn.expand = original_expand
    vim.api.nvim_buf_set_lines = original_buf_set_lines

    print("✓ Build picker last-selected ranking test passed")
end

---@return nil
local function test_build_picker_compact_layout_on_narrow_editor()
    local original_expand = vim.fn.expand
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local original_open_win = vim.api.nvim_open_win
    local original_columns = vim.o.columns
    local original_lines = vim.o.lines
    local rendered_lines = {}
    local opened_opts = nil

    config.setup({
        build_commands = {
            tinyft = {
                run = "echo run --with-extra-preview-text",
                ["very-long-target-name"] = "echo target --with-even-more-preview-text",
            },
        },
        picker = {
            layout = "auto",
            compact_breakpoint = 90,
        },
    })

    vim.bo.filetype = "tinyft"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/picker/main.tinyft" end
        return original_expand(expr)
    end
    vim.o.columns = 80
    vim.o.lines = 24
    vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
        rendered_lines = lines or {}
        if original_buf_set_lines then
            return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
        end
    end
    vim.api.nvim_open_win = function(buf, enter, opts)
        opened_opts = opts
        return original_open_win(buf, enter, opts)
    end

    init.select_build_command("float")

    local render = table.concat(rendered_lines, "\n")
    assert(opened_opts ~= nil, "Compact picker should still open a window")
    assert(opened_opts.title == " tinyft build ", "Compact picker should use the smaller build title")
    assert(render:match("^ cmd: ", 1) or render:match("\n cmd: "), "Compact picker should render command line")
    assert(not render:match("→"), "Compact picker should hide inline command previews on narrow screens")

    vim.fn.expand = original_expand
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    vim.api.nvim_open_win = original_open_win
    vim.o.columns = original_columns
    vim.o.lines = original_lines

    print("✓ Build picker compact layout test passed")
end

---@return nil
local function test_build_picker_wide_layout_stays_single_window()
    local original_expand = vim.fn.expand
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local original_open_win = vim.api.nvim_open_win
    local original_columns = vim.o.columns
    local original_lines = vim.o.lines
    local window_calls = {}
    local rendered_by_buf = {}

    config.setup({
        build_commands = {
            tinyft = {
                run = "echo run --with-wide-layout",
                ["very-long-target-name"] = "echo target --with-even-more-wide-layout-text",
            },
        },
        picker = {
            layout = "detailed",
        },
    })

    vim.bo.filetype = "tinyft"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/picker/main.tinyft" end
        return original_expand(expr)
    end
    vim.o.columns = 150
    vim.o.lines = 36
    vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
        rendered_by_buf[buf] = lines or {}
        if original_buf_set_lines then
            return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
        end
    end
    vim.api.nvim_open_win = function(buf, enter, opts)
        window_calls[#window_calls + 1] = { buf = buf, enter = enter, opts = opts }
        return original_open_win(buf, enter, opts)
    end

    init.select_build_command("float")

    assert(#window_calls == 1, "Wide picker should stay in a single window")

    local list_render = table.concat(rendered_by_buf[window_calls[1].buf] or {}, "\n")
    assert(list_render:match("→"), "Wide picker should keep inline command previews in detailed mode")
    local has_command_line = list_render:match("^ cmd: ", 1) or list_render:match("\n cmd: ")
    assert(has_command_line, "Wide picker should keep bottom command line")

    vim.fn.expand = original_expand
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    vim.api.nvim_open_win = original_open_win
    vim.o.columns = original_columns
    vim.o.lines = original_lines

    print("✓ Build picker wide layout test passed")
end


test_float_focus_behavior()
test_build_picker_empty_state()
test_build_picker_keeps_generic_commands_in_mixed_repo()
test_build_picker_window_clamped()
test_build_picker_focus_behavior()
test_build_picker_focus_override()
test_build_picker_hides_redundant_cmake_aliases()
test_build_picker_promotes_last_selected_command()
test_build_picker_compact_layout_on_narrow_editor()
test_build_picker_wide_layout_stays_single_window()
