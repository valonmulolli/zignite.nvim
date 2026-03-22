local backend = require("zignite.build.detect.backend")
local cache_utils = require("zignite.utils.cache")

---@type table
local M = {}

local TOOL_COMMAND_CACHE_MAX = 128

---@type table<string, table>
local tool_command_cache = {}
---@type string[]
local tool_command_cache_order = {}

local detect_tool_configs = {
	zig = {
		cache_key = "zig",
	},
	go = {
		cache_key = "go",
	},
	cargo = {
		cache_key = "cargo",
	},
	odin = {
		cache_key = "odin",
	},
}

---@param tool string
---@return table<string, string>|nil
local function detect_commands_with_zig_backend(tool)
	local commands = backend.detect_with_zig_worker(tool)
	if commands ~= nil then
		return commands
	end
	return backend.detect_with_zig_once(tool)
end

---@param tool string
---@param on_done fun(commands: table<string, string>|nil):nil
---@return nil
local function detect_commands_with_zig_backend_async(tool, on_done)
	if backend.detect_with_zig_worker_async(tool, function(commands)
		if commands ~= nil then
			on_done(commands)
			return
		end
		if backend.detect_with_zig_once_async(tool, on_done) then
			return
		end
		on_done(nil)
	end) then
		return
	end
	if backend.detect_with_zig_once_async(tool, on_done) then
		return
	end
	on_done(nil)
end

---@param tool string
---@param cache_key string
---@return table<string, string>
local function detect_commands_from_tool(cache_key, tool)
	local cached = cache_utils.get_bounded_cache_entry(tool_command_cache, tool_command_cache_order, cache_key)
	if cached ~= nil then
		return cache_utils.copy_string_map(cached)
	end

	local zig_detected = detect_commands_with_zig_backend(tool)
	if zig_detected ~= nil then
		cache_utils.set_bounded_cache_entry(
			tool_command_cache,
			tool_command_cache_order,
			TOOL_COMMAND_CACHE_MAX,
			cache_key,
			zig_detected
		)
		return cache_utils.copy_string_map(zig_detected)
	end
	cache_utils.set_bounded_cache_entry(
		tool_command_cache,
		tool_command_cache_order,
		TOOL_COMMAND_CACHE_MAX,
		cache_key,
		{}
	)
	return {}
end

---@param cache_key string
---@param tool string
---@param on_done fun(commands: table<string, string>|nil):nil
---@param force_refresh boolean|nil
---@return nil
local function detect_commands_from_tool_async(cache_key, tool, on_done, force_refresh)
	local cached = cache_utils.get_bounded_cache_entry(tool_command_cache, tool_command_cache_order, cache_key)
	if force_refresh ~= true and cached ~= nil then
		on_done(cache_utils.copy_string_map(cached))
		return
	end

	detect_commands_with_zig_backend_async(tool, function(zig_detected)
		if zig_detected ~= nil then
			cache_utils.set_bounded_cache_entry(
				tool_command_cache,
				tool_command_cache_order,
				TOOL_COMMAND_CACHE_MAX,
				cache_key,
				zig_detected
			)
			on_done(cache_utils.copy_string_map(zig_detected))
			return
		end
		on_done(nil)
	end)
end

---@param tool string
---@return table<string, string>
local function detect_tool_commands(tool)
	local config = detect_tool_configs[tool]
	if config == nil then
		return {}
	end
	return detect_commands_from_tool(config.cache_key, tool)
end

---@param tool string
---@param on_done fun(commands: table<string, string>|nil):nil
---@param force_refresh boolean|nil
---@return nil
local function detect_tool_commands_async(tool, on_done, force_refresh)
	local config = detect_tool_configs[tool]
	if config == nil then
		on_done({})
		return
	end
	detect_commands_from_tool_async(config.cache_key, tool, on_done, force_refresh)
end

---@return table<string, string>
function M.detect_zig_tool_commands()
	return detect_tool_commands("zig")
end

---@param on_done fun(commands: table<string, string>|nil):nil
---@param force_refresh boolean|nil
---@return nil
function M.detect_zig_tool_commands_async(on_done, force_refresh)
	detect_tool_commands_async("zig", on_done, force_refresh)
end

---@return table<string, string>
function M.detect_go_tool_commands()
	return detect_tool_commands("go")
end

---@param on_done fun(commands: table<string, string>|nil):nil
---@param force_refresh boolean|nil
---@return nil
function M.detect_go_tool_commands_async(on_done, force_refresh)
	detect_tool_commands_async("go", on_done, force_refresh)
end

---@return table<string, string>
function M.detect_rust_tool_commands()
	return detect_tool_commands("cargo")
end

---@param on_done fun(commands: table<string, string>|nil):nil
---@param force_refresh boolean|nil
---@return nil
function M.detect_rust_tool_commands_async(on_done, force_refresh)
	detect_tool_commands_async("cargo", on_done, force_refresh)
end

---@return table<string, string>
function M.detect_odin_tool_commands()
	return detect_tool_commands("odin")
end

---@param on_done fun(commands: table<string, string>|nil):nil
---@param force_refresh boolean|nil
---@return nil
function M.detect_odin_tool_commands_async(on_done, force_refresh)
	detect_tool_commands_async("odin", on_done, force_refresh)
end

---@return nil
function M.reset()
	backend.reset()
	tool_command_cache = {}
	tool_command_cache_order = {}
end

return M
