local quickfix_rpc = require("zignite.rpc.quickfix")

---@type table
local M = {}

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

---@param buf integer
---@param quickfix_opts table
---@return string[], boolean, integer
local function collect_backend_quickfix_lines(buf, quickfix_opts)
	local max_lines = tonumber(quickfix_opts.max_lines) or 1000
	if max_lines < 1 then
		max_lines = 1
	end

	local total_lines = vim.api.nvim_buf_line_count(buf)
	local start_line = math.max(0, total_lines - max_lines)
	local raw_lines = vim.api.nvim_buf_get_lines(buf, start_line, -1, false)
	return raw_lines, start_line > 0, total_lines
end

---@param quickfix_opts table
---@return string
local function choose_quickfix_processor(quickfix_opts)
	if quickfix_rpc.prefers_backend(quickfix_opts) then
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
---@param buf integer
---@param quickfix_opts table
---@return nil
local function populate_quickfix_from_lua_buffer(buf, quickfix_opts)
	local lua_lines, truncated = collect_lua_quickfix_lines(buf, quickfix_opts)
	populate_quickfix_lua(lua_lines, quickfix_opts, truncated)
end

---@param buf integer
---@param quickfix_opts table
---@return nil
function M.populate_from_buffer(buf, quickfix_opts)
	if quickfix_opts.enabled == false or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local processor = choose_quickfix_processor(quickfix_opts)

	if processor == "zig" then
		local raw_lines, force_truncated = collect_backend_quickfix_lines(buf, quickfix_opts)
		quickfix_rpc.run_async(raw_lines, quickfix_opts, force_truncated, set_quickfix_lines, function()
			populate_quickfix_from_lua_buffer(buf, quickfix_opts)
		end)
		return
	end

	populate_quickfix_from_lua_buffer(buf, quickfix_opts)
end

---@return nil
function M.reset()
	quickfix_rpc.reset()
end

return M
