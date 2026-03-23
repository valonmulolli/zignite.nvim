local common = require("zignite.build.common")
local detect_backend = require("zignite.build.detect.backend")
local state = require("zignite.build.state")
local systems = require("zignite.build.systems")

---@type table
local M = {}

---@param cache_key string
---@param mtime_key string
---@param commands table<string, string>
---@return table<string, string>, nil
local function store_cached_result(cache_key, mtime_key, commands)
	state.set_bounded_cache_entry(
		state.cmake_target_cache,
		state.cmake_target_cache_order,
		state.CMAKE_TARGET_CACHE_MAX,
		cache_key,
		{
			mtime_key = mtime_key,
			commands = state.copy_string_map(commands),
			info = nil,
		}
	)
	return commands, nil
end

---@param filepath string
---@return table<string, string>, table|nil
function M.detect_cmake_project_commands(filepath)
	if not filepath or filepath == "" then
		return {}, nil
	end
	if type(vim.fn.filereadable) ~= "function" then
		return {}, nil
	end

	local system, root = systems.detect_c_family_build_system(filepath)
	if system ~= "cmake" or not root then
		return {}, nil
	end

	local cmake_lists_path = vim.fs.joinpath(root, "CMakeLists.txt")
	if vim.fn.filereadable(cmake_lists_path) ~= 1 then
		return {}, nil
	end

	local cmake_build_ready = systems.has_cmake_build_tree(root) and "1" or "0"
	local mtime_key = string.format(
		"%s|build:%s",
		state.get_file_mtime_key(cmake_lists_path) or "missing",
		cmake_build_ready
	)
	local cache_key = cmake_lists_path .. "::" .. common.normalize_path_text(filepath)
	local cached = state.get_bounded_cache_entry(
		state.cmake_target_cache,
		state.cmake_target_cache_order,
		cache_key
	)
	if cached and cached.mtime_key == mtime_key then
		return state.copy_string_map(cached.commands), nil
	end

	local zig_lines = detect_backend.parse_project_lines_once("cmake", cmake_lists_path, {
		"--match-path=" .. filepath,
	})
	if type(zig_lines) == "table" and #zig_lines > 0 then
		return store_cached_result(cache_key, mtime_key, common.decode_backend_commands(zig_lines))
	end

	return store_cached_result(cache_key, mtime_key, {})
end

return M
