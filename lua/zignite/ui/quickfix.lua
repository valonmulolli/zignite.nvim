local backend_client = require("zignite.backend.client")
local shared = require("zignite.ui.shared")

---@type table
local M = {}

local QUICKFIX_WORKER_REQUEST_TIMEOUT_MS = 3000
local QUICKFIX_BACKEND = shared.get_plugin_path() .. "/zig/zig-out/bin/zignite"
local QUICKFIX_PROTOCOL = {
	res_begin = "@@ZQF_RES_BEGIN",
	res_end = "@@ZQF_RES_END",
	res_err = "@@ZQF_RES_ERR",
	req_begin = "@@ZQF_BEGIN",
	req_end = "@@ZQF_END",
}

---@param lines string[]
---@return nil
local function set_quickfix_lines(lines)
	vim.schedule(function()
		vim.fn.setqflist({}, " ", {
			title = "Zignite Output",
			lines = lines,
		})
	end)
end

---@param require_chanclose boolean|nil
---@return boolean
local function can_use_quickfix_backend(require_chanclose)
	if type(vim.fn.executable) ~= "function" or vim.fn.executable(QUICKFIX_BACKEND) ~= 1 then
		return false
	end
	if type(vim.fn.jobstart) ~= "function" or type(vim.fn.chansend) ~= "function" then
		return false
	end
	if require_chanclose and type(vim.fn.chanclose) ~= "function" then
		return false
	end
	return true
end

---@param lines string[]
---@return string[]
local function copy_lines(lines)
	---@type string[]
	local out = {}
	for i = 1, #lines do
		out[i] = lines[i]
	end
	return out
end

---@param lines string[]
---@return string[]
local function append_truncation_notice(lines)
	---@type string[]
	local out = { "[zignite] quickfix output truncated" }
	for i = 1, #lines do
		out[#out + 1] = lines[i]
	end
	return out
end

---@param lines string[]
---@param force_truncated boolean
---@return string[]
local function with_truncation_notice(lines, force_truncated)
	if not force_truncated or lines[1] == "[zignite] quickfix output truncated" then
		return lines
	end
	return append_truncation_notice(lines)
end

---@param lines string[]
---@param max_bytes integer
---@return string[], boolean
local function tail_lines_by_bytes(lines, max_bytes)
	if max_bytes == nil or max_bytes <= 0 or #lines == 0 then
		return lines, false
	end

	local used = 0
	local start_idx = #lines + 1
	for i = #lines, 1, -1 do
		used = used + #lines[i] + 1
		if used > max_bytes then
			break
		end
		start_idx = i
	end

	if start_idx <= 1 then
		return lines, false
	end

	if start_idx > #lines then
		return { lines[#lines] }, true
	end

	---@type string[]
	local out = {}
	for i = start_idx, #lines do
		out[#out + 1] = lines[i]
	end
	return out, true
end

---@param buf integer
---@param quickfix_opts table
---@return string[], boolean, integer
local function collect_lua_quickfix_lines(buf, quickfix_opts)
	local max_lines = tonumber(quickfix_opts.max_lines) or 1000
	if max_lines < 1 then
		max_lines = 1
	end

	local total_lines = vim.api.nvim_buf_line_count(buf)
	local start_line = math.max(0, total_lines - max_lines)
	local lines = vim.api.nvim_buf_get_lines(buf, start_line, -1, false)
	local truncated = start_line > 0

	local max_bytes = tonumber(quickfix_opts.max_bytes) or 262144
	local byte_truncated
	lines, byte_truncated = tail_lines_by_bytes(lines, max_bytes)
	truncated = truncated or byte_truncated

	return lines, truncated, total_lines
end

---@param quickfix_opts table
---@param total_lines integer
---@return string
local function choose_quickfix_processor(quickfix_opts, total_lines)
	local processor = tostring(quickfix_opts.processor or "auto"):lower()
	if processor == "lua" or processor == "zig" then
		return processor
	end

	local zig_min_lines = tonumber(quickfix_opts.zig_min_lines) or 300
	if zig_min_lines < 1 then
		zig_min_lines = 1
	end

	if total_lines >= zig_min_lines then
		return "zig"
	end
	return "lua"
end

---@param lines string[]
---@param quickfix_opts table
---@param truncated boolean
---@return nil
local function populate_quickfix_lua(lines, quickfix_opts, truncated)
	local processed = copy_lines(lines)
	if truncated then
		processed = append_truncation_notice(processed)
	end

	if quickfix_opts.strip_ansi == false then
		set_quickfix_lines(processed)
		return
	end

	local chunk_size = tonumber(quickfix_opts.strip_chunk_size) or 200
	if chunk_size < 1 then
		chunk_size = 1
	end

	local strip_max_lines = tonumber(quickfix_opts.strip_ansi_max_lines) or #processed
	if strip_max_lines < 1 then
		strip_max_lines = #processed
	end
	local strip_start = math.max(1, #processed - strip_max_lines + 1)

	local idx = strip_start
	---@return nil
	local function strip_next_chunk()
		local upper = math.min(#processed, idx + chunk_size - 1)
		for i = idx, upper do
			if processed[i]:find("\27", 1, true) then
				processed[i] = processed[i]:gsub("\27%[[0-9;]*m", "")
			end
		end
		idx = upper + 1

		if idx <= #processed and quickfix_opts.async_strip ~= false then
			vim.schedule(strip_next_chunk)
			return
		end
		if idx <= #processed then
			strip_next_chunk()
			return
		end
		set_quickfix_lines(processed)
	end

	strip_next_chunk()
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
local function build_quickfix_backend_command(flags)
	return {
		QUICKFIX_BACKEND,
		"--quickfix",
		"--max-lines=" .. flags.max_lines,
		"--max-bytes=" .. flags.max_bytes,
		"--strip-ansi=" .. flags.strip_ansi,
		"--strip-max-lines=" .. flags.strip_max_lines,
		"--parse-diagnostics=" .. flags.parse_diagnostics,
	}
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
local function build_quickfix_worker_payload(request_id, params)
	local flags = params.flags or {}
	local raw_lines = params.raw_lines or {}
	local payload = {
		string.format(
			"%s %d %d %d %s %d %s",
			QUICKFIX_PROTOCOL.req_begin,
			request_id,
			flags.max_lines,
			flags.max_bytes,
			flags.strip_ansi,
			flags.strip_max_lines,
			flags.parse_diagnostics
		),
	}
	for _, line in ipairs(raw_lines) do
		payload[#payload + 1] = "\t" .. line
	end
	payload[#payload + 1] = string.format("%s %d", QUICKFIX_PROTOCOL.req_end, request_id)
	return table.concat(payload, "\n") .. "\n"
end

local quickfix_client = backend_client.new({
	executable = QUICKFIX_BACKEND,
	worker_argv = { QUICKFIX_BACKEND, "--quickfix-daemon" },
	protocol = QUICKFIX_PROTOCOL,
	request_timeout_ms = QUICKFIX_WORKER_REQUEST_TIMEOUT_MS,
	build_worker_payload = build_quickfix_worker_payload,
})

---@param raw_lines string[]
---@param quickfix_opts table
---@param force_truncated boolean
---@param on_success fun(lines: string[]):nil
---@param on_fallback fun():nil
---@return nil
local function run_quickfix_with_zig_once(raw_lines, quickfix_opts, force_truncated, on_success, on_fallback)
	if not can_use_quickfix_backend(true) then
		on_fallback()
		return
	end

	local flags = quickfix_flag_values(quickfix_opts)
	local cmd = build_quickfix_backend_command(flags)

	---@type string[]
	local output_lines = {}
	local failed = false
	local job_id = vim.fn.jobstart(cmd, {
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data)
			append_output_lines(output_lines, data)
		end,
		on_exit = function(_, exit_code)
			if failed then
				return
			end
			if exit_code == 0 then
				on_success(with_truncation_notice(output_lines, force_truncated))
				return
			end
			failed = true
			on_fallback()
		end,
	})

	if type(job_id) ~= "number" or job_id <= 0 then
		on_fallback()
		return
	end

	local payload = table.concat(raw_lines, "\n")
	if #payload > 0 then
		local ok_send = pcall(vim.fn.chansend, job_id, payload .. "\n")
		if not ok_send then
			failed = true
			on_fallback()
			return
		end
	end
	local ok_close = pcall(vim.fn.chanclose, job_id, "stdin")
	if not ok_close then
		failed = true
		on_fallback()
	end
end

---@param raw_lines string[]
---@param quickfix_opts table
---@param force_truncated boolean
---@param on_success fun(lines: string[]):nil
---@param on_fallback fun():nil
---@return boolean
local function run_quickfix_with_zig_worker(raw_lines, quickfix_opts, force_truncated, on_success, on_fallback)
	local flags = quickfix_flag_values(quickfix_opts)
	return quickfix_client.async_request({
		flags = flags,
		raw_lines = raw_lines,
	}, function(lines)
		if type(lines) ~= "table" then
			on_fallback()
			return
		end
		on_success(with_truncation_notice(lines, force_truncated))
	end)
end

---@param raw_lines string[]
---@param quickfix_opts table
---@param force_truncated boolean
---@param on_success fun(lines: string[]):nil
---@param on_fallback fun():nil
---@return nil
local function run_quickfix_with_zig(raw_lines, quickfix_opts, force_truncated, on_success, on_fallback)
	if quickfix_opts.zig_worker ~= false then
		local ok = run_quickfix_with_zig_worker(raw_lines, quickfix_opts, force_truncated, on_success, on_fallback)
		if ok then
			return
		end
	end
	run_quickfix_with_zig_once(raw_lines, quickfix_opts, force_truncated, on_success, on_fallback)
end

---@param buf integer
---@param quickfix_opts table
---@return nil
function M.populate_from_buffer(buf, quickfix_opts)
	if quickfix_opts.enabled == false or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local total_lines = vim.api.nvim_buf_line_count(buf)
	local processor = choose_quickfix_processor(quickfix_opts, total_lines)

	if processor == "zig" then
		local max_lines = tonumber(quickfix_opts.max_lines) or 1000
		if max_lines < 1 then
			max_lines = 1
		end
		local start_line = math.max(0, total_lines - max_lines)
		local raw_lines = vim.api.nvim_buf_get_lines(buf, start_line, -1, false)
		local force_truncated = start_line > 0
		run_quickfix_with_zig(raw_lines, quickfix_opts, force_truncated, set_quickfix_lines, function()
			local lua_lines, truncated = collect_lua_quickfix_lines(buf, quickfix_opts)
			populate_quickfix_lua(lua_lines, quickfix_opts, truncated)
		end)
		return
	end

	local lua_lines, truncated = collect_lua_quickfix_lines(buf, quickfix_opts)
	populate_quickfix_lua(lua_lines, quickfix_opts, truncated)
end

---@return nil
function M.reset()
	quickfix_client.reset()
end

return M
