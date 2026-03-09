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

    assert(type(mapped["/"]) == "function", "Picker should map '/' for filtering")
    assert(#latest_lines > 0, "Picker should render lines")
    assert(latest_lines[#latest_lines]:match("segment%-end"), "Picker preview should include full command text")

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

test_float_focus_behavior()
test_build_picker_empty_state()
test_build_picker_keeps_generic_commands_in_mixed_repo()
test_build_picker_window_clamped()
test_build_picker_focus_behavior()
test_build_picker_focus_override()
test_build_picker_filter_and_preview()
test_build_picker_filter_cmdline_mode()
test_build_picker_filter_inline_mode()
