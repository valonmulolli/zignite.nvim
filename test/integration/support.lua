-- Mock vim functions for testing
local project_root = arg[1] or "."
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
local mock_jobs = {}
local state = {
    next_exit_code = 0,
    next_quickfix_backend_exit_code = 0,
    next_detect_backend_exit_code = 0,
    next_job_id = 123,
    quickfix_backend_invocations = 0,
    detect_backend_invocations = 0,
    detect_backend_request_count = 0,
}
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
    local job_id = state.next_job_id
    state.next_job_id = state.next_job_id + 1
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
            local exit_code = state.next_exit_code
            vim.defer_fn(function() opts.on_exit(job_id, exit_code) end, 10)
        end
        return job_id
    end

    if opts.on_exit then
        local exit_code = state.next_exit_code
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
        if state.next_quickfix_backend_exit_code ~= 0 then
            local exit_code = state.next_quickfix_backend_exit_code
            state.next_quickfix_backend_exit_code = 0
            if job.opts and job.opts.on_exit then
                vim.defer_fn(function() job.opts.on_exit(job_id, exit_code) end, 10)
            end
            return 1
        end

        local text = type(data) == "table" and table.concat(data) or tostring(data or "")
        local response = parse_daemon_request(text)
        if response and job.opts and job.opts.on_stdout then
            state.quickfix_backend_invocations = state.quickfix_backend_invocations + 1
            vim.defer_fn(function() job.opts.on_stdout(job_id, response) end, 10)
        end
        return 1
    end

    if is_detect_daemon_cmd(job.cmd) then
        state.detect_backend_request_count = state.detect_backend_request_count + 1
        if state.next_detect_backend_exit_code ~= 0 then
            local exit_code = state.next_detect_backend_exit_code
            state.next_detect_backend_exit_code = 0
            if job.opts and job.opts.on_exit then
                vim.defer_fn(function() job.opts.on_exit(job_id, exit_code) end, 10)
            end
            return 1
        end

        local text = type(data) == "table" and table.concat(data) or tostring(data or "")
        local response = parse_detect_daemon_request(text)
        if response and job.opts and job.opts.on_stdout then
            state.detect_backend_invocations = state.detect_backend_invocations + 1
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

    if state.next_quickfix_backend_exit_code ~= 0 then
        local exit_code = state.next_quickfix_backend_exit_code
        state.next_quickfix_backend_exit_code = 0
        if job.opts and job.opts.on_exit then
            vim.defer_fn(function() job.opts.on_exit(job_id, exit_code) end, 10)
        end
        return 1
    end

    local lines = simulate_quickfix_backend(job.input, job.cmd)
    if job.opts and job.opts.on_stdout then
        state.quickfix_backend_invocations = state.quickfix_backend_invocations + 1
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
    for index = #job_results, 1, -1 do
        job_results[index] = nil
    end
    state.quickfix_backend_invocations = 0
    state.detect_backend_invocations = 0
    state.detect_backend_request_count = 0
end

local function reset_quickfix_results()
    for index = #quickfix_results, 1, -1 do
        quickfix_results[index] = nil
    end
end

local function reset_notify_results()
    for index = #notify_results, 1, -1 do
        notify_results[index] = nil
    end
end

local function count_quickfix_backend_jobs()
    return state.quickfix_backend_invocations
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
    return state.detect_backend_invocations
end

local function count_detect_backend_requests()
    return state.detect_backend_request_count
end

---@param func function
---@param target_name string
---@return any
local function get_upvalue_by_name(func, target_name)
    local index = 1
    while true do
        local name, value = debug.getupvalue(func, index)
        if name == nil then
            return nil
        end
        if name == target_name then
            return value
        end
        index = index + 1
    end
end

return {
    project_root = project_root,
    config = config,
    init = init,
    ui = ui,
    state = state,
    job_results = job_results,
    quickfix_results = quickfix_results,
    notify_results = notify_results,
    mock_jobs = mock_jobs,
    command_to_string = command_to_string,
    reset_job_results = reset_job_results,
    reset_quickfix_results = reset_quickfix_results,
    reset_notify_results = reset_notify_results,
    count_quickfix_backend_jobs = count_quickfix_backend_jobs,
    count_quickfix_daemon_jobs = count_quickfix_daemon_jobs,
    count_detect_backend_jobs = count_detect_backend_jobs,
    count_detect_backend_requests = count_detect_backend_requests,
    get_upvalue_by_name = get_upvalue_by_name,
    detect_backend_tool_commands = detect_backend_tool_commands,
    is_detect_daemon_cmd = is_detect_daemon_cmd,
    parse_detect_daemon_request = parse_detect_daemon_request,
    restore = function()
        vim.fn.jobstart = original_jobstart
        vim.fn.chansend = original_chansend
        vim.fn.chanclose = original_chanclose
    end,
}
