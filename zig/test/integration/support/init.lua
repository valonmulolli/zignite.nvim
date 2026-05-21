local bootstrap = require("integration.support.bootstrap")
local jobs = require("integration.support.jobs")
local simulation = require("integration.support.simulate")

---@type table
local M = {}

local project_root = bootstrap.setup()

---@type table
local state = {
	next_exit_code = 0,
	next_quickfix_backend_exit_code = 0,
	next_quickfix_backend_error = nil,
	next_detect_backend_exit_code = 0,
	next_detect_backend_error = nil,
	next_project_backend_error = nil,
	next_project_backend_stdout_chunks = nil,
	next_job_id = 123,
	jobstop_count = 0,
	quickfix_backend_invocations = 0,
	quickfix_daemon_request_count = 0,
	detect_backend_invocations = 0,
	detect_backend_request_count = 0,
	project_backend_invocations = 0,
	project_backend_request_count = 0,
}

---@type table[]
local job_results = {}
---@type table[]
local quickfix_results = {}
---@type table[]
local notify_results = {}
---@type table
local mock_jobs = {}

local restore_runtime = jobs.attach({
	state = state,
	job_results = job_results,
	quickfix_results = quickfix_results,
	notify_results = notify_results,
	mock_jobs = mock_jobs,
}, simulation)

local config = require("zignite.config")
local init = require("zignite.init")
local ui_windows = require("zignite.ui.windows")

---@param cmd string|string[]
---@return string
local function command_to_string(cmd)
	if type(cmd) == "table" then
		return table.concat(cmd, " ")
	end
	return cmd or ""
end

---@param path string
---@return fun(expr: string): string
local function make_expand_override(path)
	local original_expand = vim.fn.expand
	return function(expr)
		if expr == "%:p" then
			return path
		end
		return original_expand(expr)
	end
end

---@param overrides { tbl: table, key: string, value: any }[]
---@param fn fun()
---@return nil
local function with_overrides(overrides, fn)
	local originals = {}
	for index, override in ipairs(overrides) do
		originals[index] = override.tbl[override.key]
		override.tbl[override.key] = override.value
	end

	local ok, err = xpcall(fn, debug.traceback)

	for index = #overrides, 1, -1 do
		local override = overrides[index]
		override.tbl[override.key] = originals[index]
	end

	if not ok then
		error(err)
	end
end

---@return nil
local function reset_job_results()
	for index = #job_results, 1, -1 do
		job_results[index] = nil
	end
	state.quickfix_backend_invocations = 0
	state.quickfix_daemon_request_count = 0
	state.detect_backend_invocations = 0
	state.detect_backend_request_count = 0
	state.project_backend_invocations = 0
	state.project_backend_request_count = 0
	state.next_detect_backend_error = nil
	state.next_project_backend_error = nil
	state.next_quickfix_backend_error = nil
	state.next_project_backend_stdout_chunks = nil
	state.jobstop_count = 0
end

---@return nil
local function reset_quickfix_results()
	for index = #quickfix_results, 1, -1 do
		quickfix_results[index] = nil
	end
end

---@return nil
local function reset_notify_results()
	for index = #notify_results, 1, -1 do
		notify_results[index] = nil
	end
end

---@return integer
local function count_quickfix_backend_jobs()
	return state.quickfix_backend_invocations
end

---@return integer
local function count_quickfix_daemon_jobs()
	return state.quickfix_daemon_request_count
end

---@return integer
local function count_detect_backend_jobs()
	return state.detect_backend_invocations
end

---@return integer
local function count_detect_backend_requests()
	return state.detect_backend_request_count
end

---@return integer
local function count_project_backend_jobs()
	return state.project_backend_invocations
end

---@return integer
local function count_project_backend_requests()
	return state.project_backend_request_count
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

M.project_root = project_root
M.config = config
M.init = init
M.ui = ui_windows
M.state = state
M.job_results = job_results
M.quickfix_results = quickfix_results
M.notify_results = notify_results
M.mock_jobs = mock_jobs
M.command_to_string = command_to_string
M.make_expand_override = make_expand_override
M.with_overrides = with_overrides
M.reset_job_results = reset_job_results
M.reset_quickfix_results = reset_quickfix_results
M.reset_notify_results = reset_notify_results
M.count_quickfix_backend_jobs = count_quickfix_backend_jobs
M.count_quickfix_daemon_jobs = count_quickfix_daemon_jobs
M.count_detect_backend_jobs = count_detect_backend_jobs
M.count_detect_backend_requests = count_detect_backend_requests
M.count_project_backend_jobs = count_project_backend_jobs
M.count_project_backend_requests = count_project_backend_requests
M.get_upvalue_by_name = get_upvalue_by_name
M.detect_backend_tool_commands = simulation.detect_backend_tool_commands
M.is_detect_daemon_cmd = simulation.is_detect_daemon_cmd
M.is_unified_daemon_cmd = simulation.is_unified_daemon_cmd
M.parse_detect_daemon_request = simulation.parse_detect_daemon_request
M.parse_unified_daemon_request = simulation.parse_unified_daemon_request
M.is_project_daemon_cmd = simulation.is_project_daemon_cmd
M.parse_project_daemon_request = simulation.parse_project_daemon_request

---@return nil
function M.restore()
	restore_runtime()
end

return M
