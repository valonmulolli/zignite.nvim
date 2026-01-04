-- Integration tests for zignite
-- These tests require a full Neovim environment

-- Mock vim functions for testing
_G.vim = _G.vim or {}
vim.fn = vim.fn or {
    expand = function(path) return path end,
    fnamemodify = function(path, modifier)
        if modifier == ":e" then
            return path:match("%.([^%.]+)$") or ""
        end
        return path
    end,
    executable = function() return 1 end,
    shellescape = function(str) return str end,
    filereadable = function() return 0 end
}
vim.bo = vim.bo or { filetype = "python" }
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
    assert(last_job.cmd:match("python3"), "Python command not executed")

    -- Restore
    vim.fn.expand = original_expand
    job_results = {}

    print("✓ Basic execution test passed")
end

-- Test project detection
local function test_project_execution()
    config.setup({
        project = {
            ["/tmp/test/.*"] = { name = "Test Project", command = "echo hello" }
        }
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/test/main.py" end
        return original_expand(expr)
    end

    init.run_project("float")

    assert(#job_results > 0, "Project job was not started")
    local last_job = job_results[#job_results]
    assert(last_job.cmd:match("echo hello"), "Project command not executed")

    -- Restore
    vim.fn.expand = original_expand
    job_results = {}

    print("✓ Project execution test passed")
end

-- Run integration tests
test_basic_execution()
test_project_execution()

-- Restore original jobstart
vim.fn.jobstart = original_jobstart

print("All integration tests passed!")