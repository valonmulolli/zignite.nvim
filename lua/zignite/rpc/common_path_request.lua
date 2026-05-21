---@type table
local M = {}

---@param begin_marker string
---@param request_id integer
---@param mode_flag string
---@param filepath string
---@param filetype string
---@return string[]
function M.begin_worker_lines(begin_marker, request_id, mode_flag, filepath, filetype)
	return {
		string.format("%s %d", begin_marker, request_id),
		"\t" .. mode_flag,
		"\t--path=" .. filepath,
		"\t--filetype=" .. filetype,
	}
end

---@param lines string[]
---@param flag_name string
---@param value string
---@return nil
function M.append_optional_worker_flag(lines, flag_name, value)
	lines[#lines + 1] = "\t--" .. flag_name .. "=" .. value
end

---@param lines string[]
---@param end_marker string
---@param request_id integer
---@return string
function M.finish_worker_payload(lines, end_marker, request_id)
	lines[#lines + 1] = string.format("%s %d", end_marker, request_id)
	return table.concat(lines, "\n") .. "\n"
end

---@param executable string
---@param mode_flag string
---@param filepath string
---@param filetype string
---@return string[]
function M.begin_once_argv(executable, mode_flag, filepath, filetype)
	return {
		executable,
		mode_flag,
		"--path=" .. filepath,
		"--filetype=" .. filetype,
	}
end

---@param argv string[]
---@param flag_name string
---@param value string
---@return nil
function M.append_optional_argv(argv, flag_name, value)
	argv[#argv + 1] = "--" .. flag_name .. "=" .. value
end

---@class ZigniteOptionalFlag
---@field name string
---@field value string|nil

---@param begin_marker string
---@param end_marker string
---@param request_id integer
---@param mode_flag string
---@param filepath string
---@param filetype string
---@param optional_flags ZigniteOptionalFlag[]|nil
---@param is_invalid fun(value: any): boolean
---@return string|nil
function M.compose_worker_payload(begin_marker, end_marker, request_id, mode_flag, filepath, filetype, optional_flags, is_invalid)
	if is_invalid(filepath) or is_invalid(filetype) then
		return nil
	end

	local lines = M.begin_worker_lines(begin_marker, request_id, mode_flag, filepath, filetype)
	for _, flag in ipairs(optional_flags or {}) do
		if type(flag.value) == "string" and flag.value ~= "" then
			if is_invalid(flag.value) then
				return nil
			end
			M.append_optional_worker_flag(lines, flag.name, flag.value)
		end
	end

	return M.finish_worker_payload(lines, end_marker, request_id)
end

---@param executable string
---@param mode_flag string
---@param filepath string
---@param filetype string
---@param optional_flags ZigniteOptionalFlag[]|nil
---@param is_invalid fun(value: any): boolean
---@return string[]|nil
function M.compose_once_argv(executable, mode_flag, filepath, filetype, optional_flags, is_invalid)
	if is_invalid(filepath) or is_invalid(filetype) then
		return nil
	end

	local argv = M.begin_once_argv(executable, mode_flag, filepath, filetype)
	for _, flag in ipairs(optional_flags or {}) do
		if type(flag.value) == "string" and flag.value ~= "" then
			if is_invalid(flag.value) then
				return nil
			end
			M.append_optional_argv(argv, flag.name, flag.value)
		end
	end

	return argv
end

return M
