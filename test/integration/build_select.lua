-- luacheck: globals project_root config init ui state job_results quickfix_results notify_results mock_jobs
-- luacheck: globals command_to_string reset_job_results reset_quickfix_results reset_notify_results
-- luacheck: globals count_quickfix_backend_jobs count_quickfix_daemon_jobs
-- luacheck: globals count_detect_backend_jobs count_detect_backend_requests
-- luacheck: globals get_upvalue_by_name detect_backend_tool_commands is_detect_daemon_cmd parse_detect_daemon_request

-- Test float focus=false keeps cursor in current window and avoids startinsert.
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
    local original_filereadable = vim.fn.filereadable
    local original_open_win = vim.api.nvim_open_win
    local open_win_calls = 0

    config.setup({
        build_commands = {
            testft = {
                ["meson-build"] = "meson compile -C build",
            },
        },
    })

    vim.bo.filetype = "testft"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/picker/main.testft" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        return path:match("CMakeLists.txt$") and 1 or 0
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
    vim.fn.filereadable = original_filereadable
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

    vim.fn.expand = original_expand
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

-- Test build picker supports filter prompt and full command preview line.
local function test_build_picker_filter_and_preview()
    local original_expand = vim.fn.expand
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local original_keymap = vim.keymap
    local original_input = vim.fn.input
    local mapped = {}
    local latest_lines = {}
    local next_input = "run"

    config.setup({
        build_commands = {
            tinyft = {
                ["aaa-long"] = "echo very-long-command-preview-segment-end",
                run = "echo run",
            },
        },
    })

    vim.bo.filetype = "tinyft"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/picker/main.tinyft" end
        return original_expand(expr)
    end
    vim.fn.input = function(_, default)
        return next_input or default
    end
    vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
        latest_lines = lines or {}
        if original_buf_set_lines then
            return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
        end
    end
    vim.keymap = {
        set = function(_, lhs, rhs, _opts)
            mapped[lhs] = rhs
        end,
    }

    init.select_build_command("float")

    assert(type(mapped["j"]) == "function", "Picker should map 'j' for navigation")
    assert(type(mapped["/"]) == "function", "Picker should map '/' for filtering")
    assert(#latest_lines > 0, "Picker should render lines")
    mapped["j"]()
    local preview_line = nil
    for _, line in ipairs(latest_lines) do
        if type(line) == "string" and line:match("^ cmd: ") then
            preview_line = line
            break
        end
    end
    assert(preview_line and preview_line:match("segment%-end"), "Picker preview should include full command text")

    mapped["/"]()
    assert(latest_lines[1]:match("Filter:%s+run"), "Picker should update filter header after '/' input")

    vim.fn.expand = original_expand
    vim.fn.input = original_input
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    vim.keymap = original_keymap

    print("✓ Build picker filter/preview test passed")
end

-- Test picker can force filter prompt to command-line input even when vim.ui.input exists.
local function test_build_picker_filter_cmdline_mode()
    local original_expand = vim.fn.expand
    local original_keymap = vim.keymap
    local original_input = vim.fn.input
    local original_ui = vim.ui
    local mapped = {}
    local cmdline_calls = 0
    local ui_calls = 0

    config.setup({
        build_commands = {
            tinyft = {
                run = "echo run",
                test = "echo test",
            },
        },
        picker = {
            filter_input = "cmdline",
        },
    })

    vim.bo.filetype = "tinyft"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/picker/main.tinyft" end
        return original_expand(expr)
    end
    vim.fn.input = function(_, default)
        cmdline_calls = cmdline_calls + 1
        return default or ""
    end
    vim.ui = {
        input = function(_, cb)
            ui_calls = ui_calls + 1
            if cb then
                cb("")
            end
        end,
    }
    vim.keymap = {
        set = function(_, lhs, rhs, _opts)
            mapped[lhs] = rhs
        end,
    }

    init.select_build_command("float")

    assert(type(mapped["/"]) == "function", "Picker should map '/' for filtering")
    mapped["/"]()
    assert(cmdline_calls == 1, "Picker should use vim.fn.input when picker.filter_input='cmdline'")
    assert(ui_calls == 0, "Picker should not call vim.ui.input when picker.filter_input='cmdline'")

    vim.fn.expand = original_expand
    vim.fn.input = original_input
    vim.ui = original_ui
    vim.keymap = original_keymap

    print("✓ Build picker cmdline filter mode test passed")
end

-- Test picker inline filter mode captures text in-picker without ui/cmdline prompts.
local function test_build_picker_filter_inline_mode()
    local original_expand = vim.fn.expand
    local original_keymap = vim.keymap
    local original_getcharstr = vim.fn.getcharstr
    local original_input = vim.fn.input
    local original_ui = vim.ui
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local mapped = {}
    local latest_lines = {}
    local cmdline_calls = 0
    local ui_calls = 0
    local idx = 1
    local keys = { "r", "u", "n", "\r" }

    config.setup({
        build_commands = {
            tinyft = {
                run = "echo run",
                test = "echo test",
            },
        },
        picker = {
            filter_input = "inline",
        },
    })

    vim.bo.filetype = "tinyft"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/picker/main.tinyft" end
        return original_expand(expr)
    end
    vim.fn.getcharstr = function()
        local key = keys[idx]
        idx = idx + 1
        return key
    end
    vim.fn.input = function(_, default)
        cmdline_calls = cmdline_calls + 1
        return default or ""
    end
    vim.ui = {
        input = function(_, cb)
            ui_calls = ui_calls + 1
            if cb then
                cb("")
            end
        end,
    }
    vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
        latest_lines = lines or {}
        if original_buf_set_lines then
            return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
        end
    end
    vim.keymap = {
        set = function(_, lhs, rhs, _opts)
            mapped[lhs] = rhs
        end,
    }

    init.select_build_command("float")

    assert(type(mapped["/"]) == "function", "Picker should map '/' for filtering")
    mapped["/"]()
    assert(latest_lines[1]:match("Filter:%s+run"), "Inline filter should update picker header query")
    assert(cmdline_calls == 0, "Inline filter should not use vim.fn.input")
    assert(ui_calls == 0, "Inline filter should not use vim.ui.input")

    vim.fn.expand = original_expand
    vim.fn.getcharstr = original_getcharstr
    vim.fn.input = original_input
    vim.ui = original_ui
	vim.api.nvim_buf_set_lines = original_buf_set_lines
	vim.keymap = original_keymap

	print("✓ Build picker inline filter mode test passed")
end

---@return nil
local function test_cpp_make_project_filters_irrelevant_commands()
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    init.setup({})
    vim.bo.filetype = "cpp"

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/makeproj/main.cpp" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/makeproj/Makefile" then
            return 1
        end
        return 0
    end
    vim.fn.readfile = function(path, ...)
        if path == "/tmp/makeproj/Makefile" then
            return {
                "main: main.cpp",
                "\t@echo build",
            }
        end
        if original_readfile then
            return original_readfile(path, ...)
        end
        return {}
    end

    local commands = init.get_build_commands_for_filetype("cpp")

    assert(commands.main == "make main", "Make project should expose parsed make target")
    assert(commands.build == "make", "Make project should keep generic make build alias")
    assert(commands["cmake-build"] == nil, "Make project should hide CMake-specific commands")
    assert(commands["meson-build"] == nil, "Make project should hide Meson-specific commands")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile

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

    local commands = init.get_build_commands_for_filetype("cpp")

    assert(
        commands["cmake-build-app"] == "cmake --build build --target app",
        "CMake target build command should be inferred"
    )
    assert(
        commands["cmake-run-app"] == "cmake --build build --target app && ./build/app",
        "CMake target run command should be inferred"
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

    local commands = init.get_build_commands_for_filetype("cpp")

    assert(
        commands["cmake-build"] == "cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
        "CMake build should bootstrap missing build dir"
    )
    assert(
        commands["cmake-run-app"]
            == "cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build --target app && ./build/app",
        "CMake target run should bootstrap missing build dir"
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

    local commands = init.get_build_commands_for_filetype("cpp")

    assert(
        commands["meson-build-demo-app"] == "meson compile -C build demo-app",
        "Meson target build command should be inferred"
    )
    assert(
        commands["meson-run-demo-app"] == "meson compile -C build demo-app && ./build/demo-app",
        "Meson target run command should be inferred"
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

    local commands = init.get_build_commands_for_filetype("cpp")

    assert(
        commands["meson-build"] == "meson setup build && meson compile -C build",
        "Meson build should bootstrap missing build dir"
    )
    assert(
        commands["meson-run-demo-app"] == "meson setup build && meson compile -C build demo-app && ./build/demo-app",
        "Meson target run should bootstrap missing build dir"
    )
    assert(commands.run == commands["meson-run-demo-app"], "Generic run should follow bootstrapped Meson target")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile

    print("✓ C++ Meson bootstrap test passed")
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
test_build_picker_filter_and_preview()
test_build_picker_filter_cmdline_mode()
test_build_picker_filter_inline_mode()
test_cpp_make_project_filters_irrelevant_commands()
test_cpp_cmake_project_parses_targets_and_ignores_generated_makefiles()
test_cpp_cmake_project_bootstraps_missing_build_dir()
test_cpp_meson_project_parses_targets()
test_cpp_meson_project_bootstraps_missing_build_dir()
