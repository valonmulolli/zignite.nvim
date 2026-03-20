local config = require("zignite.config")
local state = require("zignite.runtime.state")

---@type table
local M = {}

---@param filepath string
---@return string
local function get_file_extension(filepath)
	if not filepath or filepath == "" then
		return ""
	end
	local ext = vim.fn.fnamemodify(filepath, ":e")
	if type(ext) ~= "string" then
		return ""
	end
	return ext:lower()
end

---@param filepath string
---@return string|nil
local function get_filetype_from_shebang(filepath)
	if not filepath or filepath == "" then
		return nil
	end

	local cached = state.get_shebang_cache(filepath)
	if cached ~= nil then
		if cached == false then
			return nil
		end
		return cached
	end

	if type(vim.fn.filereadable) ~= "function" or vim.fn.filereadable(filepath) ~= 1 then
		state.set_shebang_cache(filepath, false)
		return nil
	end
	if type(vim.fn.readfile) ~= "function" then
		state.set_shebang_cache(filepath, false)
		return nil
	end

	local lines = vim.fn.readfile(filepath, "", 1)
	if type(lines) ~= "table" or type(lines[1]) ~= "string" then
		state.set_shebang_cache(filepath, false)
		return nil
	end

	local first_line = lines[1]
	if not first_line:match("^#!") then
		state.set_shebang_cache(filepath, false)
		return nil
	end

	local interpreter = first_line:match("^#!%s*/usr/bin/env%s+%-S%s+([%w%._%-]+)")
		or first_line:match("^#!%s*/usr/bin/env%s+([%w%._%-]+)")
	if not interpreter then
		local executable = first_line:match("^#!%s*([^%s]+)")
		if executable then
			interpreter = executable:match("([^/]+)$")
		end
	end
	if not interpreter then
		state.set_shebang_cache(filepath, false)
		return nil
	end

	local mapped = state.SHEBANG_FILETYPE_MAP[interpreter:lower()]
	state.set_shebang_cache(filepath, mapped or false)
	return mapped
end

---@param requested_filetype string
---@param filepath string
---@return string
function M.resolve_supported_filetype(requested_filetype, filepath)
	local requested = state.trim_text(requested_filetype)
	local aliased = state.FILETYPE_ALIAS_MAP[requested] or requested
	local ext_filetype = state.EXTENSION_FILETYPE_MAP[get_file_extension(filepath)]

	if aliased ~= "" then
		if config.options.runners[aliased] ~= nil or config.options.build_commands[aliased] ~= nil then
			return aliased
		end
		if ext_filetype and ext_filetype ~= "" then
			return ext_filetype
		end
		local shebang_filetype = get_filetype_from_shebang(filepath)
		if shebang_filetype and shebang_filetype ~= "" then
			return shebang_filetype
		end
		return aliased
	end

	if ext_filetype and ext_filetype ~= "" then
		return ext_filetype
	end
	local shebang_filetype = get_filetype_from_shebang(filepath)
	if shebang_filetype and shebang_filetype ~= "" then
		return shebang_filetype
	end
	return requested
end

---@param filepath string
---@param filetype string
---@return string
function M.build_temp_execution_path(filepath, filetype)
	local temp_path
	if type(vim.fn.tempname) == "function" then
		temp_path = vim.fn.tempname()
	else
		temp_path = os.tmpname()
	end

	local ext = get_file_extension(filepath)
	if ext == "" then
		ext = state.TEMP_FILE_EXTENSION_MAP[filetype] or ""
	end
	if ext == "" then
		return temp_path
	end
	return temp_path .. "." .. ext
end

return M
