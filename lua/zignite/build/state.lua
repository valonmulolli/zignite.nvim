local cache_utils = require("zignite.utils.cache")

---@type table
local M = {}

M.DETECT_RUNTIME_DEFAULT_TTL_MS = 15000
M.DETECT_RUNTIME_FAILED_TTL_MS = 1000
M.PACKAGE_SCRIPT_CACHE_MAX = 128
M.MAKE_TARGET_CACHE_MAX = 128
M.CMAKE_TARGET_CACHE_MAX = 128
M.MESON_TARGET_CACHE_MAX = 128
M.CARGO_TARGET_CACHE_MAX = 128
M.GO_PROJECT_CACHE_MAX = 128
M.DETECT_RUNTIME_CACHE_MAX = 256

---@type table<string, string>
M.last_build_command_by_filetype = {}
---@type table<string, table>
M.package_script_cache = {}
---@type string[]
M.package_script_cache_order = {}
---@type table<string, table>
M.make_target_cache = {}
---@type string[]
M.make_target_cache_order = {}
---@type table<string, table>
M.cmake_target_cache = {}
---@type string[]
M.cmake_target_cache_order = {}
---@type table<string, table>
M.meson_target_cache = {}
---@type string[]
M.meson_target_cache_order = {}
---@type table<string, table>
M.cargo_target_cache = {}
---@type string[]
M.cargo_target_cache_order = {}
---@type table<string, table>
M.go_project_cache = {}
---@type string[]
M.go_project_cache_order = {}
---@type table<string, table>
M.detect_runtime_cache = {}
---@type string[]
M.detect_runtime_cache_order = {}
---@type table<string, table>
M.detect_runtime_inflight = {}

---@param order string[]
---@param key string
---@return nil
function M.touch_cache_key(order, key)
	cache_utils.touch_cache_key(order, key)
end

---@param cache table<string, any>
---@param order string[]
---@param max_entries integer
---@param key string
---@param value any
---@return nil
function M.set_bounded_cache_entry(cache, order, max_entries, key, value)
	cache_utils.set_bounded_cache_entry(cache, order, max_entries, key, value)
end

---@param cache table<string, any>
---@param order string[]
---@param key string
---@return any
function M.get_bounded_cache_entry(cache, order, key)
	return cache_utils.get_bounded_cache_entry(cache, order, key)
end

---@return number
function M.now_ms()
	local uv = vim.uv or vim.loop
	if uv and type(uv.hrtime) == "function" then
		return uv.hrtime() / 1e6
	end
	return os.clock() * 1000
end

---@param tbl table<string, string>|nil
---@return table<string, string>
function M.copy_string_map(tbl)
	return cache_utils.copy_string_map(tbl)
end

---@param path string
---@return string|nil
function M.get_file_mtime_key(path)
	local uv = vim.uv or vim.loop
	if not uv or type(uv.fs_stat) ~= "function" then
		return nil
	end
	local stat = uv.fs_stat(path)
	if not stat then
		return nil
	end
	local mtime = stat.mtime or {}
	return string.format(
		"%s:%s:%s",
		tostring(stat.size or 0),
		tostring(mtime.sec or 0),
		tostring(mtime.nsec or 0)
	)
end

---@param filetype string
---@param command_name string
---@return nil
function M.set_last_build_command(filetype, command_name)
	if type(filetype) == "string" and filetype ~= "" and type(command_name) == "string" and command_name ~= "" then
		M.last_build_command_by_filetype[filetype] = command_name
	end
end

---@param filetype string
---@return string|nil
function M.get_last_build_command(filetype)
	return M.last_build_command_by_filetype[filetype]
end

---@param tbl table
---@return nil
local function clear_table(tbl)
	for key, _ in pairs(tbl) do
		tbl[key] = nil
	end
end

---@return nil
function M.reset()
	clear_table(M.last_build_command_by_filetype)
	clear_table(M.package_script_cache)
	clear_table(M.package_script_cache_order)
	clear_table(M.make_target_cache)
	clear_table(M.make_target_cache_order)
	clear_table(M.cmake_target_cache)
	clear_table(M.cmake_target_cache_order)
	clear_table(M.meson_target_cache)
	clear_table(M.meson_target_cache_order)
	clear_table(M.cargo_target_cache)
	clear_table(M.cargo_target_cache_order)
	clear_table(M.go_project_cache)
	clear_table(M.go_project_cache_order)
	clear_table(M.detect_runtime_cache)
	clear_table(M.detect_runtime_cache_order)
	clear_table(M.detect_runtime_inflight)
end

---@return table
function M.debug_state()
	return {
		cargo_target_cache = M.cargo_target_cache,
		cargo_target_cache_order = M.cargo_target_cache_order,
		go_project_cache = M.go_project_cache,
		go_project_cache_order = M.go_project_cache_order,
		detect_runtime_cache = M.detect_runtime_cache,
		detect_runtime_cache_order = M.detect_runtime_cache_order,
	}
end

return M
