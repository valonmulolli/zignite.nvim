---@type table
local M = {}

---@param text string
---@return string[]
local function split_lines(text)
	---@type string[]
	local lines = {}
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		if line ~= "" then
			table.insert(lines, line)
		end
	end
	return lines
end

---@param cmd string[]|string
---@param prefix string
---@param default string|boolean|nil
---@return string|boolean|nil
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

---@param cmd string[]|string
---@param prefix string
---@param default boolean
---@return boolean
local function parse_backend_bool(cmd, prefix, default)
	local value = parse_backend_flag(cmd, prefix, nil)
	if value == nil then
		return default
	end
	return value == "1" or value == "true"
end

---@param line string
---@return string|nil
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

---@param cmd string[]|string
---@return boolean
function M.is_quickfix_daemon_cmd(cmd)
	if type(cmd) ~= "table" then
		return false
	end
	for _, arg in ipairs(cmd) do
		if arg == "--quickfix-daemon" or arg == "--daemon" then
			return true
		end
	end
	return false
end

---@param cmd string[]|string
---@return boolean
function M.is_detect_daemon_cmd(cmd)
	if type(cmd) ~= "table" then
		return false
	end
	for _, arg in ipairs(cmd) do
		if arg == "--detect-daemon" or arg == "--daemon" then
			return true
		end
	end
	return false
end

---@param cmd string[]|string
---@return boolean
function M.is_project_daemon_cmd(cmd)
	if type(cmd) ~= "table" then
		return false
	end
	for _, arg in ipairs(cmd) do
		if arg == "--project-parse-daemon" or arg == "--daemon" then
			return true
		end
	end
	return false
end

---@param cmd string[]|string
---@return boolean
function M.is_unified_daemon_cmd(cmd)
	if type(cmd) ~= "table" then
		return false
	end
	for _, arg in ipairs(cmd) do
		if arg == "--daemon" then
			return true
		end
	end
	return false
end

---@param cmd string[]|string
---@return boolean
function M.is_quickfix_backend_cmd(cmd)
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

---@param input string
---@param cmd string[]
---@return string[]
function M.simulate_quickfix_backend(input, cmd)
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
	for index = #lines, 1, -1 do
		used = used + #lines[index] + 1
		if used > max_bytes then
			truncated = true
			break
		end
		start_idx = index
	end

	if #lines > 0 then
		if start_idx > #lines then
			lines = { lines[#lines] }
		elseif start_idx > 1 then
			---@type string[]
			local sliced = {}
			for index = start_idx, #lines do
				table.insert(sliced, lines[index])
			end
			lines = sliced
		end
	end

	if #lines > max_lines then
		truncated = true
		---@type string[]
		local sliced = {}
		for index = #lines - max_lines + 1, #lines do
			table.insert(sliced, lines[index])
		end
		lines = sliced
	end

	if strip_ansi and strip_max_lines > 0 then
		local strip_start_idx = math.max(1, #lines - strip_max_lines + 1)
		for index = strip_start_idx, #lines do
			lines[index] = lines[index]:gsub("\27%[[0-9;]*m", "")
		end
	end

	if parse_diagnostics then
		for index = 1, #lines do
			local normalized = canonicalize_diag(lines[index])
			if normalized then
				lines[index] = normalized
			end
		end
	end

	if truncated then
		table.insert(lines, 1, "[zignite] quickfix output truncated")
	end

	return lines
end

---@param request_text string
---@return string[]|nil
function M.parse_daemon_request(request_text)
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

	---@type string[]
	local payload_lines = {}
	for index = 2, #req_lines - 1 do
		local line = req_lines[index]
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

	local backend_lines = M.simulate_quickfix_backend(table.concat(payload_lines, "\n"), cmd)
	local response = { "@@ZQF_RES_BEGIN " .. request_id }
	for _, line in ipairs(backend_lines) do
		response[#response + 1] = "\t" .. line
	end
	response[#response + 1] = "@@ZQF_RES_END " .. request_id
	return response
end

return M
