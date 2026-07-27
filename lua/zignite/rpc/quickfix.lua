local backend_client = require("zignite.rpc.transport")

---@type table
local M = {}

local QUICKFIX_WORKER_REQUEST_TIMEOUT_MS = 3000
local QUICKFIX_BACKEND = backend_client.ZIG_EXECUTABLE
local QUICKFIX_FLAG_SPECS = {
	{ key = "max_lines", cli = "max-lines" },
	{ key = "max_bytes", cli = "max-bytes" },
	{ key = "strip_ansi", cli = "strip-ansi" },
	{ key = "strip_max_lines", cli = "strip-max-lines" },
	{ key = "parse_diagnostics", cli = "parse-diagnostics" },
}
local QUICKFIX_PROTOCOL = {
	res_begin = "@@ZQF_RES_BEGIN",
	res_end = "@@ZQF_RES_END",
	res_err = "@@ZQF_RES_ERR",
	req_begin = "@@ZQF_BEGIN",
	req_end = "@@ZQF_END",
}

---@param require_chanclose boolean|nil
---@return boolean
local function can_use_backend(require_chanclose)
	return backend_client.supports_stream_backend(require_chanclose)
end

---@param value boolean|string|number|nil
---@param default boolean|string|number|nil
---@return string
local function bool_to_flag(value, default)
	local resolved = value
	if resolved == nil then
		resolved = default
	end
	if type(resolved) == "string" then
		local lowered = resolved:lower()
		if lowered == "0" or lowered == "false" or lowered == "no" then
			resolved = false
		else
			resolved = true
		end
	elseif type(resolved) == "number" then
		resolved = resolved ~= 0
	end
	return resolved and "1" or "0"
end

---@param quickfix_opts table
---@return table
local function quickfix_flag_values(quickfix_opts)
	local max_lines = tonumber(quickfix_opts.max_lines) or 1000
	local max_bytes = tonumber(quickfix_opts.max_bytes) or 262144
	local strip_max_lines = tonumber(quickfix_opts.strip_ansi_max_lines) or 400
	if max_lines < 1 then
		max_lines = 1
	end
	if max_bytes < 1 then
		max_bytes = 1
	end
	if strip_max_lines < 1 then
		strip_max_lines = 1
	end

	return {
		max_lines = max_lines,
		max_bytes = max_bytes,
		strip_ansi = bool_to_flag(quickfix_opts.strip_ansi, true),
		strip_max_lines = strip_max_lines,
		parse_diagnostics = bool_to_flag(quickfix_opts.parse_diagnostics, true),
	}
end

---@param flags table
---@return string[]
local function ordered_flag_values(flags)
	---@type string[]
	local values = {}
	for _, spec in ipairs(QUICKFIX_FLAG_SPECS) do
		values[#values + 1] = tostring(flags[spec.key])
	end
	return values
end

---@param flags table
---@return string[]
local function build_backend_command(flags)
	local cmd = {
		QUICKFIX_BACKEND,
		"--quickfix",
	}
	for _, spec in ipairs(QUICKFIX_FLAG_SPECS) do
		cmd[#cmd + 1] = "--" .. spec.cli .. "=" .. tostring(flags[spec.key])
	end
	return cmd
end

---@param output_lines string[]
---@param data string[]|nil
---@return nil
local function append_output_lines(output_lines, data)
	if type(data) ~= "table" then
		return
	end
	for _, line in ipairs(data) do
		if line ~= nil and line ~= "" then
			output_lines[#output_lines + 1] = line
		end
	end
end

---@param request_id integer
---@param params table
---@return string
local function build_worker_payload(request_id, params)
	local flags = params.flags or {}
	local raw_lines = params.raw_lines or {}
	local flag_values = ordered_flag_values(flags)
	local payload = {
		string.format("%s %d %s", QUICKFIX_PROTOCOL.req_begin, request_id, table.concat(flag_values, " ")),
	}
	for _, line in ipairs(raw_lines) do
		payload[#payload + 1] = "\t" .. line
	end
	payload[#payload + 1] = string.format("%s %d", QUICKFIX_PROTOCOL.req_end, request_id)
	return table.concat(payload, "\n") .. "\n"
end

local quickfix_client = backend_client.new({
	executable = QUICKFIX_BACKEND,
	worker_argv = { QUICKFIX_BACKEND, "--daemon" },
	protocol = QUICKFIX_PROTOCOL,
	request_timeout_ms = QUICKFIX_WORKER_REQUEST_TIMEOUT_MS,
	build_worker_payload = build_worker_payload,
	build_once_argv = function(_)
		return nil
	end,
})

---@param lines string[]
---@param force_truncated boolean
---@return string[]
function M.with_truncation_notice(lines, force_truncated)
	if not force_truncated or lines[1] == "[zignite] quickfix output truncated" then
		return lines
	end

	---@type string[]
	local out = { "[zignite] quickfix output truncated" }
	for i = 1, #lines do
		out[#out + 1] = lines[i]
	end
	return out
end

---@param raw_lines string[]
---@param flags table
---@param force_truncated boolean
---@param on_success fun(lines: string[]):nil
---@param on_fallback fun():nil
---@return nil
local function run_once(raw_lines, flags, force_truncated, on_success, on_fallback)
	if not can_use_backend(true) then
		on_fallback()
		return
	end

	local cmd = build_backend_command(flags)

	---@type string[]
	local output_lines = {}
	local failed = false
	local ok_job, job_id = pcall(vim.fn.jobstart, cmd, {
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data)
			append_output_lines(output_lines, data)
		end,
		on_exit = function(_, exit_code, data)
			if failed then
				return
			end
			if exit_code == 0 then
				local lines = output_lines
				-- Neovim >= 0.10 delivers buffered output in on_exit's third argument
				if type(data) == "table" and #data > 0 then
					lines = {}
					append_output_lines(lines, data)
				end
				on_success(M.with_truncation_notice(lines, force_truncated))
				return
			end
			failed = true
			on_fallback()
		end,
	})

	if not ok_job or type(job_id) ~= "number" or job_id <= 0 then
		on_fallback()
		return
	end

	local function stop_job()
		if type(vim.fn.jobstop) == "function" then
			pcall(vim.fn.jobstop, job_id)
		end
	end

	local payload = table.concat(raw_lines, "\n")
	if #payload > 0 then
		local ok_send = pcall(vim.fn.chansend, job_id, payload .. "\n")
		if not ok_send then
			failed = true
			stop_job()
			on_fallback()
			return
		end
	end
	local ok_close = pcall(vim.fn.chanclose, job_id, "stdin")
	if not ok_close then
		-- Process may have already exited; on_exit handles the result.
	end
end

---@param raw_lines string[]
---@param flags table
---@param force_truncated boolean
---@param on_success fun(lines: string[]):nil
---@param on_fallback fun():nil
---@return boolean
local function run_worker(raw_lines, flags, force_truncated, on_success, on_fallback)
	return quickfix_client.async_request({
		flags = flags,
		raw_lines = raw_lines,
	}, function(lines)
		if type(lines) ~= "table" then
			on_fallback()
			return
		end
		on_success(M.with_truncation_notice(lines, force_truncated))
	end)
end

---@param quickfix_opts table
---@return boolean
function M.prefers_backend(quickfix_opts)
	local processor = tostring(quickfix_opts.processor or "auto"):lower()
	if processor == "zig" then
		return true
	end
	if processor == "lua" then
		return false
	end
	return can_use_backend(false)
end

---@param raw_lines string[]
---@param quickfix_opts table
---@param force_truncated boolean
---@param on_success fun(lines: string[]):nil
---@param on_fallback fun():nil
---@return nil
function M.run_async(raw_lines, quickfix_opts, force_truncated, on_success, on_fallback)
	local flags = quickfix_flag_values(quickfix_opts)
	if quickfix_opts.zig_worker ~= false then
		local ok = run_worker(raw_lines, flags, force_truncated, on_success, on_fallback)
		if ok then
			return
		end
	end
	run_once(raw_lines, flags, force_truncated, on_success, on_fallback)
end

---@return nil
function M.reset()
	quickfix_client.reset()
end

return M
