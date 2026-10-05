local M = {}

---@param text string
---@return string[]
function M.split_lines(text)
	---@type string[]
	local lines = {}
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		if line ~= "" then
			table.insert(lines, line)
		end
	end
	return lines
end

---@param text string
---@return string[]
function M.split_lines_preserve_empty(text)
	---@type string[]
	local lines = {}
	local normalized = tostring(text or ""):gsub("\r\n?", "\n")
	for line in (normalized .. "\n"):gmatch("([^\n]*)\n") do
		table.insert(lines, line)
	end
	if #lines > 0 then
		table.remove(lines, #lines)
	end
	return lines
end

---@param path string
---@return string[]|nil
function M.read_file_lines_direct(path)
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local contents = file:read("*a")
	file:close()
	if type(contents) ~= "string" then
		return nil
	end
	return M.split_lines(contents)
end

---@param path string
---@return string
function M.dirname(path)
	return vim.fn.fnamemodify(path, ":h")
end

---@param path string
---@return boolean
function M.filereadable(path)
	if type(vim.fn.filereadable) == "function" and vim.fn.filereadable(path) == 1 then
		return true
	end
	local file = io.open(path, "r")
	if file then
		file:close()
		return true
	end
	return false
end

---@param root string
---@param markers string[]
---@return boolean
function M.has_any_marker(root, markers)
	for _, marker in ipairs(markers or {}) do
		if M.filereadable(vim.fs.joinpath(root, marker)) then
			return true
		end
	end
	return false
end

---@param start_path string
---@param markers string[]
---@param max_up integer
---@return string|nil
function M.find_root_for_markers(start_path, markers, max_up)
	local dir = M.dirname(start_path)
	local limit = max_up or 12
	for _ = 1, limit do
		if M.has_any_marker(dir, markers) then
			return dir
		end
		local parent = M.dirname(dir)
		if parent == dir then
			break
		end
		dir = parent
	end
	return nil
end

---@param request_text string
---@param begin_marker string
---@param end_marker string
---@return table<string, string>|nil
function M.parse_flag_request_args(request_text, begin_marker, end_marker)
	local req_lines = M.split_lines(request_text or "")
	if #req_lines < 3 then
		return nil
	end

	local begin_line = req_lines[1]
	local request_id = begin_line:match("^" .. begin_marker .. "%s+(%d+)$")
	if not request_id then
		return nil
	end

	local end_line = req_lines[#req_lines]
	local end_id = end_line:match("^" .. end_marker .. "%s+(%d+)$")
	if not end_id or tonumber(end_id) ~= tonumber(request_id) then
		return nil
	end

	---@type table<string, string>
	local args = { request_id = request_id }
	for index = 2, #req_lines - 1 do
		local line = req_lines[index]
		if line:sub(1, 1) == "\t" then
			line = line:sub(2)
		end
		local key, value = line:match("^%-%-([^=]+)=(.*)$")
		if key and value ~= nil then
			args[key] = value
		end
	end
	return args
end

---@param request_text string
---@param begin_marker string
---@param payload_begin string
---@param payload_end string
---@param end_marker string
---@return table<string, string>|nil
function M.parse_flag_request_with_payload(request_text, begin_marker, payload_begin, payload_end, end_marker)
	local req_lines = M.split_lines_preserve_empty(request_text or "")
	if #req_lines < 3 then
		return nil
	end

	local begin_line = req_lines[1]
	local request_id = begin_line:match("^" .. begin_marker .. "%s+(%d+)$")
	if not request_id then
		return nil
	end

	---@type table<string, string>
	local args = { request_id = request_id }
	---@type string[]
	local payload_lines = {}
	local in_payload = false
	local saw_payload = false
	local saw_end = false

	for index = 2, #req_lines do
		local line = req_lines[index]
		local end_id = line:match("^" .. end_marker .. "%s+(%d+)$")
		if end_id then
			if tonumber(end_id) ~= tonumber(request_id) then
				return nil
			end
			if in_payload then
				return nil
			end
			saw_end = true
			break
		end

		local payload_begin_id = line:match("^" .. payload_begin .. "%s+(%d+)$")
		if payload_begin_id then
			if saw_payload or tonumber(payload_begin_id) ~= tonumber(request_id) then
				return nil
			end
			in_payload = true
			saw_payload = true
		else
			local payload_end_id = line:match("^" .. payload_end .. "%s+(%d+)$")
			if payload_end_id then
				if not in_payload or tonumber(payload_end_id) ~= tonumber(request_id) then
					return nil
				end
				in_payload = false
			elseif in_payload then
				if line:sub(1, 1) == "\t" then
					line = line:sub(2)
				end
				table.insert(payload_lines, line)
			else
				if line:sub(1, 1) == "\t" then
					line = line:sub(2)
				end
				local key, value = line:match("^%-%-([^=]+)=(.*)$")
				if key and value ~= nil then
					args[key] = value
				end
			end
		end
	end

	if not saw_end or in_payload then
		return nil
	end
	if saw_payload then
		args.selection_text = table.concat(payload_lines, "\n")
	end
	return args
end

---@param value string|nil
---@return string
function M.trim_text(value)
	return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param value string
---@return string
function M.quote_shell_arg(value)
	return "'" .. tostring(value or ""):gsub("'", "'\"'\"'") .. "'"
end

return M
