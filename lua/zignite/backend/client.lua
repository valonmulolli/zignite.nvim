---@type table
local M = {}

---@type table<string, table>
local shared_workers = {}

---@return string
local function get_plugin_path()
	local source = debug.getinfo(1, "S").source
	if source:sub(1, 1) == "@" then
		source = source:sub(2)
	end

	local normalize = vim.fs and vim.fs.normalize
	if source:sub(1, 1) ~= "/" then
		local cwd
		if vim.uv and type(vim.uv.cwd) == "function" then
			cwd = vim.uv.cwd()
		elseif vim.loop and type(vim.loop.cwd) == "function" then
			cwd = vim.loop.cwd()
		elseif vim.fn and type(vim.fn.getcwd) == "function" then
			cwd = vim.fn.getcwd()
		else
			cwd = os.getenv("PWD") or "."
		end
		source = cwd .. "/" .. source
	end
	if normalize then
		source = normalize(source)
	end

	for _ = 1, 4 do
		source = source:gsub("/[^/]+$", "")
	end
	return source
end

M.ZIG_EXECUTABLE = get_plugin_path() .. "/zig/zig-out/bin/zignite"

---@return boolean
function M.has_backend()
	return type(vim.fn.executable) == "function" and vim.fn.executable(M.ZIG_EXECUTABLE) == 1
end

---@param final_command string|string[]
---@param argv_command string[]|nil
---@return string|string[]
function M.build_system_command(final_command, argv_command)
	if M.has_backend() then
		---@type string[]
		local system_command = { M.ZIG_EXECUTABLE }
		local config = require("zignite.config")
		if config.options.timeout and type(config.options.timeout) == "number" then
			system_command[#system_command + 1] = "--timeout=" .. config.options.timeout
		end
		if argv_command and #argv_command > 0 then
			system_command[#system_command + 1] = "--argv"
			for _, arg in ipairs(argv_command) do
				system_command[#system_command + 1] = arg
			end
		else
			system_command[#system_command + 1] = final_command
		end
		return system_command
	end

	if argv_command and #argv_command > 0 then
		return argv_command
	end
	return final_command
end

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

---@param line string
---@return boolean
local function should_skip_line(line)
	return line == ""
end

---@param request table
---@param line string
---@return nil
local function append_request_line(request, line)
	if line:sub(1, 1) == "\t" then
		request.lines[#request.lines + 1] = line:sub(2)
	else
		request.lines[#request.lines + 1] = line
	end
end

---@param data string[]|nil
---@return string[]
local function decode_buffered_lines(buffer, data)
	if type(data) ~= "table" then
		return {}
	end

	if #data == 0 then
		return {}
	end

	---@type string[]
	local lines = {}
	local first = tostring(data[1] or "")
	lines[1] = (buffer.value or "") .. first

	for index = 2, #data - 1 do
		lines[#lines + 1] = tostring(data[index] or "")
	end

	buffer.value = tostring(data[#data] or "")
	if #data == 1 then
		buffer.value = lines[1]
		return {}
	end

	if buffer.value == "" then
		buffer.value = ""
		return lines
	end

	return lines
end

---@param argv string[]
---@return string
local function worker_key(argv)
	return table.concat(argv, "\0")
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

---@param request table
---@param payload string[]|nil
---@param failed boolean
---@return nil
local function finalize_request(request, payload, failed)
	if request.completed then
		return
	end
	request.completed = true
	request.failed = failed == true
	request.lines = type(payload) == "table" and payload or {}
	stop_request_timer(request.timer)
	complete_request_callbacks(request, request.failed and nil or request.lines)
end

---@param queue table[]
---@param request table
---@return boolean
local function remove_queued_request(queue, request)
	for index, queued in ipairs(queue) do
		if queued == request then
			table.remove(queue, index)
			return true
		end
	end
	return false
end

---@param worker table
---@return nil
local function start_next_request(worker)
	if worker.stopped or worker.active_request or #worker.queue == 0 then
		return
	end

	local request = table.remove(worker.queue, 1)
	worker.active_request = request
	request.lines = {}
	request.error = nil
	request.started = false

	local ok_send = pcall(vim.fn.chansend, worker.job_id, request.payload)
	if ok_send then
		return
	end

	worker.active_request = nil
	finalize_request(request, nil, true)
	if type(vim.fn.jobstop) == "function" then
		pcall(vim.fn.jobstop, worker.job_id)
	end
end

---@param worker table
---@param skip_jobstop boolean|nil
---@return nil
local function stop_shared_worker(worker, skip_jobstop)
	if not worker or worker.stopped then
		return
	end
	worker.stopped = true

	if shared_workers[worker.key] == worker then
		shared_workers[worker.key] = nil
	end

	if not skip_jobstop and type(vim.fn.jobstop) == "function" then
		pcall(vim.fn.jobstop, worker.job_id)
	end

	if worker.active_request then
		finalize_request(worker.active_request, nil, true)
		worker.active_request = nil
	end

	for _, request in ipairs(worker.queue) do
		finalize_request(request, nil, true)
	end
	worker.queue = {}
	worker.stdout_buffer.value = ""
end

---@param worker table
---@param line string
---@return nil
local function process_protocol_line(worker, line)
	if should_skip_line(line) then
		return
	end

	local request = worker.active_request
	if not request then
		return
	end
	local protocol = request.protocol

	local begin_id = line:match("^" .. protocol.res_begin .. "%s+(%d+)$")
	if begin_id and tonumber(begin_id) == request.request_id then
		request.lines = {}
		request.error = nil
		request.started = true
		return
	end

	if not request.started then
		return
	end

	local error_id, error_message = line:match("^" .. protocol.res_err .. "%s+(%d+)%s+(.+)$")
	if error_id and tonumber(error_id) == request.request_id then
		request.error = trim_text(error_message)
		return
	end

	local end_id = line:match("^" .. protocol.res_end .. "%s+(%d+)$")
	if end_id and tonumber(end_id) == request.request_id then
		if request.error and request.error ~= "" then
			finalize_request(request, nil, true)
		else
			finalize_request(request, request.lines, false)
		end
		worker.active_request = nil
		start_next_request(worker)
		return
	end

	append_request_line(request, line)
end

---@param opts table
---@return table|nil
local function ensure_shared_worker(opts)
	if type(vim.fn.jobstart) ~= "function" or type(vim.fn.chansend) ~= "function" then
		return nil
	end

	local key = worker_key(opts.worker_argv)
	local existing = shared_workers[key]
	if existing and type(existing.job_id) == "number" and existing.job_id > 0 and not existing.stopped then
		return existing
	end

	local worker = {
		key = key,
		job_id = nil,
		next_request_id = 0,
		queue = {},
		active_request = nil,
		stdout_buffer = { value = "" },
		stopped = false,
	}

	local job_id = vim.fn.jobstart(opts.worker_argv, {
		stdout_buffered = false,
		on_stdout = function(_, data)
			for _, line in ipairs(decode_buffered_lines(worker.stdout_buffer, data)) do
				process_protocol_line(worker, line)
			end
		end,
		on_exit = function()
			stop_shared_worker(worker, true)
		end,
	})
	if type(job_id) ~= "number" or job_id <= 0 then
		return nil
	end

	worker.job_id = job_id
	shared_workers[key] = worker
	return worker
end

---@param opts table
---@return table
function M.new(opts)
	local client = {
		executable = opts.executable,
		worker_key = worker_key(opts.worker_argv),
	}

	local protocol = opts.protocol
	local worker_wait_ms = tonumber(opts.worker_wait_ms) or 1200
	local request_timeout_ms = tonumber(opts.request_timeout_ms) or 0

	---@return boolean
	function client.has_backend()
		return type(vim.fn.executable) == "function" and vim.fn.executable(client.executable) == 1
	end

	---@return boolean
	local function can_use_worker_backend()
		return client.has_backend() and type(vim.fn.jobstart) == "function" and type(vim.fn.chansend) == "function"
	end

	---@param params table
	---@param callbacks function[]|nil
	---@param timer table|nil
	---@return table|nil, table|nil
	local function enqueue_request(params, callbacks, timer)
		if not can_use_worker_backend() then
			stop_request_timer(timer)
			return nil, nil
		end

		local worker = ensure_shared_worker(opts)
		if not worker then
			stop_request_timer(timer)
			return nil, nil
		end

		worker.next_request_id = worker.next_request_id + 1
		local request_id = worker.next_request_id
		local payload = opts.build_worker_payload(request_id, params)
		if type(payload) ~= "string" or payload == "" then
			stop_request_timer(timer)
			return nil, nil
		end

		local request = {
			worker = worker,
			request_id = request_id,
			params = params,
			protocol = protocol,
			payload = payload,
			callbacks = callbacks,
			timer = timer,
			lines = {},
			error = nil,
			started = false,
			completed = false,
			failed = false,
		}
		worker.queue[#worker.queue + 1] = request
		start_next_request(worker)
		return worker, request
	end

	---@param params table
	---@return string[]|nil
	function client.sync_request(params)
		if type(vim.wait) ~= "function" then
			return nil
		end

		local worker, request = enqueue_request(params, nil, nil)
		if not worker or not request then
			return nil
		end

		local ok_wait = vim.wait(worker_wait_ms, function()
			return request.completed == true
		end, 20)
		if not ok_wait then
			if worker.active_request == request then
				stop_shared_worker(worker)
			elseif remove_queued_request(worker.queue, request) then
				finalize_request(request, nil, true)
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
		local worker, request = enqueue_request(params, { on_done }, nil)
		if not worker or not request then
			return false
		end

		request.timer = start_request_timer(request_timeout_ms, function()
			if request.completed then
				return
			end
			if worker.active_request == request then
				stop_shared_worker(worker)
			elseif remove_queued_request(worker.queue, request) then
				finalize_request(request, nil, true)
			end
		end)
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
		local worker = shared_workers[client.worker_key]
		if worker then
			stop_shared_worker(worker)
		end
	end

	return client
end

return M
