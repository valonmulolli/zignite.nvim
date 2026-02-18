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
    filereadable = function() return 0 end
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

vim.fn.jobstart = function(cmd, opts)
    table.insert(job_results, {cmd = cmd, opts = opts})
    -- Simulate successful execution
    if opts.on_exit then
        vim.defer_fn(function() opts.on_exit(nil, 0) end, 10)
    end
    return 123
end

-- Mock vim.cmd
vim.cmd = function() end

-- Mock vim.schedule
vim.schedule = function(func) func() end

-- Mock vim.log.levels
vim.log = { levels = { INFO = 1, WARN = 2, ERROR = 3 } }

-- Mock vim.notify
vim.notify = function() end

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
    assert(command:match("python3"), "Python command not executed")

    -- Restore
    vim.fn.expand = original_expand
    reset_job_results()

    print("✓ Basic execution test passed")
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

    -- Restore
    vim.fn.expand = original_expand
    reset_job_results()

    print("✓ Project execution test passed")
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
test_project_execution()
test_zig_standalone_fallback()
test_zig_project_runfile()
test_runfile_vs_runproject_precedence()
test_odin_single_file_mode()

-- Restore original jobstart
vim.fn.jobstart = original_jobstart

print("All integration tests passed!")
