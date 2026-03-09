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
    systemlist = function() return {} end,
    tempname = function() return os.tmpname() end,
    getpos = function() return { 0, 1, 1, 0 } end,
}
vim.v = vim.v or { shell_error = 0 }
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
    nvim_win_set_width = function() end,
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
vim.split = function(str, _sep) return { str } end
vim.defer_fn = function(func, _delay)
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
local next_detect_backend_exit_code = 0
local next_job_id = 123
local mock_jobs = {}
local quickfix_backend_invocations = 0
local detect_backend_invocations = 0
local detect_backend_request_count = 0
local detect_backend_tool_commands = {
    zig = { "build", "fmt", "fetch", "run" },
    go = { "build", "env", "fmt" },
    cargo = { "build", "check", "run" },
    odin = { "build", "run", "test" },
}

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
    local max_bytes = tonumber(parse_backend_flag(cmd, "--max-bytes=", "262144")) or 262144
    local strip_ansi = parse_backend_bool(cmd, "--strip-ansi=", true)
    local strip_max_lines = tonumber(parse_backend_flag(cmd, "--strip-max-lines=", "400")) or 400
    local parse_diagnostics = parse_backend_bool(cmd, "--parse-diagnostics=", true)

    if max_lines < 1 then
        max_lines = 1
    end
    if max_bytes < 1 then
        max_bytes = 1
    end

    local truncated = false
    local used = 0
    local start_idx = #lines + 1
    for i = #lines, 1, -1 do
        used = used + #lines[i] + 1
        if used > max_bytes then
            truncated = true
            break
        end
        start_idx = i
    end

    if #lines > 0 then
        if start_idx > #lines then
            lines = { lines[#lines] }
        elseif start_idx > 1 then
            local sliced = {}
            for i = start_idx, #lines do
                table.insert(sliced, lines[i])
            end
            lines = sliced
        end
    end

    if #lines > max_lines then
        truncated = true
        local sliced = {}
        for i = #lines - max_lines + 1, #lines do
            table.insert(sliced, lines[i])
        end
        lines = sliced
    end

    if strip_ansi and strip_max_lines > 0 then
        local strip_start_idx = math.max(1, #lines - strip_max_lines + 1)
        for i = strip_start_idx, #lines do
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

local function is_detect_daemon_cmd(cmd)
    if type(cmd) ~= "table" then
        return false
    end
    for _, arg in ipairs(cmd) do
        if arg == "--detect-daemon" then
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

local function parse_detect_daemon_request(request_text)
    local req_lines = split_lines(request_text or "")
    if #req_lines < 2 then
        return nil
    end

    local begin_line = req_lines[1]
    local request_id, tool = begin_line:match("^@@ZDET_REQ_BEGIN%s+(%d+)%s+([%w_%-]+)$")
    if not request_id or not tool then
        return nil
    end

    local end_line = req_lines[#req_lines]
    local end_id = end_line:match("^@@ZDET_REQ_END%s+(%d+)$")
    if not end_id or tonumber(end_id) ~= tonumber(request_id) then
        return nil
    end

    local response = { "@@ZDET_RES_BEGIN " .. request_id }
    local commands = detect_backend_tool_commands[tool] or {}
    for _, command in ipairs(commands) do
        response[#response + 1] = "\t" .. command
    end
    response[#response + 1] = "@@ZDET_RES_END " .. request_id
    return response
end

local function simulated_tool_help_output(cmd)
    if type(cmd) ~= "table" or type(cmd[1]) ~= "string" then
        return nil
    end

    if cmd[1] == "zig" and cmd[2] == "--help" then
        return {
            "Usage: zig [command] [options]",
            "",
            "Commands:",
            "",
            "  build            Build project from build.zig",
            "  fetch            Copy a package into global cache and print its hash",
            "  fmt              Reformat Zig source into canonical form",
            "  run              Create executable and run immediately",
            "",
            "General Options:",
            "  -h, --help       Print command-specific usage",
        }
    end

    if cmd[1] == "go" and cmd[2] == "help" then
        return {
            "The commands are:",
            "",
            "    build       compile packages and dependencies",
            "    env         print Go environment information",
            "    fmt         gofmt package sources",
            "",
            "Additional help topics:",
        }
    end

    if cmd[1] == "cargo" and cmd[2] == "--list" then
        return {
            "Installed Commands:",
            "    build      Compile a local package and all of its dependencies",
            "    check      Analyze the current package and report errors",
            "    run        Run a binary or example of the local package",
        }
    end

    if cmd[1] == "odin" and cmd[2] == "help" then
        return {
            "Commands:",
            "  build      Build an Odin package",
            "  run        Build and run an Odin package",
            "  test       Build and run tests for an Odin package",
            "Flags:",
        }
    end

    return nil
end

vim.fn.jobstart = function(cmd, opts)
    local job_id = next_job_id
    next_job_id = next_job_id + 1
    table.insert(job_results, {cmd = cmd, opts = opts, job_id = job_id})
    mock_jobs[job_id] = { cmd = cmd, opts = opts, input = "" }

    if is_quickfix_backend_cmd(cmd) or is_detect_daemon_cmd(cmd) then
        return job_id
    end

    local tool_lines = simulated_tool_help_output(cmd)
    if tool_lines then
        if opts.on_stdout then
            vim.defer_fn(function() opts.on_stdout(job_id, tool_lines) end, 10)
        end
        if opts.on_exit then
            local exit_code = next_exit_code
            vim.defer_fn(function() opts.on_exit(job_id, exit_code) end, 10)
        end
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

    if is_detect_daemon_cmd(job.cmd) then
        detect_backend_request_count = detect_backend_request_count + 1
        if next_detect_backend_exit_code ~= 0 then
            local exit_code = next_detect_backend_exit_code
            next_detect_backend_exit_code = 0
            if job.opts and job.opts.on_exit then
                vim.defer_fn(function() job.opts.on_exit(job_id, exit_code) end, 10)
            end
            return 1
        end

        local text = type(data) == "table" and table.concat(data) or tostring(data or "")
        local response = parse_detect_daemon_request(text)
        if response and job.opts and job.opts.on_stdout then
            detect_backend_invocations = detect_backend_invocations + 1
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
    detect_backend_invocations = 0
    detect_backend_request_count = 0
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

local function count_detect_backend_jobs()
    return detect_backend_invocations
end

local function count_detect_backend_requests()
    return detect_backend_request_count
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

-- Test visual RunCode temp files preserve a useful source extension.
local function test_visual_run_code_preserves_extension()
    config.setup({ mode = "float" })

    vim.bo.filetype = "typescript"
    local original_expand = vim.fn.expand
    local original_getpos = vim.fn.getpos
    local original_tempname = vim.fn.tempname
    local original_get_text = vim.api.nvim_buf_get_text

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/visual/main.ts" end
        return original_expand(expr)
    end
    vim.fn.tempname = function()
        return "/tmp/zignite-visual"
    end
    vim.fn.getpos = function()
        return { 0, 1, 0, 0 }
    end
    vim.api.nvim_buf_get_text = function()
        return { "console.log('ok')" }
    end

    reset_job_results()
    init.run_code(1, "float")

    assert(#job_results > 0, "Visual RunCode should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("/tmp/zignite%-visual%.ts"), "Visual RunCode temp file should preserve .ts extension")

    vim.fn.expand = original_expand
    vim.fn.getpos = original_getpos
    vim.fn.tempname = original_tempname
    vim.api.nvim_buf_get_text = original_get_text
    reset_job_results()

    print("✓ Visual RunCode temp extension test passed")
end

-- Test timeout-enabled runs go through zig wrapper (`--timeout` + `--argv`).
local function test_timeout_uses_zig_wrapper()
    config.setup({
        mode = "float",
        timeout = 5000,
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/timeout/main.py" end
        return original_expand(expr)
    end

    reset_job_results()
    init.run_code(0, "float")

    assert(#job_results > 0, "Timeout run job was not started")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("%-%-timeout=5000"), "Timeout run should include --timeout wrapper flag")
    assert(command:match("%-%-argv"), "Timeout run should include --argv wrapper mode")
    assert(command:match("python3"), "Timeout run should include python command payload")

    vim.fn.expand = original_expand
    reset_job_results()

    print("✓ Timeout wrapper runtime test passed")
end

-- Test filetype fallback by extension when vim.bo.filetype is empty.
local function test_language_detected_from_extension()
    config.setup({ mode = "float" })

    local original_expand = vim.fn.expand
    vim.bo.filetype = ""
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/fallback/main.rs" end
        return original_expand(expr)
    end

    init.run_code(0, "float")

    assert(#job_results > 0, "Extension-based detection should start a job")
    local has_rust = false
    local commands = {}
    for _, job in ipairs(job_results) do
        local command = command_to_string(job.cmd)
        commands[#commands + 1] = command
        if command:match("rustc") then
            has_rust = true
        end
    end
    assert(has_rust, "Expected rust runner for .rs fallback, got: " .. table.concat(commands, " | "))

    vim.fn.expand = original_expand
    reset_job_results()

    print("✓ Extension-based language detection test passed")
end

-- Test filetype fallback by shebang when extension and vim.bo.filetype are missing.
local function test_language_detected_from_shebang()
    config.setup({ mode = "float" })

    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile
    vim.bo.filetype = ""
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/fallback/script" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/fallback/script" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/fallback/script" then
            return { "#!/usr/bin/env python3" }
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end

    init.run_code(0, "float")

    assert(#job_results > 0, "Shebang-based detection should start a job")
    local has_python = false
    local commands = {}
    for _, job in ipairs(job_results) do
        local command = command_to_string(job.cmd)
        commands[#commands + 1] = command
        if command:match("python3") then
            has_python = true
        end
    end
    assert(has_python, "Expected python runner for python shebang fallback, got: " .. table.concat(commands, " | "))

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    reset_job_results()

    print("✓ Shebang-based language detection test passed")
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

-- Test build command detection maps related filetypes (e.g. typescriptreact -> typescript).
local function test_build_command_filetype_alias()
    config.setup({ mode = "float" })

    local original_expand = vim.fn.expand
    vim.bo.filetype = "typescriptreact"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/alias/main.tsx" end
        return original_expand(expr)
    end

    init.run_build_command("dev", "float")

    assert(#job_results > 0, "Alias filetype build command should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("npm run dev"), "typescriptreact should reuse typescript build commands")

    vim.fn.expand = original_expand
    reset_job_results()

    print("✓ Build command filetype alias test passed")
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

-- Test zig quickfix processor keeps newest lines when max_bytes truncates input.
local function test_quickfix_zig_processor_keeps_tail_on_byte_cap()
    config.setup({
        mode = "float",
        quickfix = {
            enabled = true,
            processor = "zig",
            max_lines = 10,
            max_bytes = 12,
            strip_ansi = false,
            strip_ansi_max_lines = 10,
            parse_diagnostics = false,
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    local original_line_count = vim.api.nvim_buf_line_count
    local original_get_lines = vim.api.nvim_buf_get_lines
    local test_lines = {
        "first-line",
        "second-line",
        "newest-line",
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

    assert(#quickfix_results > 0, "Zig quickfix should populate results under byte cap")
    local qf = quickfix_results[#quickfix_results]
    assert(qf.lines[1] == "[zignite] quickfix output truncated", "Zig quickfix should include truncation notice")
    assert(qf.lines[2] == "newest-line", "Zig quickfix should keep newest line under byte cap")
    assert(qf.lines[3] == nil, "Zig quickfix should drop older lines once byte cap is reached")

    next_exit_code = 0
    vim.fn.expand = original_expand
    vim.api.nvim_buf_line_count = original_line_count
    vim.api.nvim_buf_get_lines = original_get_lines
    reset_job_results()
    reset_quickfix_results()

    print("✓ Quickfix zig byte-tail test passed")
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

-- Test RunLive picks command by live/dev/watch priority.
local function test_run_live_priority_selection()
    config.setup({
        build_commands = {
            webft = {
                start = "npm start",
                dev = "npm run dev",
                live = "npm run live",
            },
        },
    })

    vim.bo.filetype = "webft"
    local original_expand = vim.fn.expand
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/webft/main.ts" end
        return original_expand(expr)
    end

    reset_job_results()
    init.run_live("float")

    assert(#job_results > 0, "RunLive should start a job when a live command exists")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("live"), "RunLive should prioritize 'live' command")
    assert(not command:match("run dev"), "RunLive should not fallback to 'dev' when 'live' exists")

    vim.fn.expand = original_expand
    reset_job_results()

    print("✓ RunLive priority selection test passed")
end

-- Test RunLive shows guidance when no live/watch command exists.
local function test_run_live_missing_command()
    config.setup({
        build_commands = {
            nolive = {
                build = "echo build",
                test = "echo test",
            },
        },
    })

    vim.bo.filetype = "nolive"
    local original_expand = vim.fn.expand
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local output_messages = {}
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/nolive/main.txt" end
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
    init.run_live("float")
    assert(#job_results == 0, "RunLive should not start job when no live/watch command exists")
    assert(#output_messages > 0, "RunLive should show guidance when no live/watch command exists")
    assert(
        output_messages[#output_messages]:match("No live/watch command found"),
        "RunLive missing-command message should mention live/watch command"
    )

    vim.fn.expand = original_expand
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    reset_job_results()

	print("✓ RunLive missing command test passed")
end

-- Test picker path never relies on vim.wait when async picker mode is enabled.
---@return nil
local function test_picker_async_path_without_wait()
	init.setup({
		build_commands = {},
		detect_runtime = {
			async_picker = true,
			cache_ttl_ms = 15000,
			live_merge = true,
		},
	})

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_open_win = vim.api.nvim_open_win
	local original_wait = vim.wait
	local picker_opened = false
	local wait_called = false

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/asyncwait/main.go"
		end
		return original_expand(expr)
	end
	vim.api.nvim_open_win = function(...)
		picker_opened = true
		return original_open_win(...)
	end
	vim.wait = function()
		wait_called = true
		error("picker async path should not call vim.wait")
	end

	local ok, err = pcall(init.select_build_command, "float")
	assert(ok, "Picker should open without vim.wait dependency: " .. tostring(err))
	assert(picker_opened, "Picker should still open in async mode")
	assert(not wait_called, "Async picker path should never call vim.wait")

	vim.fn.expand = original_expand
	vim.api.nvim_open_win = original_open_win
	vim.wait = original_wait

	print("✓ Picker async no-wait test passed")
end

-- Test RunBuild uses async detection fallback instead of sync vim.wait when
-- a detected command is not yet cached.
---@return nil
local function test_run_build_async_detect_without_wait()
	init.setup({
		build_commands = {},
		detect_runtime = {
			async_picker = true,
			cache_ttl_ms = 15000,
			live_merge = true,
		},
	})

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_wait = vim.wait

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/async-build/main.go"
		end
		return original_expand(expr)
	end
	vim.wait = function()
		error("run_build_command should not call vim.wait")
	end

	reset_job_results()
	local ok, err = pcall(init.run_build_command, "fmt", "float")
	assert(ok, "RunBuild should resolve detected commands without vim.wait: " .. tostring(err))
	assert(#job_results > 0, "RunBuild should start a job for detected command")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("go fmt"), "RunBuild should execute detected go fmt command")

	vim.fn.expand = original_expand
	vim.wait = original_wait
	reset_job_results()

	print("✓ RunBuild async detect test passed")
end

-- Test RunBuild completion stays non-blocking and uses literal prefix matching.
---@return nil
local function test_run_build_completion_nonblocking_prefix()
	local original_create_user_command = vim.api.nvim_create_user_command
	local original_expand = vim.fn.expand
	local original_wait = vim.wait
	local commands = {}

	config.setup({
		build_commands = {
			cpp = {
				["c++"] = "zig c++",
				clean = "make clean",
			},
		},
	})

	vim.bo.filetype = "cpp"
	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/completion/main.cpp"
		end
		return original_expand(expr)
	end
	vim.wait = function()
		error("completion should not call vim.wait")
	end
	vim.api.nvim_create_user_command = function(name, fn, opts)
		commands[name] = { fn = fn, opts = opts }
	end
	vim.g = vim.g or {}
	vim.g.loaded_zignite = nil

	dofile(project_root .. "/plugin/zignite.lua")

	assert(commands.RunBuild ~= nil, "Plugin should register RunBuild command")
	local matches = commands.RunBuild.opts.complete("c+", "", 0)
	assert(#matches == 1 and matches[1] == "c++", "RunBuild completion should use literal prefix matching")

	vim.api.nvim_create_user_command = original_create_user_command
	vim.fn.expand = original_expand
	vim.wait = original_wait
	vim.g.loaded_zignite = nil

	print("✓ RunBuild completion nonblocking prefix test passed")
end

-- Test picker opens from immediate commands then live-merges async detected commands.
---@return nil
local function test_picker_async_live_merge_refresh()
	init.setup({
		build_commands = {
			go = {
				build = "go build",
			},
		},
		detect_runtime = {
			async_picker = true,
			cache_ttl_ms = 1,
			live_merge = true,
		},
	})

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_chansend_fn = vim.fn.chansend
	local original_buf_set_lines = vim.api.nvim_buf_set_lines
	local rendered_lines = {}
	local deferred_detect = nil

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/asyncrefresh/main.go"
		end
		return original_expand(expr)
	end
	vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
		if type(lines) == "table" and #lines > 0 then
			rendered_lines = lines
		end
		if original_buf_set_lines then
			return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
		end
	end
	vim.fn.chansend = function(job_id, data)
		local job = mock_jobs[job_id]
		if job and is_detect_daemon_cmd(job.cmd) then
			local text = type(data) == "table" and table.concat(data) or tostring(data or "")
			deferred_detect = {
				job_id = job_id,
				opts = job.opts,
				response = parse_detect_daemon_request(text),
			}
			detect_backend_invocations = detect_backend_invocations + 1
			return 1
		end
		return original_chansend_fn(job_id, data)
	end

	reset_job_results()
	init.select_build_command("float")

	local initial_render = table.concat(rendered_lines, "\n")
	assert(initial_render:match("cmd:%s+go build"), "Initial picker render should keep selected command preview")
	assert(not initial_render:match("go env"), "Initial picker render should not include deferred detected commands")
	assert(deferred_detect and deferred_detect.opts and deferred_detect.response, "Detect response should be deferred")

	deferred_detect.opts.on_stdout(deferred_detect.job_id, deferred_detect.response)
	local refreshed_render = table.concat(rendered_lines, "\n")
	assert(refreshed_render:match("go env"), "Live refresh should merge detected commands into picker")
	assert(refreshed_render:match("cmd:%s+go build"), "Live refresh should preserve selected command preview")

	vim.fn.expand = original_expand
	vim.fn.chansend = original_chansend_fn
	vim.api.nvim_buf_set_lines = original_buf_set_lines

	print("✓ Picker async live-merge refresh test passed")
end

-- Test picker detection cache invalidation uses TTL and mtime signature.
---@return nil
local function test_picker_detection_cache_ttl_and_mtime()
	init.setup({
		build_commands = {},
		detect_runtime = {
			async_picker = true,
			cache_ttl_ms = 15000,
			live_merge = false,
		},
	})

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_exepath = vim.fn.exepath
	local original_hrtime = vim.loop.hrtime
	local original_fs_stat = vim.loop.fs_stat
	local fake_now_ms = 1000
	local signature_version = 1

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/cachettl/main.go"
		end
		return original_expand(expr)
	end
	vim.fn.exepath = function(name)
		if name == "go" then
			return "/tmp/fake-go"
		end
		if original_exepath then
			return original_exepath(name)
		end
		return ""
	end
	vim.loop.hrtime = function()
		return fake_now_ms * 1e6
	end
	vim.loop.fs_stat = function(path)
		if path == "/tmp/fake-go" then
			return {
				size = 1,
				mtime = {
					sec = signature_version,
					nsec = 0,
				},
			}
		end
		if original_fs_stat then
			return original_fs_stat(path)
		end
		return nil
	end

	reset_job_results()
	init.select_build_command("float")
	local first = count_detect_backend_jobs()
	assert(first > 0, "First picker open should trigger detection")

	init.select_build_command("float")
	local second = count_detect_backend_jobs()
	assert(second == first, "Second picker open within TTL should reuse cache")

	fake_now_ms = fake_now_ms + 20000
	init.select_build_command("float")
	local third = count_detect_backend_jobs()
	assert(third > second, "TTL expiry should trigger new detection")

	fake_now_ms = fake_now_ms + 10
	signature_version = signature_version + 1
	init.select_build_command("float")
	local fourth = count_detect_backend_jobs()
	assert(fourth > third, "Mtime signature change should trigger new detection")

	vim.fn.expand = original_expand
	vim.fn.exepath = original_exepath
	vim.loop.hrtime = original_hrtime
	vim.loop.fs_stat = original_fs_stat

	print("✓ Picker detection cache TTL+mtime test passed")
end

-- Test failed detection retries sooner than the normal success TTL.
---@return nil
local function test_picker_detection_failed_cache_retries_early()
	init.setup({
		build_commands = {},
		detect_runtime = {
			async_picker = true,
			cache_ttl_ms = 15000,
			live_merge = false,
		},
	})

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_hrtime = vim.loop.hrtime
	local original_next_exit_code = next_exit_code
	local fake_now_ms = 1000

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/cachefail/main.go"
		end
		return original_expand(expr)
	end
	vim.loop.hrtime = function()
		return fake_now_ms * 1e6
	end

	reset_job_results()
	next_detect_backend_exit_code = 1
	next_exit_code = 1
	init.select_build_command("float")
	local first = count_detect_backend_requests()
	assert(first > 0, "First picker open should issue a detect request")

	fake_now_ms = fake_now_ms + 2000
	init.select_build_command("float")
	local second = count_detect_backend_requests()
	assert(second > first, "Failed detection cache should retry before normal TTL expiry")

	next_detect_backend_exit_code = 0
	next_exit_code = original_next_exit_code
	vim.fn.expand = original_expand
	vim.loop.hrtime = original_hrtime

	print("✓ Picker failed-detection retry test passed")
end

-- Test Zig command detection from `zig --help` appears in build picker.
local function test_zig_detected_commands_in_picker()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "zig"
    local original_expand = vim.fn.expand
    local original_open_win = vim.api.nvim_open_win
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local picker_opened = false
    local rendered_lines = {}

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/zigdetect/main.zig" end
        return original_expand(expr)
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

	reset_job_results()
	init.select_build_command("float")

	    assert(picker_opened, "Picker should open for detected zig commands")
	    local rendered = table.concat(rendered_lines, "\n")
	    assert(rendered:match("build"), "Picker should include detected zig build command")
	    assert(rendered:match("fmt"), "Picker should include detected zig fmt command")
	    assert(rendered:match("run"), "Picker should include detected zig run command")
	    assert(rendered:match("fetch"), "Picker should include zig fetch command")
	    assert(rendered:match("zig fetch <%a+>"), "Picker should display placeholder for required fetch argument")

    vim.fn.expand = original_expand
    vim.api.nvim_open_win = original_open_win
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    vim.v.shell_error = 0

    print("✓ Zig detected commands in picker test passed")
end

-- Test Go command detection from `go help` appears in build picker.
local function test_go_detected_commands_in_picker()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_open_win = vim.api.nvim_open_win
	local original_buf_set_lines = vim.api.nvim_buf_set_lines
	local picker_opened = false
	local rendered_lines = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/godetect/main.go"
		end
		return original_expand(expr)
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

	assert(picker_opened, "Picker should open for detected go commands")
	local rendered = table.concat(rendered_lines, "\n")
	assert(rendered:match("env"), "Picker should include detected go env command")
	assert(rendered:match("fmt"), "Picker should include detected go fmt command")

	vim.fn.expand = original_expand
	vim.api.nvim_open_win = original_open_win
	vim.api.nvim_buf_set_lines = original_buf_set_lines
	vim.v.shell_error = 0

	print("✓ Go detected commands in picker test passed")
end

-- Test Go command detection can use the persistent zig detect worker path.
local function test_go_detected_commands_with_zig_worker()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "go"
    local original_expand = vim.fn.expand
    local original_systemlist = vim.fn.systemlist
    local original_wait = vim.wait
    local original_open_win = vim.api.nvim_open_win
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local picker_opened = false
    local rendered_lines = {}

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/godetect/main.go" end
        return original_expand(expr)
    end
    vim.wait = function(_, condition)
        return condition()
    end
    vim.fn.systemlist = function(cmd)
        assert(
            not (type(cmd) == "table" and cmd[1] == "go" and cmd[2] == "help"),
            "go help should not be probed when zig detect worker succeeds"
        )
        return original_systemlist(cmd)
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

    reset_job_results()
    init.select_build_command("float")

    assert(picker_opened, "Picker should open for go commands detected via zig worker")
    assert(count_detect_backend_jobs() > 0, "Detect worker path should send at least one request")
    local rendered = table.concat(rendered_lines, "\n")
    assert(rendered:match("go env"), "Worker-detected go commands should include env")
    assert(rendered:match("go fmt"), "Worker-detected go commands should include fmt")

    vim.fn.expand = original_expand
    vim.fn.systemlist = original_systemlist
    vim.wait = original_wait
    vim.api.nvim_open_win = original_open_win
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    vim.v.shell_error = 0

    print("✓ Go detected commands via zig worker test passed")
end

-- Test Go command detection falls back to Lua parsing when zig detect worker fails.
local function test_go_detected_commands_worker_fallback()
    init.setup({
        build_commands = {},
    })

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_open_win = vim.api.nvim_open_win
	local original_buf_set_lines = vim.api.nvim_buf_set_lines
	local picker_opened = false
	local rendered_lines = {}

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/godetect/main.go" end
        return original_expand(expr)
    end
    next_detect_backend_exit_code = 1
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

    reset_job_results()
    init.select_build_command("float")

    local go_help_spawned = false
    for _, job in ipairs(job_results) do
        if type(job.cmd) == "table" and job.cmd[1] == "go" and job.cmd[2] == "help" then
            go_help_spawned = true
            break
        end
    end

    assert(picker_opened, "Picker should open when falling back from worker to Lua parser")
    assert(go_help_spawned, "Fallback should spawn go help when worker fails")
    local rendered = table.concat(rendered_lines, "\n")
    assert(rendered:match("go env"), "Fallback-detected go commands should include env")
    assert(rendered:match("go fmt"), "Fallback-detected go commands should include fmt")

    vim.fn.expand = original_expand
    vim.api.nvim_open_win = original_open_win
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    vim.v.shell_error = 0

    print("✓ Go detected commands worker fallback test passed")
end

-- Test disabling go auto-detection removes detected commands and avoids probing.
local function test_go_detection_can_be_disabled()
	init.setup({
		build_commands = {},
		detect = {
			go = false,
		},
	})
	assert(config.options.detect.go == false, "Test setup should disable detect.go")

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_jobstart_fn = vim.fn.jobstart
	local original_open_win = vim.api.nvim_open_win
	local original_buf_set_lines = vim.api.nvim_buf_set_lines
	local picker_opened = false
	local rendered_lines = {}
	local picker_job_commands = {}
	local in_picker_call = false

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/godetect/main.go"
		end
		return original_expand(expr)
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
	vim.fn.jobstart = function(cmd, opts)
		if in_picker_call then
			picker_job_commands[#picker_job_commands + 1] = command_to_string(cmd)
		end
		return original_jobstart_fn(cmd, opts)
	end

	reset_job_results()
	in_picker_call = true
	init.select_build_command("float")
	in_picker_call = false

	local go_help_spawned = false
	for _, cmd in ipairs(picker_job_commands) do
		if cmd:match("^go help") then
			go_help_spawned = true
			break
		end
	end

	assert(picker_opened, "Picker should still open when go detection is disabled")
	assert(not go_help_spawned, "go help should not run when detect.go=false")
	local rendered = table.concat(rendered_lines, "\n")
	assert(not rendered:match("go env"), "Disabled go detection should not include detected go env command")
	assert(not rendered:match("go fmt"), "Disabled go detection should not include detected go fmt command")

	vim.fn.expand = original_expand
	vim.fn.jobstart = original_jobstart_fn
	vim.api.nvim_open_win = original_open_win
	vim.api.nvim_buf_set_lines = original_buf_set_lines
	vim.v.shell_error = 0

	print("✓ Go detection disable test passed")
end

-- Test C command detection from Makefile targets appears in build picker.
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

-- Test run_build_command can execute zig commands detected from `zig --help`.
local function test_run_build_command_with_detected_zig_command()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "zig"
    local original_expand = vim.fn.expand
    local original_systemlist = vim.fn.systemlist
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/zigdetect/main.zig" end
        return original_expand(expr)
    end
	vim.fn.systemlist = function(cmd)
		vim.v.shell_error = 0
		if type(cmd) == "table" and cmd[2] == "--detect" and cmd[3] == "--tool=zig" then
			return { "fmt" }
		end
		return {
			"Usage: zig [command] [options]",
			"",
			"Commands:",
			"  build            Build project from build.zig",
			"  fmt              Reformat Zig source into canonical form",
			"",
			"General Options:",
		}
	end

    reset_job_results()
    init.run_build_command("fmt", "float")
    assert(#job_results > 0, "Detected zig build command should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("zig fmt"), "Detected zig command should execute via zig fmt")

    vim.fn.expand = original_expand
    vim.fn.systemlist = original_systemlist
    vim.v.shell_error = 0
    reset_job_results()

    print("✓ RunBuild with detected zig command test passed")
end

-- Test run_build_command can execute go commands detected from `go help`.
local function test_run_build_command_with_detected_go_command()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "go"
    local original_expand = vim.fn.expand
    local original_systemlist = vim.fn.systemlist
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/godetect/main.go" end
        return original_expand(expr)
    end
	vim.fn.systemlist = function(cmd)
		vim.v.shell_error = 0
		if type(cmd) == "table" and cmd[2] == "--detect" and cmd[3] == "--tool=go" then
			return { "env" }
		end
		if type(cmd) == "table" and cmd[1] == "go" and cmd[2] == "help" then
			return {
				"The commands are:",
				"    env         print Go environment information",
			}
		end
		return original_systemlist(cmd)
	end

    reset_job_results()
    init.run_build_command("env", "float")
    assert(#job_results > 0, "Detected go command should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("go env"), "Detected go command should execute via go env")

    vim.fn.expand = original_expand
    vim.fn.systemlist = original_systemlist
    vim.v.shell_error = 0
    reset_job_results()

    print("✓ RunBuild with detected go command test passed")
end

-- Test run_build_command can execute rust commands detected from `cargo --list`.
local function test_run_build_command_with_detected_rust_command()
    init.setup({
        build_commands = {},
    })

	vim.bo.filetype = "rust"
	local original_expand = vim.fn.expand
	local original_systemlist = vim.fn.systemlist
	local original_detect_commands = detect_backend_tool_commands.cargo
	vim.fn.expand = function(expr)
	    if expr == "%:p" then return "/tmp/rustdetect/main.rs" end
	    return original_expand(expr)
	end
	detect_backend_tool_commands.cargo = { "metadata" }
	vim.fn.systemlist = function(cmd)
		vim.v.shell_error = 0
		if type(cmd) == "table" and cmd[2] == "--detect" and cmd[3] == "--tool=cargo" then
			return { "metadata" }
		end
		if type(cmd) == "table" and cmd[1] == "cargo" and cmd[2] == "--list" then
			return {
				"Installed Commands:",
				"    metadata    Output metadata about local package",
			}
		end
		return original_systemlist(cmd)
	end

    reset_job_results()
    init.run_build_command("metadata", "float")
    assert(#job_results > 0, "Detected rust command should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("cargo metadata"), "Detected rust command should execute via cargo metadata")

	vim.fn.expand = original_expand
	vim.fn.systemlist = original_systemlist
	detect_backend_tool_commands.cargo = original_detect_commands
	vim.v.shell_error = 0
	reset_job_results()

    print("✓ RunBuild with detected rust command test passed")
end

-- Test run_build_command can execute cpp commands detected from Makefile targets.
local function test_run_build_command_with_detected_cpp_make_target()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "cpp"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/cppdetect/main.cpp" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/cppdetect/Makefile" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/cppdetect/Makefile" then
            return {
                "custom-target:",
                "\t@echo cpp",
            }
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end

    reset_job_results()
    init.run_build_command("custom-target", "float")
    assert(#job_results > 0, "Detected cpp Makefile target should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("make custom%-target"), "Detected cpp Makefile target should execute via make custom-target")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    reset_job_results()

    print("✓ RunBuild with detected cpp Makefile target test passed")
end

-- Test run_build_command can execute odin commands detected from `odin help`.
local function test_run_build_command_with_detected_odin_command()
    init.setup({
        build_commands = {},
    })

	vim.bo.filetype = "odin"
	local original_expand = vim.fn.expand
	local original_systemlist = vim.fn.systemlist
	local original_detect_commands = detect_backend_tool_commands.odin
	vim.fn.expand = function(expr)
	    if expr == "%:p" then return "/tmp/odindetect/main.odin" end
	    return original_expand(expr)
	end
	detect_backend_tool_commands.odin = { "version" }
	vim.fn.systemlist = function(cmd)
		vim.v.shell_error = 0
		if type(cmd) == "table" and cmd[2] == "--detect" and cmd[3] == "--tool=odin" then
			return { "version" }
		end
		if type(cmd) == "table" and cmd[1] == "odin" and cmd[2] == "help" then
			return {
				"Commands:",
				"    version     Print version information",
				"",
				"Flags:",
			}
		end
		return original_systemlist(cmd)
	end

    reset_job_results()
    init.run_build_command("version", "float")
    assert(#job_results > 0, "Detected odin command should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("odin version"), "Detected odin command should execute via odin version")

	vim.fn.expand = original_expand
	vim.fn.systemlist = original_systemlist
	detect_backend_tool_commands.odin = original_detect_commands
	vim.v.shell_error = 0
	reset_job_results()

    print("✓ RunBuild with detected odin command test passed")
end

-- Test Java build commands can be inferred from Maven project files.
local function test_run_build_command_with_detected_java_maven_command()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "java"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/javadetect/src/Main.java" end
        return original_expand(expr)
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

    reset_job_results()
    init.run_build_command("mvn-test", "float")
    assert(#job_results > 0, "Detected Java Maven command should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("mvn test"), "Detected Java Maven command should execute via mvn test")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    reset_job_results()

    print("✓ RunBuild with detected Java Maven command test passed")
end

-- Test Kotlin build commands can be inferred from Gradle wrapper projects.
local function test_run_build_command_with_detected_kotlin_gradle_command()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "kotlin"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/ktdetect/src/Main.kt" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/ktdetect/gradlew" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end

    reset_job_results()
    init.run_build_command("gradle-build", "float")
    assert(#job_results > 0, "Detected Kotlin Gradle command should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("./gradlew build"), "Detected Kotlin Gradle command should execute via ./gradlew build")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    reset_job_results()

    print("✓ RunBuild with detected Kotlin Gradle command test passed")
end

-- Test JavaScript package scripts are detected from package.json.
local function test_javascript_package_scripts_detection()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "javascript"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile
    local original_vim_json = vim.json

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/jsapp/src/main.js" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/jsapp/package.json" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/jsapp/package.json" then
            return { '{"scripts":{"dev":"vite","lint":"eslint ."}}' }
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end
    vim.json = {
        decode = function(_)
            return {
                scripts = {
                    dev = "vite",
                    lint = "eslint .",
                },
            }
        end,
    }

    reset_job_results()
    init.run_build_command("lint", "float")
    assert(#job_results > 0, "Detected package script should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("npm run lint"), "Detected script should execute via npm run lint")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.json = original_vim_json
    reset_job_results()

    print("✓ JavaScript package script detection test passed")
end

-- Test run_build_command prompts for zig fetch URL/path and executes with provided argument.
local function test_run_build_command_with_detected_zig_fetch_prompt()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "zig"
    local original_expand = vim.fn.expand
    local original_systemlist = vim.fn.systemlist
    local original_input = vim.fn.input
    local prompts = {}

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/zigdetect/main.zig" end
        return original_expand(expr)
    end
    vim.fn.systemlist = function()
        vim.v.shell_error = 0
        return {
            "Usage: zig [command] [options]",
            "",
            "Commands:",
            "  fetch            Copy a package into global cache and print its hash",
            "",
            "General Options:",
        }
    end
    vim.fn.input = function(prompt, _default)
        prompts[#prompts + 1] = prompt
        return "https://example.com/pkg.tar.gz"
    end

    reset_job_results()
    init.run_build_command("fetch", "float")
    assert(#job_results > 0, "Detected zig fetch command should start a job after prompting for URL/path")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("zig fetch"), "Detected zig fetch should execute via zig fetch")
    assert(command:match("https://example%.com/pkg%.tar%.gz"), "zig fetch should include provided URL/path argument")
    assert(#prompts == 1 and prompts[1]:match("zig fetch"), "zig fetch should prompt for URL/path exactly once")

    vim.fn.expand = original_expand
    vim.fn.systemlist = original_systemlist
    vim.fn.input = original_input
    vim.v.shell_error = 0
    reset_job_results()

    print("✓ RunBuild with detected zig fetch prompt test passed")
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

-- Test vsplit mode applies configured term.size as window width.
local function test_vsplit_respects_configured_width()
    config.setup({
        mode = "vsplit",
        term = {
            position = "right",
            size = 33,
            focus = true,
            startinsert = false,
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    local original_set_width = vim.api.nvim_win_set_width
    local captured_width = nil

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/vsplit-width/main.py" end
        return original_expand(expr)
    end
    vim.api.nvim_win_set_width = function(_, width)
        captured_width = width
    end

    init.run_code(0, "vsplit")

    assert(captured_width == 33, "vsplit should apply term.size as window width")

    vim.fn.expand = original_expand
    vim.api.nvim_win_set_width = original_set_width
    reset_job_results()

    print("✓ vsplit width test passed")
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
test_visual_run_code_preserves_extension()
test_timeout_uses_zig_wrapper()
test_language_detected_from_extension()
test_language_detected_from_shebang()
test_project_execution()
test_build_command_uses_cwd()
test_build_command_filetype_alias()
test_quickfix_on_error_lua_processor()
test_quickfix_zig_processor()
test_quickfix_zig_processor_keeps_tail_on_byte_cap()
test_quickfix_auto_threshold_behavior()
test_quickfix_zig_fallback()
test_quickfix_zig_diagnostic_parser()
test_float_focus_behavior()
test_build_picker_empty_state()
test_build_picker_keeps_generic_commands_in_mixed_repo()
test_build_picker_window_clamped()
test_build_picker_focus_behavior()
test_build_picker_focus_override()
test_build_picker_filter_and_preview()
test_build_picker_filter_cmdline_mode()
test_build_picker_filter_inline_mode()
test_run_build_last_behavior()
test_run_live_priority_selection()
test_run_live_missing_command()
test_picker_async_path_without_wait()
test_run_build_async_detect_without_wait()
test_run_build_completion_nonblocking_prefix()
test_picker_async_live_merge_refresh()
test_picker_detection_cache_ttl_and_mtime()
test_picker_detection_failed_cache_retries_early()
test_zig_detected_commands_in_picker()
test_go_detected_commands_in_picker()
test_go_detected_commands_with_zig_worker()
test_go_detected_commands_worker_fallback()
test_go_detection_can_be_disabled()
test_c_detected_make_targets_in_picker()
test_run_build_command_with_detected_zig_command()
test_run_build_command_with_detected_go_command()
test_run_build_command_with_detected_rust_command()
test_run_build_command_with_detected_cpp_make_target()
test_run_build_command_with_detected_odin_command()
test_run_build_command_with_detected_java_maven_command()
test_run_build_command_with_detected_kotlin_gradle_command()
test_javascript_package_scripts_detection()
test_run_build_command_with_detected_zig_fetch_prompt()
test_show_output_respects_mode()
test_vsplit_respects_left_position()
test_vsplit_respects_configured_width()
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
