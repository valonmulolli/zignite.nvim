local common = require("zignite.build.parsers.common")
local config = require("zignite.config")
local state = require("zignite.build.state")
local utils = require("zignite.utils")

---@type table
local M = {}

---@param filepath string
---@return table<string, string>
function M.detect_makefile_targets(filepath)
	if not filepath or filepath == "" then
		return {}
	end
	if type(vim.fn.filereadable) ~= "function" or type(vim.fn.readfile) ~= "function" then
		return {}
	end

	local root = utils.get_project_root(filepath, config.options.project)
	if not root then
		root = vim.fn.fnamemodify(filepath, ":h")
	end
	local makefile_path = vim.fs.joinpath(root, "Makefile")
	if vim.fn.filereadable(makefile_path) ~= 1 then
		return {}
	end

	local mtime_key = state.get_file_mtime_key(makefile_path)
	local cached = state.get_bounded_cache_entry(
		state.make_target_cache,
		state.make_target_cache_order,
		makefile_path
	)
	if cached and cached.mtime_key == mtime_key then
		return state.copy_string_map(cached.commands)
	end

	local lines = vim.fn.readfile(makefile_path)
	if type(lines) ~= "table" then
		state.set_bounded_cache_entry(
			state.make_target_cache,
			state.make_target_cache_order,
			state.MAKE_TARGET_CACHE_MAX,
			makefile_path,
			{ mtime_key = mtime_key, commands = {} }
		)
		return {}
	end
	if common.is_cmake_generated_makefile_lines(lines) then
		state.set_bounded_cache_entry(
			state.make_target_cache,
			state.make_target_cache_order,
			state.MAKE_TARGET_CACHE_MAX,
			makefile_path,
			{ mtime_key = mtime_key, commands = {} }
		)
		return {}
	end

	local commands = common.parse_makefile_targets(lines)
	state.set_bounded_cache_entry(
		state.make_target_cache,
		state.make_target_cache_order,
		state.MAKE_TARGET_CACHE_MAX,
		makefile_path,
		{ mtime_key = mtime_key, commands = state.copy_string_map(commands) }
	)
	return commands
end

return M
