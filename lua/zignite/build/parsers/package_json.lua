local common = require("zignite.build.parsers.common")
local config = require("zignite.config")
local state = require("zignite.build.state")
local utils = require("zignite.utils")

---@type table
local M = {}

---@param filepath string
---@return table<string, string>
function M.detect_package_scripts(filepath)
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
	local package_json_path = vim.fs.joinpath(root, "package.json")
	if vim.fn.filereadable(package_json_path) ~= 1 then
		return {}
	end

	local mtime_key = state.get_file_mtime_key(package_json_path)
	local package_manager = utils.detect_node_package_manager_root(root)
	local cached = state.get_bounded_cache_entry(
		state.package_script_cache,
		state.package_script_cache_order,
		package_json_path
	)
	if cached and cached.mtime_key == mtime_key and cached.package_manager == package_manager then
		return state.copy_string_map(cached.commands)
	end

	local lines = vim.fn.readfile(package_json_path)
	if type(lines) ~= "table" or #lines == 0 then
		state.set_bounded_cache_entry(
			state.package_script_cache,
			state.package_script_cache_order,
			state.PACKAGE_SCRIPT_CACHE_MAX,
			package_json_path,
			{ mtime_key = mtime_key, package_manager = package_manager, commands = {} }
		)
		return {}
	end

	local parsed = common.decode_json_payload(table.concat(lines, "\n"))
	local scripts = parsed and parsed.scripts
	---@type table<string, string>
	local commands = {}
	if type(scripts) == "table" then
		for script_name, script_value in pairs(scripts) do
			if type(script_name) == "string" and type(script_value) == "string" then
				commands[script_name] = utils.format_package_script_command(package_manager, script_name)
			end
		end
	end

	state.set_bounded_cache_entry(
		state.package_script_cache,
		state.package_script_cache_order,
		state.PACKAGE_SCRIPT_CACHE_MAX,
		package_json_path,
		{ mtime_key = mtime_key, package_manager = package_manager, commands = state.copy_string_map(commands) }
	)
	return commands
end

return M
