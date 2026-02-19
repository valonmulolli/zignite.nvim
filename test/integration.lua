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
local original_chansend = vim.fn.chansend
local original_chanclose = vim.fn.chanclose
local job_results = {}
local quickfix_results = {}
local notify_results = {}
local next_exit_code = 0
local next_quickfix_backend_exit_code = 0
local next_job_id = 123
local mock_jobs = {}
local quickfix_backend_invocations = 0

local function split_lines(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then
            table.insert(lines, line)
        end
    end
    return lines
end

local function parse_backend_flag(cmd, prefix, default)
    if type(cmd) ~= "table" then
        return default
    end
    for _, arg in ipairs(cmd) do
        if type(arg) == "string" and arg:sub(1, #prefix) == prefix then
            return arg:sub(#prefix + 1)
        end
    end
    return default
end

local function parse_backend_bool(cmd, prefix, default)
    local value = parse_backend_flag(cmd, prefix, nil)
    if value == nil then
        return default
    end
    return value == "1" or value == "true"
end

local function canonicalize_diag(line)
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^%-%->%s*", "")
    local path, row, col, msg = trimmed:match("^([^:]+):(%d+):(%d+):%s*(.+)$")
    if path and row and col then
        return string.format("%s:%d:%d: %s", path, tonumber(row), tonumber(col), msg ~= "" and msg or "diagnostic")
    end

    local path0, row0, col0 = trimmed:match("^([^:]+):(%d+):(%d+)$")
    if path0 and row0 and col0 then
        return string.format("%s:%d:%d: diagnostic", path0, tonumber(row0), tonumber(col0))
    end

    local path2, row2, msg2 = trimmed:match("^([^:]+):(%d+):%s*(.+)$")
    if path2 and row2 then
        return string.format("%s:%d:%d: %s", path2, tonumber(row2), 1, msg2 ~= "" and msg2 or "diagnostic")
    end

    local path3, row3, col3, msg3 = trimmed:match("^(.+)%((%d+):(%d+)%)%s*(.*)$")
    if path3 and row3 and col3 then
        local normalized = msg3 ~= "" and msg3 or "diagnostic"
        return string.format("%s:%d:%d: %s", path3, tonumber(row3), tonumber(col3), normalized)
    end

    return nil
end

local function simulate_quickfix_backend(input, cmd)
    local lines = split_lines(input or "")
    local max_lines = tonumber(parse_backend_flag(cmd, "--max-lines=", "1000")) or 1000
    local strip_ansi = parse_backend_bool(cmd, "--strip-ansi=", true)
    local strip_max_lines = tonumber(parse_backend_flag(cmd, "--strip-max-lines=", "400")) or 400
    local parse_diagnostics = parse_backend_bool(cmd, "--parse-diagnostics=", true)

    local truncated = #lines > max_lines
    if max_lines < 1 then
        max_lines = 1
    end
    if #lines > max_lines then
        local sliced = {}
        for i = #lines - max_lines + 1, #lines do
            table.insert(sliced, lines[i])
        end
        lines = sliced
    end

    if strip_ansi and strip_max_lines > 0 then
        local start_idx = math.max(1, #lines - strip_max_lines + 1)
        for i = start_idx, #lines do
            lines[i] = lines[i]:gsub("\27%[[0-9;]*m", "")
        end
    end

    if parse_diagnostics then
        for i = 1, #lines do
            local normalized = canonicalize_diag(lines[i])
            if normalized then
                lines[i] = normalized
            end
        end
    end

    if truncated then
        table.insert(lines, 1, "[zignite] quickfix output truncated")
    end

    return lines
end

local function is_quickfix_daemon_cmd(cmd)
    if type(cmd) ~= "table" then
        return false
    end
    for _, arg in ipairs(cmd) do
        if arg == "--quickfix-daemon" then
            return true
        end
    end
    return false
end

local function is_quickfix_backend_cmd(cmd)
    if type(cmd) ~= "table" then
        return false
    end
    for _, arg in ipairs(cmd) do
        if arg == "--quickfix" or arg == "--quickfix-daemon" then
            return true
        end
    end
    return false
end

local function parse_daemon_request(request_text)
    local req_lines = split_lines(request_text or "")
    if #req_lines < 2 then
        return nil
    end

    local begin_line = req_lines[1]
    local request_id, max_lines, max_bytes, strip_ansi, strip_max_lines, parse_diagnostics =
        begin_line:match("^@@ZQF_BEGIN%s+(%d+)%s+(%d+)%s+(%d+)%s+([01])%s+(%d+)%s+([01])$")
    if not request_id then
        return nil
    end

    local end_line = req_lines[#req_lines]
    local end_id = end_line:match("^@@ZQF_END%s+(%d+)$")
    if not end_id or tonumber(end_id) ~= tonumber(request_id) then
        return nil
    end

    local payload_lines = {}
    for i = 2, #req_lines - 1 do
        local line = req_lines[i]
        if line:sub(1, 1) == "\t" then
            payload_lines[#payload_lines + 1] = line:sub(2)
        else
            payload_lines[#payload_lines + 1] = line
        end
    end

    local cmd = {
        "--quickfix",
        "--max-lines=" .. max_lines,
        "--max-bytes=" .. max_bytes,
        "--strip-ansi=" .. strip_ansi,
        "--strip-max-lines=" .. strip_max_lines,
        "--parse-diagnostics=" .. parse_diagnostics,
    }

    local backend_lines = simulate_quickfix_backend(table.concat(payload_lines, "\n"), cmd)
    local response = { "@@ZQF_RES_BEGIN " .. request_id }
    for _, line in ipairs(backend_lines) do
        response[#response + 1] = "\t" .. line
    end
    response[#response + 1] = "@@ZQF_RES_END " .. request_id
    return response
end

vim.fn.jobstart = function(cmd, opts)
    local job_id = next_job_id
    next_job_id = next_job_id + 1
    table.insert(job_results, {cmd = cmd, opts = opts, job_id = job_id})
    mock_jobs[job_id] = { cmd = cmd, opts = opts, input = "" }

    if is_quickfix_backend_cmd(cmd) then
        return job_id
    end

    if opts.on_exit then
        local exit_code = next_exit_code
        vim.defer_fn(function() opts.on_exit(job_id, exit_code) end, 10)
    end
    return job_id
end

vim.fn.chansend = function(job_id, data)
    local job = mock_jobs[job_id]
    if not job then
        return 0
    end

    if is_quickfix_daemon_cmd(job.cmd) then
        if next_quickfix_backend_exit_code ~= 0 then
            local exit_code = next_quickfix_backend_exit_code
            next_quickfix_backend_exit_code = 0
            if job.opts and job.opts.on_exit then
                vim.defer_fn(function() job.opts.on_exit(job_id, exit_code) end, 10)
            end
            return 1
        end

        local text = type(data) == "table" and table.concat(data) or tostring(data or "")
        local response = parse_daemon_request(text)
        if response and job.opts and job.opts.on_stdout then
            quickfix_backend_invocations = quickfix_backend_invocations + 1
            vim.defer_fn(function() job.opts.on_stdout(job_id, response) end, 10)
        end
        return 1
    end

    if type(data) == "table" then
        for _, part in ipairs(data) do
            job.input = job.input .. tostring(part)
        end
    else
        job.input = job.input .. tostring(data or "")
    end
    return 1
end

vim.fn.chanclose = function(job_id, stream)
    local job = mock_jobs[job_id]
    if not job or stream ~= "stdin" or not is_quickfix_backend_cmd(job.cmd) then
        return 0
    end

    if next_quickfix_backend_exit_code ~= 0 then
        local exit_code = next_quickfix_backend_exit_code
        next_quickfix_backend_exit_code = 0
        if job.opts and job.opts.on_exit then
            vim.defer_fn(function() job.opts.on_exit(job_id, exit_code) end, 10)
        end
        return 1
    end

    local lines = simulate_quickfix_backend(job.input, job.cmd)
    if job.opts and job.opts.on_stdout then
        quickfix_backend_invocations = quickfix_backend_invocations + 1
        vim.defer_fn(function() job.opts.on_stdout(job_id, lines) end, 10)
    end
    if job.opts and job.opts.on_exit then
        vim.defer_fn(function() job.opts.on_exit(job_id, 0) end, 10)
    end
    return 1
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
local ui = require('zignite.ui')

local function command_to_string(cmd)
    if type(cmd) == "table" then
        return table.concat(cmd, " ")
    end
    return cmd or ""
end

local function reset_job_results()
    job_results = {}
    quickfix_backend_invocations = 0
end

local function reset_quickfix_results()
    quickfix_results = {}
end

local function reset_notify_results()
    notify_results = {}
end

local function count_quickfix_backend_jobs()
    return quickfix_backend_invocations
end

local function count_quickfix_daemon_jobs()
    local count = 0
    for _, job in ipairs(job_results) do
        if is_quickfix_daemon_cmd(job.cmd) then
            count = count + 1
        end
    end
    return count
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

-- Test interpreted default runner uses argv mode (no shell chaining).
local function test_interpreted_runner_uses_argv_mode()
    config.setup({ mode = "float" })

    local original_expand = vim.fn.expand
    local cases = {
        { filetype = "javascript", path = "/tmp/js/main.js", token = "node" },
        { filetype = "typescript", path = "/tmp/ts/main.ts", token = "bun" },
        { filetype = "lua", path = "/tmp/lua/main.lua", token = "lua" },
        { filetype = "sh", path = "/tmp/sh/main.sh", token = "bash" },
        { filetype = "zsh", path = "/tmp/zsh/main.zsh", token = "zsh" },
    }

    for _, case in ipairs(cases) do
        vim.bo.filetype = case.filetype
        vim.fn.expand = function(expr)
            if expr == "%:p" then return case.path end
            return original_expand(expr)
        end

        init.run_code(0, "float")

        assert(#job_results > 0, case.filetype .. " job was not started")
        local command = command_to_string(job_results[#job_results].cmd)
        assert(command:match("%-%-argv"), case.filetype .. " default runner should use argv mode")
        assert(command:match(case.token), "Expected " .. case.token .. " in " .. case.filetype .. " runner command")
        assert(not command:match("&&"), case.filetype .. " runner should not use shell command chains by default")
        reset_job_results()
    end

    vim.fn.expand = original_expand

    print("✓ Interpreted runner argv-mode test passed")
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

-- Test Lua quickfix generation on non-zero exits strips ANSI and tails lines.
local function test_quickfix_on_error_lua_processor()
    config.setup({
        mode = "float",
        quickfix = {
            enabled = true,
            processor = "lua",
            max_lines = 2,
            max_bytes = 1024,
            strip_ansi = true,
            strip_ansi_max_lines = 2,
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
    assert(#qf.lines == 3, "Quickfix should include truncation notice plus tailed lines")
    assert(qf.lines[1] == "[zignite] quickfix output truncated", "Quickfix should include truncation notice")
    assert(not qf.lines[2]:match("\27"), "Quickfix line should be ANSI-stripped")
    assert(not qf.lines[3]:match("\27"), "Quickfix line should be ANSI-stripped")
    assert(count_quickfix_backend_jobs() == 0, "Lua processor should not spawn zig quickfix backend")

    next_exit_code = 0
    vim.fn.expand = original_expand
    vim.api.nvim_buf_line_count = original_line_count
    vim.api.nvim_buf_get_lines = original_get_lines
    reset_job_results()
    reset_quickfix_results()

    print("✓ Quickfix Lua processor test passed")
end

-- Test explicit zig processor path is used for quickfix generation.
local function test_quickfix_zig_processor()
    config.setup({
        mode = "float",
        quickfix = {
            enabled = true,
            processor = "zig",
            max_lines = 2,
            max_bytes = 1024,
            strip_ansi = true,
            strip_ansi_max_lines = 2,
            parse_diagnostics = false,
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

    assert(count_quickfix_daemon_jobs() > 0, "Zig processor should start quickfix daemon worker")
    assert(count_quickfix_backend_jobs() > 0, "Zig processor should spawn quickfix backend")
    assert(#quickfix_results > 0, "Quickfix should be populated on zig processor path")
    local qf = quickfix_results[#quickfix_results]
    assert(qf.lines[1] == "[zignite] quickfix output truncated", "Zig quickfix should include truncation notice")
    assert(qf.lines[2] == "error-2", "Zig processor should strip ANSI from retained lines")
    assert(qf.lines[3] == "error-3", "Zig processor should strip ANSI from retained lines")

    next_exit_code = 0
    vim.fn.expand = original_expand
    vim.api.nvim_buf_line_count = original_line_count
    vim.api.nvim_buf_get_lines = original_get_lines
    reset_job_results()
    reset_quickfix_results()

    print("✓ Quickfix zig processor test passed")
end

-- Test auto processor routes to Lua below threshold and Zig above threshold.
local function test_quickfix_auto_threshold_behavior()
    local original_expand = vim.fn.expand
    local original_line_count = vim.api.nvim_buf_line_count
    local original_get_lines = vim.api.nvim_buf_get_lines

    vim.bo.filetype = "python"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/qf/main.py" end
        return original_expand(expr)
    end

    config.setup({
        mode = "float",
        quickfix = {
            enabled = true,
            processor = "auto",
            zig_min_lines = 5,
            max_lines = 5,
            strip_ansi = true,
            strip_ansi_max_lines = 5,
            parse_diagnostics = false,
        },
    })

    local small_lines = {
        "line-1",
        "\27[31mline-2\27[0m",
        "line-3",
    }
    vim.api.nvim_buf_line_count = function() return #small_lines end
    vim.api.nvim_buf_get_lines = function(_, start_idx, _, _)
        local out = {}
        for i = start_idx + 1, #small_lines do
            table.insert(out, small_lines[i])
        end
        return out
    end

    next_exit_code = 1
    init.run_code(0, "float")
    assert(count_quickfix_backend_jobs() == 0, "Auto mode should use Lua processor below threshold")

    reset_job_results()
    reset_quickfix_results()

    local large_lines = {}
    for i = 1, 8 do
        large_lines[i] = string.format("\27[31mline-%d\27[0m", i)
    end
    vim.api.nvim_buf_line_count = function() return #large_lines end
    vim.api.nvim_buf_get_lines = function(_, start_idx, _, _)
        local out = {}
        for i = start_idx + 1, #large_lines do
            table.insert(out, large_lines[i])
        end
        return out
    end

    init.run_code(0, "float")
    assert(count_quickfix_backend_jobs() > 0, "Auto mode should use zig processor above threshold")

    next_exit_code = 0
    vim.fn.expand = original_expand
    vim.api.nvim_buf_line_count = original_line_count
    vim.api.nvim_buf_get_lines = original_get_lines
    reset_job_results()
    reset_quickfix_results()

    print("✓ Quickfix auto threshold test passed")
end

-- Test zig quickfix processor falls back to Lua when zig backend fails.
local function test_quickfix_zig_fallback()
    config.setup({
        mode = "float",
        quickfix = {
            enabled = true,
            processor = "zig",
            max_lines = 2,
            strip_ansi = true,
            strip_ansi_max_lines = 2,
            parse_diagnostics = false,
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

    next_quickfix_backend_exit_code = 1
    next_exit_code = 1
    init.run_code(0, "float")

    assert(#quickfix_results > 0, "Lua fallback should populate quickfix after zig failure")
    local qf = quickfix_results[#quickfix_results]
    assert(not qf.lines[1]:match("\27"), "Lua fallback should still strip ANSI codes")

    next_exit_code = 0
    vim.fn.expand = original_expand
    vim.api.nvim_buf_line_count = original_line_count
    vim.api.nvim_buf_get_lines = original_get_lines
    reset_job_results()
    reset_quickfix_results()

    print("✓ Quickfix zig fallback test passed")
end

-- Test zig diagnostic parser canonicalizes common compiler formats.
local function test_quickfix_zig_diagnostic_parser()
    config.setup({
        mode = "float",
        quickfix = {
            enabled = true,
            processor = "zig",
            max_lines = 5,
            strip_ansi = false,
            parse_diagnostics = true,
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    local original_line_count = vim.api.nvim_buf_line_count
    local original_get_lines = vim.api.nvim_buf_get_lines
    local test_lines = {
        "src/main.c:10:5: error: expected ';' after expression",
        " --> src/lib.rs:7:3",
        "/tmp/sample.odin(8:1) Error: Redeclaration of 'main'",
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

    assert(#quickfix_results > 0, "Zig diagnostic parser should populate quickfix lines")
    local qf = quickfix_results[#quickfix_results]
    assert(qf.lines[1]:match("^src/main%.c:10:5:"), "GCC/Clang diagnostic should be canonicalized")
    assert(qf.lines[2]:match("^src/lib%.rs:7:3:"), "Rust arrow diagnostic should be canonicalized")
    assert(qf.lines[3]:match("^/tmp/sample%.odin:8:1:"), "Paren diagnostics should be canonicalized")

    next_exit_code = 0
    vim.fn.expand = original_expand
    vim.api.nvim_buf_line_count = original_line_count
    vim.api.nvim_buf_get_lines = original_get_lines
    reset_job_results()
    reset_quickfix_results()

    print("✓ Quickfix zig diagnostic parser test passed")
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

-- Test :RunBuildLast behavior (warn before first run, then repeat latest command).
local function test_run_build_last_behavior()
    config.setup({
        build_commands = {
            lastft = {
                run = "echo run-last",
                test = "pytest -q",
            },
        },
    })

    vim.bo.filetype = "lastft"
    local original_expand = vim.fn.expand
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local output_messages = {}
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/last/main.py" end
        return original_expand(expr)
    end
    vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
        if type(lines) == "table" and #lines > 0 then
            table.insert(output_messages, table.concat(lines, "\n"))
        end
        if original_buf_set_lines then
            return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
        end
    end

    reset_job_results()
    init.run_last_build_command("float")
    assert(#job_results == 0, "RunBuildLast should not start job before any build command")
    assert(#output_messages > 0, "RunBuildLast should surface guidance before first selection")

    reset_job_results()
    init.run_build_command("test", "float")
    assert(#job_results > 0, "run_build_command(test) should start a job")

    reset_job_results()
    init.run_last_build_command("float")
    assert(#job_results > 0, "RunBuildLast should repeat previous build command")
    local repeated = command_to_string(job_results[#job_results].cmd)
    assert(repeated:match("pytest"), "RunBuildLast should repeat the latest command for filetype")

    vim.fn.expand = original_expand
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    reset_job_results()

    print("✓ RunBuildLast behavior test passed")
end

-- Test show_output respects split mode and renders in-window (not notify fallback).
local function test_show_output_respects_mode()
    config.setup({
        mode = "split",
        term = {
            position = "top",
            focus = true,
        },
    })

    local original_cmd = vim.cmd
    local issued_cmds = {}
    vim.cmd = function(cmd)
        table.insert(issued_cmds, cmd)
    end
    reset_notify_results()

    ui.show_output("Error: split mode output", "split")

    assert(#issued_cmds > 0, "show_output(split) should open a split window")
    assert(issued_cmds[1] == "topleft split", "show_output(split) should honor top split position")
    assert(#notify_results == 0, "show_output(split) should not fallback to notify")

    vim.cmd = original_cmd
    reset_notify_results()

    print("✓ show_output mode behavior test passed")
end

-- Test vsplit mode honors term.position=left.
local function test_vsplit_respects_left_position()
    config.setup({
        mode = "vsplit",
        term = {
            position = "left",
            focus = true,
            startinsert = false,
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    local original_cmd = vim.cmd
    local issued_cmds = {}

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/vsplit/main.py" end
        return original_expand(expr)
    end
    vim.cmd = function(cmd)
        table.insert(issued_cmds, cmd)
    end

    init.run_code(0, "vsplit")

    assert(#issued_cmds > 0, "vsplit run should issue split command")
    assert(issued_cmds[1] == "topleft vsplit", "vsplit should honor term.position=left")

    vim.fn.expand = original_expand
    vim.cmd = original_cmd
    reset_job_results()

    print("✓ vsplit left-position test passed")
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
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local output_messages = {}
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/argv_guard/main.py" end
        return original_expand(expr)
    end
    vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
        if type(lines) == "table" and #lines > 0 then
            table.insert(output_messages, table.concat(lines, "\n"))
        end
        if original_buf_set_lines then
            return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
        end
    end
    reset_job_results()
    reset_notify_results()

    init.run_code(0, "float")

    assert(#job_results == 0, "Reserved --argv runner should not start a job")
    assert(#notify_results > 0 or #output_messages > 0, "Reserved --argv runner should surface an error")
    local msg = (#notify_results > 0 and notify_results[#notify_results].msg) or output_messages[#output_messages] or ""
    assert(msg:match("%-%-argv"), "Reserved --argv error should mention --argv")

    vim.fn.expand = original_expand
    vim.api.nvim_buf_set_lines = original_buf_set_lines
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
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local output_messages = {}
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/argv_guard/main.py" end
        return original_expand(expr)
    end
    vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
        if type(lines) == "table" and #lines > 0 then
            table.insert(output_messages, table.concat(lines, "\n"))
        end
        if original_buf_set_lines then
            return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
        end
    end
    reset_job_results()
    reset_notify_results()

    init.run_build_command("run", "float")

    assert(#job_results == 0, "Reserved --argv build command should not start a job")
    assert(#notify_results > 0 or #output_messages > 0, "Reserved --argv build command should surface an error")
    local msg = (#notify_results > 0 and notify_results[#notify_results].msg) or output_messages[#output_messages] or ""
    assert(msg:match("%-%-argv"), "Reserved --argv build error should mention --argv")

    vim.fn.expand = original_expand
    vim.api.nvim_buf_set_lines = original_buf_set_lines
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
test_interpreted_runner_uses_argv_mode()
test_project_execution()
test_build_command_uses_cwd()
test_quickfix_on_error_lua_processor()
test_quickfix_zig_processor()
test_quickfix_auto_threshold_behavior()
test_quickfix_zig_fallback()
test_quickfix_zig_diagnostic_parser()
test_float_focus_behavior()
test_build_picker_empty_state()
test_build_picker_window_clamped()
test_build_picker_focus_behavior()
test_build_picker_focus_override()
test_build_picker_filter_and_preview()
test_run_build_last_behavior()
test_show_output_respects_mode()
test_vsplit_respects_left_position()
test_reserved_argv_runner_guard()
test_reserved_argv_build_guard()
test_zig_standalone_fallback()
test_zig_project_runfile()
test_runfile_vs_runproject_precedence()
test_go_runfile_prefers_file_runner_at_root()
test_odin_single_file_mode()

-- Restore original jobstart
vim.fn.jobstart = original_jobstart
vim.fn.chansend = original_chansend
vim.fn.chanclose = original_chanclose

print("All integration tests passed!")
