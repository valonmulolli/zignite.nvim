local backend = require("zignite.build_detect_backend")
local parsers = require("zignite.build_detect_parsers")

---@type table
local M = {}

local TOOL_COMMAND_CACHE_MAX = 128

---@type table<string, table>
local tool_command_cache = {}
---@type string[]
local tool_command_cache_order = {}

---@param value string
---@return string
local function trim_text(value)
	if type(value) ~= "string" then
		return ""
	end
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param order string[]
---@param key string
---@return nil
local function touch_cache_key(order, key)
	for index, existing in ipairs(order) do
		if existing == key then
			table.remove(order, index)
			break
		end
	end
	order[#order + 1] = key
end

---@param cache table<string, any>
---@param order string[]
---@param max_entries integer
---@param key string
---@param value any
---@return nil
local function set_bounded_cache_entry(cache, order, max_entries, key, value)
	if type(key) ~= "string" or key == "" then
		return
	end
	cache[key] = value
	touch_cache_key(order, key)
	while #order > max_entries do
		local oldest = table.remove(order, 1)
		if oldest ~= nil then
			cache[oldest] = nil
		end
	end
end

---@param cache table<string, any>
---@param order string[]
---@param key string
---@return any
local function get_bounded_cache_entry(cache, order, key)
	local value = cache[key]
	if value ~= nil and type(key) == "string" and key ~= "" then
		touch_cache_key(order, key)
	end
	return value
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

---@param tool string
---@return table<string, string>|nil
local function detect_commands_with_zig_backend(tool)
	local commands = backend.detect_with_zig_worker(tool, parsers.build_detected_templates_from_names)
	if commands ~= nil then
		return commands
	end
	return backend.detect_with_zig_once(tool, parsers.build_detected_templates_from_names)
end

---@param tool string
---@param on_done fun(commands: table<string, string>|nil):nil
---@return nil
local function detect_commands_with_zig_backend_async(tool, on_done)
	if backend.detect_with_zig_worker_async(tool, on_done, parsers.build_detected_templates_from_names) then
		return
	end
	if backend.detect_with_zig_once_async(tool, on_done, parsers.build_detected_templates_from_names) then
		return
	end
	on_done(nil)
end

---@param cache_key string
---@param tool string
---@param executable string
---@param command_argv string[]
---@param parser fun(lines: string[]): table<string, string>
---@return table<string, string>
local function detect_commands_from_tool(cache_key, tool, executable, command_argv, parser)
	local cached = get_bounded_cache_entry(tool_command_cache, tool_command_cache_order, cache_key)
	if cached ~= nil then
		return copy_string_map(cached)
	end

	local zig_detected = detect_commands_with_zig_backend(tool)
	if zig_detected ~= nil then
		set_bounded_cache_entry(tool_command_cache, tool_command_cache_order, TOOL_COMMAND_CACHE_MAX, cache_key, zig_detected)
		return copy_string_map(zig_detected)
	end

	if type(vim.fn.executable) ~= "function" or vim.fn.executable(executable) ~= 1 then
		set_bounded_cache_entry(tool_command_cache, tool_command_cache_order, TOOL_COMMAND_CACHE_MAX, cache_key, {})
		return {}
	end
	if type(vim.fn.systemlist) ~= "function" then
		set_bounded_cache_entry(tool_command_cache, tool_command_cache_order, TOOL_COMMAND_CACHE_MAX, cache_key, {})
		return {}
	end

	local output_lines = vim.fn.systemlist(command_argv)
	local shell_error = (vim.v and tonumber(vim.v.shell_error)) or 0
	if type(output_lines) ~= "table" or shell_error ~= 0 then
		set_bounded_cache_entry(tool_command_cache, tool_command_cache_order, TOOL_COMMAND_CACHE_MAX, cache_key, {})
		return {}
	end

	local detected = parser(output_lines)
	set_bounded_cache_entry(tool_command_cache, tool_command_cache_order, TOOL_COMMAND_CACHE_MAX, cache_key, detected)
	return copy_string_map(detected)
end

---@param cache_key string
---@param tool string
---@param executable string
---@param command_argv string[]
---@param parser fun(lines: string[]): table<string, string>
---@param on_done fun(commands: table<string, string>|nil):nil
---@param force_refresh boolean|nil
---@return nil
local function detect_commands_from_tool_async(
	cache_key,
	tool,
	executable,
	command_argv,
	parser,
	on_done,
	force_refresh
)
	local cached = get_bounded_cache_entry(tool_command_cache, tool_command_cache_order, cache_key)
	if force_refresh ~= true and cached ~= nil then
		on_done(copy_string_map(cached))
		return
	end

	local function run_command_fallback()
		if type(vim.fn.executable) ~= "function" or vim.fn.executable(executable) ~= 1 then
			set_bounded_cache_entry(tool_command_cache, tool_command_cache_order, TOOL_COMMAND_CACHE_MAX, cache_key, {})
			on_done({})
			return
		end

		if type(vim.fn.jobstart) == "function" then
			---@type string[]
			local lines = {}
			local job_id = vim.fn.jobstart(command_argv, {
				stdout_buffered = true,
				stderr_buffered = true,
				on_stdout = function(_, data)
					if type(data) ~= "table" then
						return
					end
					for _, raw_line in ipairs(data) do
						local line = tostring(raw_line or "")
						if trim_text(line) ~= "" then
							lines[#lines + 1] = line
						end
					end
				end,
				on_stderr = function(_, data)
					if type(data) ~= "table" then
						return
					end
					for _, raw_line in ipairs(data) do
						local line = tostring(raw_line or "")
						if trim_text(line) ~= "" then
							lines[#lines + 1] = line
						end
					end
				end,
				on_exit = function(_, exit_code)
					if tonumber(exit_code) ~= 0 then
						on_done(nil)
						return
					end
					local detected = parser(lines)
					set_bounded_cache_entry(tool_command_cache, tool_command_cache_order, TOOL_COMMAND_CACHE_MAX, cache_key, detected)
					on_done(copy_string_map(detected))
				end,
			})
			if type(job_id) == "number" and job_id > 0 then
				return
			end
		end

		if type(vim.fn.systemlist) == "function" then
			local output_lines = vim.fn.systemlist(command_argv)
			local shell_error = (vim.v and tonumber(vim.v.shell_error)) or 0
			if type(output_lines) ~= "table" or shell_error ~= 0 then
				on_done(nil)
				return
			end
			local detected = parser(output_lines)
			set_bounded_cache_entry(tool_command_cache, tool_command_cache_order, TOOL_COMMAND_CACHE_MAX, cache_key, detected)
			on_done(copy_string_map(detected))
			return
		end

		on_done(nil)
	end

	detect_commands_with_zig_backend_async(tool, function(zig_detected)
		if zig_detected ~= nil then
			set_bounded_cache_entry(
				tool_command_cache,
				tool_command_cache_order,
				TOOL_COMMAND_CACHE_MAX,
				cache_key,
				zig_detected
			)
			on_done(copy_string_map(zig_detected))
			return
		end
		run_command_fallback()
	end)
end

---@return table<string, string>
function M.detect_zig_tool_commands()
	return detect_commands_from_tool("zig", "zig", "zig", { "zig", "--help" }, parsers.parse_zig_help_commands)
end

---@param on_done fun(commands: table<string, string>|nil):nil
---@param force_refresh boolean|nil
---@return nil
function M.detect_zig_tool_commands_async(on_done, force_refresh)
	detect_commands_from_tool_async(
		"zig",
		"zig",
		"zig",
		{ "zig", "--help" },
		parsers.parse_zig_help_commands,
		on_done,
		force_refresh
	)
end

---@return table<string, string>
function M.detect_go_tool_commands()
	return detect_commands_from_tool("go", "go", "go", { "go", "help" }, parsers.parse_go_help_commands)
end

---@param on_done fun(commands: table<string, string>|nil):nil
---@param force_refresh boolean|nil
---@return nil
function M.detect_go_tool_commands_async(on_done, force_refresh)
	detect_commands_from_tool_async(
		"go",
		"go",
		"go",
		{ "go", "help" },
		parsers.parse_go_help_commands,
		on_done,
		force_refresh
	)
end

---@return table<string, string>
function M.detect_rust_tool_commands()
	return detect_commands_from_tool("cargo", "cargo", "cargo", { "cargo", "--list" }, parsers.parse_cargo_commands)
end

---@param on_done fun(commands: table<string, string>|nil):nil
---@param force_refresh boolean|nil
---@return nil
function M.detect_rust_tool_commands_async(on_done, force_refresh)
	detect_commands_from_tool_async(
		"cargo",
		"cargo",
		"cargo",
		{ "cargo", "--list" },
		parsers.parse_cargo_commands,
		on_done,
		force_refresh
	)
end

---@return table<string, string>
function M.detect_odin_tool_commands()
	return detect_commands_from_tool("odin", "odin", "odin", { "odin", "help" }, parsers.parse_odin_commands)
end

---@param on_done fun(commands: table<string, string>|nil):nil
---@param force_refresh boolean|nil
---@return nil
function M.detect_odin_tool_commands_async(on_done, force_refresh)
	detect_commands_from_tool_async(
		"odin",
		"odin",
		"odin",
		{ "odin", "help" },
		parsers.parse_odin_commands,
		on_done,
		force_refresh
	)
end

---@return nil
function M.reset()
	backend.reset()
	tool_command_cache = {}
	tool_command_cache_order = {}
end

return M
