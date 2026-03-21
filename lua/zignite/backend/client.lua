---@type table
local M = {}

---@param value string
---@return string
local function trim_text(value)
	if type(value) ~= "string" then
		return ""
	end
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param timeout_ms integer|nil
---@param callback fun():nil
---@return table|nil
local function start_request_timer(timeout_ms, callback)
	if type(timeout_ms) ~= "number" or timeout_ms <= 0 then
		return nil
	end
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

---@param worker table
---@return nil
local function clear_active_state(worker)
	worker.active_id = nil
	worker.active_lines = {}
	worker.active_error = nil
end

---@param worker table
---@param request_id integer
---@return table|nil, string[], string|nil
local function finish_active_request(worker, request_id)
	local request = worker.pending[request_id]
	worker.pending[request_id] = nil
	local completed_lines = worker.active_lines
	local completed_error = worker.active_error
	clear_active_state(worker)
	if request then
		stop_request_timer(request.timer)
		request.lines = completed_lines
		request.completed = true
		request.error = completed_error
		request.failed = completed_error ~= nil and completed_error ~= ""
	end
	return request, completed_lines, completed_error
end

---@param line string
---@return boolean
local function should_skip_line(line)
	return line == ""
end

---@param worker table
---@param line string
---@return nil
local function append_active_line(worker, line)
	if line:sub(1, 1) == "\t" then
		worker.active_lines[#worker.active_lines + 1] = line:sub(2)
	else
		worker.active_lines[#worker.active_lines + 1] = line
	end
end

---@param worker table
---@param line string
---@param protocol table
---@param on_complete fun(request: table|nil, completed_lines: string[], completed_error: string|nil):nil
---@return nil
local function process_protocol_line(worker, line, protocol, on_complete)
	if should_skip_line(line) then
		return
	end

	local begin_id = line:match("^" .. protocol.res_begin .. "%s+(%d+)$")
	if begin_id then
		clear_active_state(worker)
		worker.active_id = tonumber(begin_id)
		return
	end

	if not worker.active_id then
		return
	end

	local error_id, error_message = line:match("^" .. protocol.res_err .. "%s+(%d+)%s+(.+)$")
	if error_id and tonumber(error_id) == worker.active_id then
		worker.active_error = trim_text(error_message)
		return
	end

	local end_id = line:match("^" .. protocol.res_end .. "%s+(%d+)$")
	if end_id and tonumber(end_id) == worker.active_id then
		local request, completed_lines, completed_error = finish_active_request(worker, worker.active_id)
		on_complete(request, completed_lines, completed_error)
		return
	end

	append_active_line(worker, line)
end

---@param _worker table
---@param data string[]|nil
---@return string[]
local function decode_plain_lines(_worker, data)
	if type(data) ~= "table" then
		return {}
	end
	---@type string[]
	local lines = {}
	for _, raw_line in ipairs(data) do
		lines[#lines + 1] = tostring(raw_line or "")
	end
	return lines
end

---@param worker table
---@param data string[]|nil
---@return string[]
local function decode_buffered_lines(worker, data)
	if type(data) ~= "table" then
		return {}
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
	return lines
end

---@param request table
---@param payload string[]|nil
---@return nil
local function complete_request_callbacks(request, payload)
	if type(request.callbacks) ~= "table" then
		return
	end
	for _, callback in ipairs(request.callbacks) do
		if type(callback) == "function" then
			pcall(callback, payload)
		end
	end
end

---@param worker table
---@return nil
local function flush_worker(worker)
	if not worker or type(worker.pending) ~= "table" then
		return
	end
	for _, request in pairs(worker.pending) do
		stop_request_timer(request.timer)
		request.failed = true
		request.completed = true
		complete_request_callbacks(request, nil)
	end
	worker.pending = {}
	clear_active_state(worker)
	if worker.stdout_buffer ~= nil then
		worker.stdout_buffer = ""
	end
end

---@param worker table
---@param initial table|nil
---@return integer, table
local function start_worker_request(worker, initial)
	worker.next_request_id = worker.next_request_id + 1
	local request_id = worker.next_request_id
	local request = initial or {}
	request.completed = false
	request.failed = false
	request.lines = request.lines or {}
	worker.pending[request_id] = request
	return request_id, request
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
		clear_active_state(worker)
	end
end

---@param client table
---@param worker table
---@param request_id integer
---@return nil
local function stop_failed_worker(client, worker, request_id)
	worker.pending[request_id] = nil
	if type(vim.fn.jobstop) == "function" then
		pcall(vim.fn.jobstop, worker.job_id)
	end
	if client.worker == worker then
		client.worker = nil
	end
end

---@param worker table
---@param payload string
---@return boolean
local function send_worker_payload(worker, payload)
	return pcall(vim.fn.chansend, worker.job_id, payload)
end

---@param opts table
---@return table
function M.new(opts)
	local client = {
		executable = opts.executable,
		worker = nil,
	}

	local protocol = opts.protocol
	local worker_wait_ms = tonumber(opts.worker_wait_ms) or 1200
	local request_timeout_ms = tonumber(opts.request_timeout_ms) or 0
	local decode_lines = opts.buffered_stdout and decode_buffered_lines or decode_plain_lines

	---@return boolean
	function client.has_backend()
		return type(vim.fn.executable) == "function" and vim.fn.executable(client.executable) == 1
	end

	---@return boolean
	local function can_use_worker_backend()
		return client.has_backend() and type(vim.fn.jobstart) == "function" and type(vim.fn.chansend) == "function"
	end

	---@return table|nil
	local function ensure_worker()
		if not can_use_worker_backend() then
			return nil
		end
		if client.worker and type(client.worker.job_id) == "number" and client.worker.job_id > 0 then
			return client.worker
		end

		local worker = {
			job_id = nil,
			next_request_id = 0,
			pending = {},
			active_id = nil,
			active_lines = {},
			active_error = nil,
		}
		if opts.buffered_stdout then
			worker.stdout_buffer = ""
		end

		local job_id = vim.fn.jobstart(opts.worker_argv, {
			stdout_buffered = false,
			on_stdout = function(_, data)
				for _, line in ipairs(decode_lines(worker, data)) do
					process_protocol_line(worker, line, protocol, function(request, completed_lines, completed_error)
						if request then
							if completed_error and completed_error ~= "" then
								complete_request_callbacks(request, nil)
							else
								complete_request_callbacks(request, completed_lines)
							end
						end
					end)
				end
			end,
			on_exit = function()
				if client.worker == worker then
					client.worker = nil
				end
				flush_worker(worker)
			end,
		})
		if type(job_id) ~= "number" or job_id <= 0 then
			return nil
		end
		worker.job_id = job_id
		client.worker = worker
		return worker
	end

	---@param params table
	---@return string[]|nil
	function client.sync_request(params)
		if type(vim.wait) ~= "function" then
			return nil
		end
		local worker = ensure_worker()
		if not worker then
			return nil
		end

		local request_id, request = start_worker_request(worker, { params = params })
		local payload = opts.build_worker_payload(request_id, params)
		if type(payload) ~= "string" or payload == "" then
			cancel_worker_request(worker, request_id, request)
			return nil
		end
		if not send_worker_payload(worker, payload) then
			stop_failed_worker(client, worker, request_id)
			return nil
		end

		local ok_wait = vim.wait(worker_wait_ms, function()
			return request.completed == true
		end, 20)
		if not ok_wait then
			if opts.reset_on_sync_timeout then
				stop_failed_worker(client, worker, request_id)
			else
				cancel_worker_request(worker, request_id, request)
			end
			return nil
		end
		if request.failed then
			return nil
		end
		return request.lines
	end

	---@param params table
	---@param on_done fun(lines: string[]|nil):nil
	---@return boolean
	function client.async_request(params, on_done)
		local worker = ensure_worker()
		if not worker then
			return false
		end

		local request_id, request = start_worker_request(worker, {
			params = params,
			callbacks = { on_done },
			timer = nil,
		})
		request.timer = start_request_timer(request_timeout_ms, function()
			if worker.pending[request_id] ~= request then
				return
			end
			cancel_worker_request(worker, request_id, request)
			complete_request_callbacks(request, nil)
			if opts.reset_on_async_timeout ~= false and type(vim.fn.jobstop) == "function" then
				pcall(vim.fn.jobstop, worker.job_id)
			end
			if client.worker == worker then
				client.worker = nil
			end
		end)

		local payload = opts.build_worker_payload(request_id, params)
		if type(payload) ~= "string" or payload == "" then
			stop_request_timer(request.timer)
			cancel_worker_request(worker, request_id, request)
			return false
		end
		if not send_worker_payload(worker, payload) then
			stop_request_timer(request.timer)
			stop_failed_worker(client, worker, request_id)
			return false
		end

		return true
	end

	---@param params table
	---@return string[]|nil
	function client.once_request(params)
		if not client.has_backend() or type(vim.fn.systemlist) ~= "function" then
			return nil
		end
		local argv = opts.build_once_argv(params)
		if type(argv) ~= "table" or #argv == 0 then
			return nil
		end
		local output_lines = vim.fn.systemlist(argv)
		local shell_error = (vim.v and tonumber(vim.v.shell_error)) or 0
		if type(output_lines) ~= "table" or shell_error ~= 0 then
			return nil
		end

		---@type string[]
		local lines = {}
		for _, raw_line in ipairs(output_lines) do
			local line = trim_text(tostring(raw_line or ""))
			if line ~= "" then
				lines[#lines + 1] = line
			end
		end
		return lines
	end

	---@param params table
	---@param on_done fun(lines: string[]|nil):nil
	---@return boolean
	function client.once_request_async(params, on_done)
		if not client.has_backend() or type(vim.fn.jobstart) ~= "function" then
			return false
		end
		local argv = opts.build_once_argv(params)
		if type(argv) ~= "table" or #argv == 0 then
			return false
		end

		---@type string[]
		local output_lines = {}
		local job_id = vim.fn.jobstart(argv, {
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
				on_done(output_lines)
			end,
		})
		return type(job_id) == "number" and job_id > 0
	end

	---@return nil
	function client.reset()
		if client.worker and type(client.worker.job_id) == "number" and client.worker.job_id > 0 then
			if type(vim.fn.jobstop) == "function" then
				pcall(vim.fn.jobstop, client.worker.job_id)
			end
		end
		client.worker = nil
	end

	return client
end

return M
