---@type table
local M = {}

local DETECT_REQ_BEGIN = "@@ZDET_REQ_BEGIN"
local DETECT_REQ_END = "@@ZDET_REQ_END"
local DETECT_RES_BEGIN = "@@ZDET_RES_BEGIN"
local DETECT_RES_END = "@@ZDET_RES_END"
local DETECT_RES_ERR = "@@ZDET_RES_ERR"
local DETECT_WORKER_WAIT_MS = 1200
local DETECT_WORKER_REQUEST_TIMEOUT_MS = 3000
local PROJECT_REQ_BEGIN = "@@ZPRJ_REQ_BEGIN"
local PROJECT_REQ_END = "@@ZPRJ_REQ_END"
local PROJECT_RES_BEGIN = "@@ZPRJ_RES_BEGIN"
local PROJECT_RES_END = "@@ZPRJ_RES_END"
local PROJECT_RES_ERR = "@@ZPRJ_RES_ERR"
local PROJECT_WORKER_WAIT_MS = 1200

local ZIG_EXECUTABLE = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h:h")
	.. "/zig/zig-out/bin/zignite"

---@type table|nil
local detect_worker = nil
---@type table|nil
local project_worker = nil
local handle_detect_worker_stdout
local handle_project_worker_stdout

---@param value string
---@return string
local function trim_text(value)
	if type(value) ~= "string" then
		return ""
	end
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param timeout_ms integer
---@param callback fun():nil
---@return table|nil
local function start_request_timer(timeout_ms, callback)
	local uv = vim.uv or vim.loop
	if not uv or type(uv.new_timer) ~= "function" then
		return nil
	end
	local timer = uv.new_timer()
	if not timer then
		return nil
	end
	timer:start(timeout_ms, 0, vim.schedule_wrap(function()
		pcall(function()
			timer:stop()
		end)
		pcall(function()
			timer:close()
		end)
		callback()
	end))
	return timer
end

---@param timer table|nil
---@return nil
local function stop_request_timer(timer)
	if not timer then
		return
	end
	pcall(function()
		timer:stop()
	end)
	pcall(function()
		timer:close()
	end)
end

---@param tbl table<string, string>|nil
---@return table<string, string>
local function copy_string_map(tbl)
	---@type table<string, string>
	local out = {}
	if type(tbl) ~= "table" then
		return out
	end
	for key, value in pairs(tbl) do
		if type(key) == "string" and type(value) == "string" then
			out[key] = value
		end
	end
	return out
end

---@param worker table
---@param callback_runner fun(request: table):nil
---@return nil
local function flush_worker_fallbacks(worker, callback_runner)
	if not worker or not worker.pending then
		return
	end
	for _, request in pairs(worker.pending) do
		stop_request_timer(request.timer)
		if type(callback_runner) == "function" then
			callback_runner(request)
		end
		request.failed = true
		request.completed = true
	end
	worker.pending = {}
	worker.active_id = nil
	worker.active_lines = {}
	worker.active_error = nil
	if worker.stdout_buffer ~= nil then
		worker.stdout_buffer = ""
	end
end

---@param worker table
---@return nil
local function flush_detect_worker_fallbacks(worker)
	flush_worker_fallbacks(worker, function(request)
		if type(request.callbacks) ~= "table" then
			return
		end
		for _, callback in ipairs(request.callbacks) do
			if type(callback) == "function" then
				pcall(callback, nil)
			end
		end
	end)
end

---@param worker table
---@return nil
local function flush_project_worker_fallbacks(worker)
	flush_worker_fallbacks(worker, nil)
end

---@param worker table
---@param request_id integer
---@return table|nil, string[], string|nil
local function finish_active_request(worker, request_id)
	local request = worker.pending[request_id]
	worker.pending[request_id] = nil
	local completed_lines = worker.active_lines
	local completed_error = worker.active_error
	worker.active_id = nil
	worker.active_lines = {}
	worker.active_error = nil
	if request then
		stop_request_timer(request.timer)
		request.lines = completed_lines
		request.completed = true
		request.error = completed_error
		request.failed = completed_error ~= nil and completed_error ~= ""
	end
	return request, completed_lines, completed_error
end

---@param worker table
---@param build_from_names fun(tool: string, names: string[]): table<string, string>
---@return table|nil
local function start_detect_worker(build_from_names)
	local worker = {
		job_id = nil,
		next_request_id = 0,
		pending = {},
		active_id = nil,
		active_lines = {},
		active_error = nil,
		build_from_names = build_from_names,
	}

	local job_id = vim.fn.jobstart({ ZIG_EXECUTABLE, "--detect-daemon" }, {
		stdout_buffered = false,
		on_stdout = function(_, data)
			handle_detect_worker_stdout(worker, data)
		end,
		on_exit = function()
			if detect_worker == worker then
				detect_worker = nil
			end
			flush_detect_worker_fallbacks(worker)
		end,
	})

	if type(job_id) ~= "number" or job_id <= 0 then
		return nil
	end
	worker.job_id = job_id
	return worker
end

---@return table|nil
local function start_project_worker()
	local worker = {
		job_id = nil,
		next_request_id = 0,
		pending = {},
		active_id = nil,
		active_lines = {},
		active_error = nil,
		stdout_buffer = "",
	}

	local job_id = vim.fn.jobstart({ ZIG_EXECUTABLE, "--project-parse-daemon" }, {
		stdout_buffered = false,
		on_stdout = function(_, data)
			handle_project_worker_stdout(worker, data)
		end,
		on_exit = function()
			if project_worker == worker then
				project_worker = nil
			end
			flush_project_worker_fallbacks(worker)
		end,
	})

	if type(job_id) ~= "number" or job_id <= 0 then
		return nil
	end
	worker.job_id = job_id
	return worker
end

---@param worker table
---@param request_id integer
---@param request table
---@return nil
local function cancel_worker_request(worker, request_id, request)
	if worker.pending[request_id] == request then
		worker.pending[request_id] = nil
	end
	if worker.active_id == request_id then
		worker.active_id = nil
		worker.active_lines = {}
		worker.active_error = nil
	end
end

---@param worker table
---@param request_id integer
---@return nil
local function stop_failed_worker(worker, request_id)
	worker.pending[request_id] = nil
	if type(vim.fn.jobstop) == "function" then
		pcall(vim.fn.jobstop, worker.job_id)
	end
	if detect_worker == worker then
		detect_worker = nil
	end
	if project_worker == worker then
		project_worker = nil
	end
end

---@param worker table
---@param payload string
---@return boolean
local function send_worker_payload(worker, payload)
	return pcall(vim.fn.chansend, worker.job_id, payload)
end

---@param worker table
---@param data string[]|nil
---@return nil
function handle_detect_worker_stdout(worker, data)
	if type(data) ~= "table" then
		return
	end

	for _, raw_line in ipairs(data) do
		local line = tostring(raw_line or "")
		if line == "" then
			goto continue
		end

		local begin_id = line:match("^" .. DETECT_RES_BEGIN .. "%s+(%d+)$")
		if begin_id then
			worker.active_id = tonumber(begin_id)
			worker.active_lines = {}
			worker.active_error = nil
			goto continue
		end

		if worker.active_id then
			local error_id, error_message = line:match("^" .. DETECT_RES_ERR .. "%s+(%d+)%s+(.+)$")
			if error_id and tonumber(error_id) == worker.active_id then
				worker.active_error = trim_text(error_message)
				goto continue
			end

			local end_id = line:match("^" .. DETECT_RES_END .. "%s+(%d+)$")
			if end_id and tonumber(end_id) == worker.active_id then
				local request, completed_lines, completed_error = finish_active_request(worker, worker.active_id)
				if request then
					if type(request.callbacks) == "table" then
						for _, callback in ipairs(request.callbacks) do
							if type(callback) == "function" then
								if completed_error and completed_error ~= "" then
									pcall(callback, nil)
								else
									local commands = worker.build_from_names(request.tool or "", completed_lines)
									pcall(callback, copy_string_map(commands))
								end
							end
						end
					end
				end
			else
				if line:sub(1, 1) == "\t" then
					worker.active_lines[#worker.active_lines + 1] = line:sub(2)
				else
					worker.active_lines[#worker.active_lines + 1] = line
				end
			end
		end

		::continue::
	end
end

---@param worker table
---@param data string[]|nil
---@return nil
function handle_project_worker_stdout(worker, data)
	if type(data) ~= "table" then
		return
	end

	worker.stdout_buffer = worker.stdout_buffer or ""
	local chunk = worker.stdout_buffer
	for _, raw_line in ipairs(data) do
		chunk = chunk .. tostring(raw_line or "")
	end
	local trailing_newline = chunk:sub(-1) == "\n"
	---@type string[]
	local lines = {}
	for line in (chunk .. "\n"):gmatch("(.-)\n") do
		lines[#lines + 1] = line
	end
	if not trailing_newline then
		worker.stdout_buffer = table.remove(lines) or ""
	else
		worker.stdout_buffer = ""
	end

	for _, line in ipairs(lines) do
		if line == "" then
			goto continue
		end

		local begin_id = line:match("^" .. PROJECT_RES_BEGIN .. "%s+(%d+)$")
		if begin_id then
			worker.active_id = tonumber(begin_id)
			worker.active_lines = {}
			worker.active_error = nil
			goto continue
		end

		if worker.active_id then
			local error_id, error_message = line:match("^" .. PROJECT_RES_ERR .. "%s+(%d+)%s+(.+)$")
			if error_id and tonumber(error_id) == worker.active_id then
				worker.active_error = trim_text(error_message)
				goto continue
			end

			local end_id = line:match("^" .. PROJECT_RES_END .. "%s+(%d+)$")
			if end_id and tonumber(end_id) == worker.active_id then
				finish_active_request(worker, worker.active_id)
			else
				if line:sub(1, 1) == "\t" then
					worker.active_lines[#worker.active_lines + 1] = line:sub(2)
				else
					worker.active_lines[#worker.active_lines + 1] = line
				end
			end
		end

		::continue::
	end
end

---@return boolean
local function has_zig_backend()
	return type(vim.fn.executable) == "function" and vim.fn.executable(ZIG_EXECUTABLE) == 1
end

---@param build_from_names fun(tool: string, names: string[]): table<string, string>
---@return table|nil
local function ensure_detect_worker(build_from_names)
	if not has_zig_backend() then
		return nil
	end
	if type(vim.fn.jobstart) ~= "function" or type(vim.fn.chansend) ~= "function" then
		return nil
	end
	if detect_worker and type(detect_worker.job_id) == "number" and detect_worker.job_id > 0 then
		return detect_worker
	end
	local worker = start_detect_worker(build_from_names)
	if not worker then
		return nil
	end
	detect_worker = worker
	return worker
end

---@return table|nil
local function ensure_project_worker()
	if not has_zig_backend() then
		return nil
	end
	if type(vim.fn.jobstart) ~= "function" or type(vim.fn.chansend) ~= "function" then
		return nil
	end
	if project_worker and type(project_worker.job_id) == "number" and project_worker.job_id > 0 then
		return project_worker
	end
	local worker = start_project_worker()
	if not worker then
		return nil
	end
	project_worker = worker
	return worker
end

---@param tool string
---@param build_from_names fun(tool: string, names: string[]): table<string, string>
---@return table<string, string>|nil
function M.detect_with_zig_worker(tool, build_from_names)
	if type(vim.wait) ~= "function" then
		return nil
	end
	local worker = ensure_detect_worker(build_from_names)
	if not worker then
		return nil
	end

	worker.next_request_id = worker.next_request_id + 1
	local request_id = worker.next_request_id
	local request = { completed = false, failed = false, lines = {} }
	worker.pending[request_id] = request

	local payload = string.format("%s %d %s\n%s %d\n", DETECT_REQ_BEGIN, request_id, tool, DETECT_REQ_END, request_id)
	local ok_send = send_worker_payload(worker, payload)
	if not ok_send then
		stop_failed_worker(worker, request_id)
		return nil
	end

	local ok_wait = vim.wait(DETECT_WORKER_WAIT_MS, function()
		return request.completed == true
	end, 20)
	if not ok_wait then
		worker.pending[request_id] = nil
		return nil
	end
	if request.failed then
		return nil
	end

	local commands = build_from_names(tool, request.lines)
	if vim.tbl_isempty(commands) then
		return nil
	end
	return commands
end

---@param tool string
---@param on_done fun(commands: table<string, string>|nil):nil
---@param build_from_names fun(tool: string, names: string[]): table<string, string>
---@return boolean
function M.detect_with_zig_worker_async(tool, on_done, build_from_names)
	local worker = ensure_detect_worker(build_from_names)
	if not worker then
		return false
	end

	worker.next_request_id = worker.next_request_id + 1
	local request_id = worker.next_request_id
	local request = {
		tool = tool,
		callbacks = { on_done },
		timer = nil,
	}
	request.timer = start_request_timer(DETECT_WORKER_REQUEST_TIMEOUT_MS, function()
		if worker.pending[request_id] ~= request then
			return
		end
		cancel_worker_request(worker, request_id, request)
		if type(request.callbacks) == "table" then
			for _, callback in ipairs(request.callbacks) do
				if type(callback) == "function" then
					pcall(callback, nil)
				end
			end
		end
		if type(vim.fn.jobstop) == "function" then
			pcall(vim.fn.jobstop, worker.job_id)
		end
		if detect_worker == worker then
			detect_worker = nil
		end
	end)
	worker.pending[request_id] = request

	local payload = string.format("%s %d %s\n%s %d\n", DETECT_REQ_BEGIN, request_id, tool, DETECT_REQ_END, request_id)
	local ok_send = send_worker_payload(worker, payload)
	if not ok_send then
		stop_request_timer(request.timer)
		stop_failed_worker(worker, request_id)
		return false
	end

	return true
end

---@param tool string
---@param build_from_names fun(tool: string, names: string[]): table<string, string>
---@return table<string, string>|nil
function M.detect_with_zig_once(tool, build_from_names)
	if not has_zig_backend() or type(vim.fn.systemlist) ~= "function" then
		return nil
	end
	local output_lines = vim.fn.systemlist({ ZIG_EXECUTABLE, "--detect", "--tool=" .. tool })
	local shell_error = (vim.v and tonumber(vim.v.shell_error)) or 0
	if type(output_lines) ~= "table" or shell_error ~= 0 then
		return nil
	end
	local commands = build_from_names(tool, output_lines)
	if vim.tbl_isempty(commands) then
		return nil
	end
	return commands
end

---@param tool string
---@param on_done fun(commands: table<string, string>|nil):nil
---@param build_from_names fun(tool: string, names: string[]): table<string, string>
---@return boolean
function M.detect_with_zig_once_async(tool, on_done, build_from_names)
	if not has_zig_backend() then
		return false
	end
	if type(vim.fn.jobstart) ~= "function" then
		return false
	end

	---@type string[]
	local output_lines = {}
	local job_id = vim.fn.jobstart({ ZIG_EXECUTABLE, "--detect", "--tool=" .. tool }, {
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data)
			if type(data) ~= "table" then
				return
			end
			for _, raw_line in ipairs(data) do
				local line = trim_text(tostring(raw_line or ""))
				if line ~= "" then
					output_lines[#output_lines + 1] = line
				end
			end
		end,
		on_exit = function(_, exit_code)
			if exit_code ~= 0 then
				on_done(nil)
				return
			end
			on_done(build_from_names(tool, output_lines))
		end,
	})
	return type(job_id) == "number" and job_id > 0
end

---@param kind string
---@param path string
---@param extra_args string[]|nil
---@return string[]|nil
function M.parse_project_lines_once(kind, path, extra_args)
	if not has_zig_backend() then
		return nil
	end
	if type(kind) ~= "string" or kind == "" or type(path) ~= "string" or path == "" then
		return nil
	end
	if type(vim.wait) == "function" then
		local worker = ensure_project_worker()
		if worker then
			worker.next_request_id = worker.next_request_id + 1
			local request_id = worker.next_request_id
			local request = { completed = false, failed = false, lines = {} }
			worker.pending[request_id] = request

			local payload_lines = {
				string.format("%s %d", PROJECT_REQ_BEGIN, request_id),
				"\t--kind=" .. kind,
				"\t--path=" .. path,
			}
			for _, arg in ipairs(extra_args or {}) do
				if type(arg) == "string" and arg ~= "" then
					payload_lines[#payload_lines + 1] = "\t" .. arg
				end
			end
			payload_lines[#payload_lines + 1] = string.format("%s %d", PROJECT_REQ_END, request_id)
			local payload = table.concat(payload_lines, "\n") .. "\n"
			local ok_send = send_worker_payload(worker, payload)
			if ok_send then
				local ok_wait = vim.wait(PROJECT_WORKER_WAIT_MS, function()
					return request.completed == true
				end, 20)
				if ok_wait and not request.failed then
					return request.lines
				end
			end
			stop_failed_worker(worker, request_id)
		end
	end
	if type(vim.fn.systemlist) ~= "function" then
		return nil
	end
	---@type string[]
	local argv = {
		ZIG_EXECUTABLE,
		"--project-parse",
		"--kind=" .. kind,
		"--path=" .. path,
	}
	for _, arg in ipairs(extra_args or {}) do
		if type(arg) == "string" and arg ~= "" then
			argv[#argv + 1] = arg
		end
	end
	local output_lines = vim.fn.systemlist(argv)
	local shell_error = (vim.v and tonumber(vim.v.shell_error)) or 0
	if type(output_lines) ~= "table" or shell_error ~= 0 then
		return nil
	end
	---@type string[]
	local names = {}
	for _, raw_line in ipairs(output_lines) do
		local line = trim_text(tostring(raw_line or ""))
		if line ~= "" then
			names[#names + 1] = line
		end
	end
	return names
end

---@param kind string
---@param path string
---@return string[]|nil
function M.parse_project_names_once(kind, path)
	return M.parse_project_lines_once(kind, path, nil)
end

---@return nil
function M.reset()
	if detect_worker and type(detect_worker.job_id) == "number" and detect_worker.job_id > 0 then
		if type(vim.fn.jobstop) == "function" then
			pcall(vim.fn.jobstop, detect_worker.job_id)
		end
	end
	if project_worker and type(project_worker.job_id) == "number" and project_worker.job_id > 0 then
		if type(vim.fn.jobstop) == "function" then
			pcall(vim.fn.jobstop, project_worker.job_id)
		end
	end
	detect_worker = nil
	project_worker = nil
end

return M
