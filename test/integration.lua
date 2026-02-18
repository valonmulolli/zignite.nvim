-- Integration tests for zignite
-- These tests require a full Neovim environment

local project_root = arg[1] or "."
package.path = package.path .. ";" .. project_root .. "/lua/?.lua"
package.path = package.path .. ";" .. project_root .. "/lua/?/init.lua"
package.path = package.path .. ";" .. project_root .. "/test/?.lua"

-- Mock vim functions for testing
_G.vim = _G.vim or {}
vim.fn = vim.fn or {
    expand = function(path) return path end,
    fnamemodify = function(path, modifier)
        if modifier == ":h" then
            return path:gsub("/[^/]+$", "")
        elseif modifier == ":e" then
            return path:match("%.([^%.]+)$") or ""
        elseif modifier == ":t" then
            return path:match("([^/]+)$") or path
        elseif modifier == ":t:r" then
            local name = path:match("([^/]+)$") or path
            return name:gsub("%.([^%.]+)$", "")
        elseif modifier == ":." then
            return path
        end
        return path
    end,
    executable = function() return 1 end,
    shellescape = function(str) return str end,
    filereadable = function() return 0 end,
    strdisplaywidth = function(str) return #tostring(str) end,
}
vim.bo = vim.bo or { filetype = "python" }
vim.o = vim.o or { columns = 120, lines = 40 }
vim.tbl_isempty = vim.tbl_isempty or function(tbl) return next(tbl) == nil end
vim.tbl_contains = vim.tbl_contains or function(tbl, value)
    for _, v in ipairs(tbl) do
        if v == value then return true end
    end
    return false
end
vim.tbl_extend = vim.tbl_extend or function(behavior, ...)
    local result = {}
    for i = 1, select("#", ...) do
        local tbl = select(i, ...)
        for k, v in pairs(tbl) do
            if type(v) == "table" and type(result[k]) == "table" then
                result[k] = vim.tbl_extend(behavior, result[k], v)
            else
                result[k] = v
            end
        end
    end
    return result
end
vim.tbl_deep_extend = vim.tbl_deep_extend or function(behavior, ...)
    return vim.tbl_extend(behavior, ...)
end
vim.keymap = vim.keymap or { set = function() end }
vim.fs = vim.fs or {
    normalize = function(path) return path end,
    joinpath = function(a, b) return a .. "/" .. b end,
}
vim.loop = vim.loop or {
    new_timer = function()
        return {
            start = function() end,
            stop = function() end,
            close = function() end,
        }
    end,
}
vim.schedule_wrap = vim.schedule_wrap or function(func) return func end
vim.api = vim.api or {
    nvim_create_buf = function() return 1 end,
    nvim_buf_set_lines = function() end,
    nvim_buf_set_option = function() end,
    nvim_open_win = function() return 1 end,
    nvim_win_set_option = function() end,
    nvim_win_close = function() end,
    nvim_buf_is_valid = function() return true end,
    nvim_win_is_valid = function() return true end,
    nvim_win_get_buf = function() return 1 end,
    nvim_buf_get_lines = function() return {} end,
    nvim_get_current_win = function() return 1 end,
    nvim_win_set_buf = function() end,
    nvim_win_set_height = function() end,
    nvim_buf_set_keymap = function() end,
    nvim_set_option_value = function() end,
    nvim_win_set_cursor = function() end,
    nvim_win_set_config = function() end,
    nvim_buf_line_count = function() return 0 end,
    nvim_create_namespace = function() return 1 end,
    nvim_buf_clear_namespace = function() end,
    nvim_win_get_cursor = function() return { 1, 0 } end,
    nvim_buf_set_extmark = function() end,
    nvim_buf_delete = function() end,
    nvim_create_user_command = function() end,
    nvim_buf_get_text = function() return {"test"} end,
    nvim_getpos = function() return {0, 1, 1, 0} end
}
vim.split = function(str, sep) return {str} end
vim.defer_fn = function(func, delay)
    func()
end

-- Mock vim.fn.jobstart for testing
local original_jobstart = vim.fn.jobstart
local job_results = {}
local quickfix_results = {}
local notify_results = {}
local next_exit_code = 0

vim.fn.jobstart = function(cmd, opts)
    table.insert(job_results, {cmd = cmd, opts = opts})
    -- Simulate execution with configurable exit code
    if opts.on_exit then
        local exit_code = next_exit_code
        vim.defer_fn(function() opts.on_exit(nil, exit_code) end, 10)
    end
    return 123
end

vim.fn.setqflist = function(_, _, qf_opts)
    table.insert(quickfix_results, qf_opts)
end

-- Mock vim.cmd
vim.cmd = function() end

-- Mock vim.schedule
vim.schedule = function(func) func() end

-- Mock vim.log.levels
vim.log = { levels = { INFO = 1, WARN = 2, ERROR = 3 } }

-- Mock vim.notify
vim.notify = function(msg, level, opts)
    table.insert(notify_results, { msg = tostring(msg), level = level, opts = opts })
end

local config = require('zignite.config')
local init = require('zignite.init')

local function command_to_string(cmd)
    if type(cmd) == "table" then
        return table.concat(cmd, " ")
    end
    return cmd or ""
end

local function reset_job_results()
    job_results = {}
end

local function reset_quickfix_results()
    quickfix_results = {}
end

local function reset_notify_results()
    notify_results = {}
end

-- Test basic command execution
local function test_basic_execution()
    config.setup({ mode = "float" })

    -- Mock vim.bo.filetype and vim.fn.expand
    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/test.py" end
        return original_expand(expr)
    end

    -- Run the code
    init.run_code(0, "float")

    -- Check that job was started
    assert(#job_results > 0, "Job was not started")
    local last_job = job_results[#job_results]
    local command = command_to_string(last_job.cmd)
    assert(command:match("%-%-argv"), "Expected argv mode for simple runner command")
    assert(command:match("python3"), "Python command not executed")

    -- Restore
    vim.fn.expand = original_expand
    reset_job_results()

    print("✓ Basic execution test passed")
end

-- Test complex runner keeps shell mode (no --argv)
local function test_complex_runner_uses_shell_mode()
    config.setup({ mode = "float" })

    vim.bo.filetype = "javascript"
    local original_expand = vim.fn.expand
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/js/main.js" end
        return original_expand(expr)
    end

    init.run_code(0, "float")

    assert(#job_results > 0, "JavaScript job was not started")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(not command:match("%-%-argv"), "Complex command should remain shell mode")
    assert(command:match("&&"), "Expected shell command chain for javascript runner")

    vim.fn.expand = original_expand
    reset_job_results()

    print("✓ Complex runner shell-mode test passed")
end

-- Test project detection
local function test_project_execution()
    config.setup({
        project = {
            ["/tmp/test/.*"] = { name = "Test Project", command = "echo hello" }
        }
    })

    vim.bo.filetype = "plain"
    local original_expand = vim.fn.expand
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/test/main.py" end
        return original_expand(expr)
    end

    init.run_project("float")

    assert(#job_results > 0, "Project job was not started")
    local last_job = job_results[#job_results]
    local command = command_to_string(last_job.cmd)
    assert(command:match("echo hello"), "Project command not executed")
    assert(command:match("%-%-argv"), "Project command should use argv mode for simple commands")
    assert(not command:match("cd "), "Project command should not rely on shell cd chaining")
    assert(last_job.opts and last_job.opts.cwd == "/tmp/test", "Project command should execute with project cwd")

    -- Restore
    vim.fn.expand = original_expand
    reset_job_results()

    print("✓ Project execution test passed")
end

-- Test build command execution uses cwd and argv mode for simple commands.
local function test_build_command_uses_cwd()
    config.setup({
        build_commands = {
            python = {
                run = "python3 $file",
            },
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/buildproj/main.py" end
        return original_expand(expr)
    end

    init.run_build_command("run", "float")

    assert(#job_results > 0, "Build command job was not started")
    local last_job = job_results[#job_results]
    local command = command_to_string(last_job.cmd)
    assert(command:match("%-%-argv"), "Build command should use argv mode for simple commands")
    assert(command:match("python3"), "Build command should include python3")
    assert(not command:match("cd "), "Build command should not rely on shell cd chaining")
    assert(last_job.opts and last_job.opts.cwd == "/tmp/buildproj", "Build command should execute in file directory cwd")

    vim.fn.expand = original_expand
    reset_job_results()

    print("✓ Build command cwd test passed")
end

-- Test quickfix generation on non-zero exits strips ANSI and tails lines.
local function test_quickfix_on_error()
    config.setup({
        mode = "float",
        quickfix = {
            enabled = true,
            max_lines = 2,
            strip_ansi = true,
            async_strip = true,
            strip_chunk_size = 1,
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    local original_line_count = vim.api.nvim_buf_line_count
    local original_get_lines = vim.api.nvim_buf_get_lines
    local test_lines = {
        "line-1",
        "\27[31merror-2\27[0m",
        "\27[33merror-3\27[0m",
    }

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/qf/main.py" end
        return original_expand(expr)
    end
    vim.api.nvim_buf_line_count = function() return #test_lines end
    vim.api.nvim_buf_get_lines = function(_, start_idx, _, _)
        local out = {}
        for i = start_idx + 1, #test_lines do
            table.insert(out, test_lines[i])
        end
        return out
    end

    next_exit_code = 1
    init.run_code(0, "float")

    assert(#quickfix_results > 0, "Quickfix should be populated on non-zero exit")
    local qf = quickfix_results[#quickfix_results]
    assert(#qf.lines == 2, "Quickfix should be capped to max_lines")
    assert(not qf.lines[1]:match("\27"), "Quickfix line should be ANSI-stripped")
    assert(not qf.lines[2]:match("\27"), "Quickfix line should be ANSI-stripped")

    next_exit_code = 0
    vim.fn.expand = original_expand
    vim.api.nvim_buf_line_count = original_line_count
    vim.api.nvim_buf_get_lines = original_get_lines
    reset_job_results()
    reset_quickfix_results()

    print("✓ Quickfix error-path test passed")
end

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

-- Test misconfigured runner command using reserved --argv fails fast with a clear error.
local function test_reserved_argv_runner_guard()
    config.setup({
        runners = {
            python = "--argv python3 $file",
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/argv_guard/main.py" end
        return original_expand(expr)
    end
    reset_job_results()
    reset_notify_results()

    init.run_code(0, "float")

    assert(#job_results == 0, "Reserved --argv runner should not start a job")
    assert(#notify_results > 0, "Reserved --argv runner should notify")
    assert(notify_results[#notify_results].msg:match("%-%-argv"), "Reserved --argv error should mention --argv")

    vim.fn.expand = original_expand
    reset_notify_results()

    print("✓ Reserved argv runner guard test passed")
end

-- Test misconfigured build command using reserved --argv fails fast with a clear error.
local function test_reserved_argv_build_guard()
    config.setup({
        build_commands = {
            python = {
                run = "--argv python3 $file",
            },
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/argv_guard/main.py" end
        return original_expand(expr)
    end
    reset_job_results()
    reset_notify_results()

    init.run_build_command("run", "float")

    assert(#job_results == 0, "Reserved --argv build command should not start a job")
    assert(#notify_results > 0, "Reserved --argv build command should notify")
    assert(notify_results[#notify_results].msg:match("%-%-argv"), "Reserved --argv build error should mention --argv")

    vim.fn.expand = original_expand
    reset_notify_results()

    print("✓ Reserved argv build guard test passed")
end

-- Test standalone Zig fallback (no build.zig -> zig run $file)
local function test_zig_standalone_fallback()
    config.setup({
        runners = {
            zig = "zig build run",
        },
    })

    vim.bo.filetype = "zig"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/standalone/main.zig" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function() return 0 end

    init.run_code(0, "float")

    assert(#job_results > 0, "Standalone Zig job was not started")
    local last_job = job_results[#job_results]
    local command = command_to_string(last_job.cmd)
    assert(command:match("zig run"), "Standalone Zig should use zig run")
    assert(not command:match("zig build run"), "Standalone Zig should not use zig build run")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    reset_job_results()

    print("✓ Zig standalone fallback test passed")
end

-- Test Zig project behavior for :RunFile (build-system should win)
local function test_zig_project_runfile()
    config.setup({ mode = "float" })

    vim.bo.filetype = "zig"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/build-system/src/main.zig" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        return path == "/tmp/build-system/build.zig" and 1 or 0
    end

    init.run_code(0, "float")

    assert(#job_results > 0, "Zig project job was not started")
    local last_job = job_results[#job_results]
    local command = command_to_string(last_job.cmd)
    assert(command:match("zig build run"), "Zig project :RunFile should use zig build run")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    reset_job_results()

    print("✓ Zig project RunFile test passed")
end

-- Test precedence: RunFile keeps filetype runner, RunProject uses project command.
local function test_runfile_vs_runproject_precedence()
    config.setup({
        project = {
            ["/tmp/app/.*"] = { name = "App Project", command = "echo project-cmd" },
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/app/src/main.py" end
        return original_expand(expr)
    end

    init.run_code(0, "float")
    assert(#job_results > 0, "RunFile job was not started")
    local runfile_cmd = command_to_string(job_results[#job_results].cmd)
    assert(runfile_cmd:match("python3"), "RunFile should prefer python filetype runner")
    assert(not runfile_cmd:match("project%-cmd"), "RunFile should not use project command in subdir when runner exists")

    reset_job_results()
    init.run_project("float")
    assert(#job_results > 0, "RunProject job was not started")
    local runproject_cmd = command_to_string(job_results[#job_results].cmd)
    assert(runproject_cmd:match("project%-cmd"), "RunProject should use project command")

    vim.fn.expand = original_expand
    reset_job_results()

	print("✓ RunFile vs RunProject precedence test passed")
end

-- Test Go RunFile in project root prefers filetype runner (single-file), not go run .
local function test_go_runfile_prefers_file_runner_at_root()
    config.setup({ mode = "float" })

    vim.bo.filetype = "go"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/goapp/main.go" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        return path == "/tmp/goapp/go.mod" and 1 or 0
    end

    init.run_code(0, "float")
    assert(#job_results > 0, "Go RunFile job was not started")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("go run /tmp/goapp/main%.go"), "Go RunFile should use single-file runner")
    assert(not command:match("go run %."), "Go RunFile should not use go run . at root")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    reset_job_results()

    print("✓ Go RunFile root-priority test passed")
end

-- Test Odin single-file mode uses -file to avoid package-wide main collisions.
local function test_odin_single_file_mode()
    config.setup({ mode = "float" })

    vim.bo.filetype = "odin"
    local original_expand = vim.fn.expand
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/odin/lesson.odin" end
        return original_expand(expr)
    end

    init.run_code(0, "float")
    assert(#job_results > 0, "Odin RunFile job was not started")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("odin run"), "Odin command should use odin run")
    assert(command:match("%-file"), "Odin RunFile should include -file flag")

    vim.fn.expand = original_expand
    reset_job_results()

    print("✓ Odin single-file mode test passed")
end

-- Run integration tests
test_basic_execution()
test_complex_runner_uses_shell_mode()
test_project_execution()
test_build_command_uses_cwd()
test_quickfix_on_error()
test_float_focus_behavior()
test_build_picker_empty_state()
test_build_picker_window_clamped()
test_build_picker_focus_behavior()
test_build_picker_focus_override()
test_reserved_argv_runner_guard()
test_reserved_argv_build_guard()
test_zig_standalone_fallback()
test_zig_project_runfile()
test_runfile_vs_runproject_precedence()
test_go_runfile_prefers_file_runner_at_root()
test_odin_single_file_mode()

-- Restore original jobstart
vim.fn.jobstart = original_jobstart

print("All integration tests passed!")
