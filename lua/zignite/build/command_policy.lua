local config = require("zignite.config")
local detect = require("zignite.build.detect")
local backend = require("zignite.build.project_query")
local state = require("zignite.build.state")
local systems = require("zignite.build.system_runtime")
local utils = require("zignite.utils")

---@type table
local M = {}
local LIVE_COMMAND_PRIORITY = { "live", "dev", "watch", "serve", "start", "preview" }
local TOOL_DETECTORS = {
	zig = {
		flag = "zig",
		sync = detect.detect_zig_tool_commands,
		async = detect.detect_zig_tool_commands_async,
	},
	go = {
		flag = "go",
		sync = detect.detect_go_tool_commands,
		async = detect.detect_go_tool_commands_async,
	},
	rust = {
		flag = "rust",
		sync = detect.detect_rust_tool_commands,
		async = detect.detect_rust_tool_commands_async,
	},
	odin = {
		flag = "odin",
		sync = detect.detect_odin_tool_commands,
		async = detect.detect_odin_tool_commands_async,
	},
}
local C_FAMILY_COMMAND_SPECS = {
	cmake = {
		selected_keys = {
			"cmake-config",
			"cmake-build",
			"cmake-clean",
			"cmake-debug",
			"cmake-release",
			"cmake-test",
			"cmake-run",
			"install",
		},
		alias_map = {
			build = "cmake-build",
			clean = "cmake-clean",
			debug = "cmake-debug",
			release = "cmake-release",
			test = "cmake-test",
			config = "cmake-config",
			run = "cmake-run",
		},
	},
	meson = {
		selected_keys = {
			"meson-setup",
			"meson-build",
			"meson-clean",
			"meson-test",
			"meson-run",
			"install",
		},
		alias_map = {
			build = "meson-build",
			clean = "meson-clean",
			test = "meson-test",
			setup = "meson-setup",
			run = "meson-run",
		},
	},
}

---@param filetype string
---@return table<string, string>
local function get_default_build_commands(filetype)
	return config.defaults.build_commands[filetype] or {}
end

---@param configured table<string, string>
---@return table<string, string>
local function copy_commands(configured)
	return state.copy_string_map(configured or {})
end

---@param configured table<string, string>
---@param keys string[]
---@return table<string, string>
local function copy_selected_commands(configured, keys)
	local selected = {}
	for _, key in ipairs(keys or {}) do
		local value = configured[key]
		if type(value) == "string" and value ~= "" then
			selected[key] = value
		end
	end
	return selected
end

---@param updated table<string, string>
---@param default_commands table<string, string>
---@param key string
---@param value string|nil
---@return nil
local function replace_default_command(updated, default_commands, key, value)
	if type(value) ~= "string" or value == "" then
		return
	end
	if updated[key] ~= nil and updated[key] == default_commands[key] then
		updated[key] = value
	end
end

---@param updated table<string, string>
---@param default_commands table<string, string>
---@param replacements table<string, string|nil>
---@return nil
local function replace_default_commands(updated, default_commands, replacements)
	for key, value in pairs(replacements or {}) do
		replace_default_command(updated, default_commands, key, value)
	end
end

---@param configured table<string, string>
---@param parser_commands table<string, string>|nil
---@return table<string, string>
local function merge_parser_backed_commands(configured, parser_commands)
	local updated = copy_commands(configured)
	M.extend_string_map(updated, parser_commands)
	return updated
end

---@param target table<string, string>
---@param alias string
---@param source_key string
---@return nil
local function fill_missing_aliases(target, alias_map)
	for alias, source_key in pairs(alias_map or {}) do
		if target[alias] == nil and type(source_key) == "string" and source_key ~= "" then
			local source_value = target[source_key]
			if type(source_value) == "string" and source_value ~= "" then
				target[alias] = source_value
			end
		end
	end
end

---@return fun(flag: string): boolean
local function config_detection_enabled()
	local detect_options = config.options.detect or {}
	return function(flag)
		local value = detect_options[flag]
		if value == nil then
			return true
		end
		return value == true
	end
end

---@param configured table<string, string>
---@param parser_commands table<string, string>|nil
---@param selected_keys string[]
---@param alias_map table<string, string>
---@return table<string, string>
local function build_filtered_system_commands(configured, parser_commands, selected_keys, alias_map)
	local filtered = copy_selected_commands(configured, selected_keys)
	M.extend_string_map(filtered, parser_commands)
	fill_missing_aliases(filtered, alias_map)
	return filtered
end

---@param configured table<string, string>
---@param system string
---@param system_commands table<string, string>
---@return table<string, string>
local function build_c_family_system_commands(configured, system, system_commands)
	local spec = C_FAMILY_COMMAND_SPECS[system]
	if type(spec) ~= "table" then
		return copy_commands(configured)
	end
	return build_filtered_system_commands(configured, system_commands, spec.selected_keys, spec.alias_map)
end

---@param configured table<string, string>
---@return table<string, string>
local function filter_make_commands(configured)
	local filtered = {}
	for _, key in ipairs({ "build", "run", "clean", "test", "install", "debug" }) do
		if configured[key] then
			filtered[key] = configured[key]
		end
	end
	return filtered
end

---@param filetype string
---@param filepath string
---@param configured table<string, string>
---@return table<string, string>
local function apply_node_package_manager_defaults(filetype, filepath, configured)
	if filetype ~= "javascript" and filetype ~= "typescript" then
		return configured
	end

	local package_manager = utils.detect_node_package_manager(filepath, config.options.project)
	if package_manager == "npm" then
		return configured
	end

	local default_commands = get_default_build_commands(filetype)
	local updated = copy_commands(configured)

	replace_default_commands(updated, default_commands, {
		start = utils.format_package_script_command(package_manager, "start"),
		dev = utils.format_package_script_command(package_manager, "dev"),
		build = utils.format_package_script_command(package_manager, "build"),
		test = utils.format_package_script_command(package_manager, "test"),
		install = utils.format_package_install_command(package_manager),
	})

	return updated
end

---@param filepath string
---@param configured table<string, string>
---@return table<string, string>
local function apply_python_tool_defaults(filepath, configured)
	local python_tool = utils.detect_python_project_tool(filepath, config.options.project)
	if python_tool ~= "uv" then
		return configured
	end

	local default_commands = get_default_build_commands("python")
	local updated = copy_commands(configured)

	replace_default_commands(updated, default_commands, {
		run = "uv run -m main",
		test = "uv run pytest",
		install = "uv sync",
	})

	return updated
end

function M.extend_string_map(target, source)
	if type(source) ~= "table" then
		return target
	end
	for key, value in pairs(source) do
		if type(key) == "string" and type(value) == "string" then
			target[key] = value
		end
	end
	return target
end

---@param commands table<string, string>
---@param filetype string
---@param is_detection_enabled fun(flag: string): boolean
---@return table<string, string>
local function append_sync_tool_detector_commands(commands, filetype, is_detection_enabled)
	local detector = TOOL_DETECTORS[filetype]
	if detector and is_detection_enabled(detector.flag) then
		M.extend_string_map(commands, detector.sync())
	end
	return commands
end

---@param sync_commands table<string, string>
---@param filetype string
---@param on_done fun(commands: table<string, string>|nil):nil
---@param force_refresh boolean|nil
---@param is_detection_enabled fun(flag: string): boolean
---@return nil
local function finish_with_async_tool_detector(sync_commands, filetype, on_done, force_refresh, is_detection_enabled)
	---@param async_commands table<string, string>|nil
	---@return nil
	local function finish(async_commands)
		if async_commands == nil then
			if vim.tbl_isempty(sync_commands) then
				on_done(nil)
			else
				on_done(state.copy_string_map(sync_commands))
			end
			return
		end

		local merged = state.copy_string_map(sync_commands)
		M.extend_string_map(merged, async_commands)
		on_done(merged)
	end

	local detector = TOOL_DETECTORS[filetype]
	if detector and is_detection_enabled(detector.flag) then
		detector.async(finish, force_refresh)
		return
	end
	vim.schedule(function()
		on_done(state.copy_string_map(sync_commands))
	end)
end

---@param filetype string
---@param filepath string
---@param is_detection_enabled fun(flag: string): boolean
---@param cached boolean|nil
---@return table<string, string>
local function collect_sync_project_detected_commands(filetype, filepath, is_detection_enabled, cached)
	local _ = is_detection_enabled
	local commands
	if cached then
		commands = backend.collect_sync_project_commands_cached(filetype, filepath, is_detection_enabled)
	else
		commands = backend.collect_sync_project_commands(filetype, filepath, is_detection_enabled)
	end
	return commands
end

---@param filetype string
---@param filepath string
---@param cached boolean|nil
---@return table<string, string>
local function get_configured_build_commands_internal(filetype, filepath, cached)
	local configured = state.copy_string_map(config.options.build_commands[filetype] or {})
	local detect_enabled = config_detection_enabled()
	if filetype == "javascript" or filetype == "typescript" then
		return apply_node_package_manager_defaults(filetype, filepath, configured)
	end
	if filetype == "python" then
		return apply_python_tool_defaults(filepath, configured)
	end
	if cached and detect_enabled("bazel_project") and systems.supports_bazel_project_commands(filetype) then
		local bazel_commands = backend.detect_bazel_project_commands_cached(filepath)
		if next(bazel_commands) ~= nil then
			return state.copy_string_map(bazel_commands)
		end
	end
	if cached and (filetype == "java" or filetype == "kotlin") and detect_enabled("java_kotlin_project") then
		local java_commands = backend.detect_java_like_project_commands_cached(filepath)
		if next(java_commands) ~= nil then
			return merge_parser_backed_commands(configured, java_commands)
		end
	end

	local parser_result = backend.detect_parser_backed_build_result(filetype, filepath)
	if parser_result then
		if parser_result.detect_flag and not detect_enabled(parser_result.detect_flag) then
			return configured
		end
		return merge_parser_backed_commands(configured, parser_result.commands)
	end
	if filetype ~= "c" and filetype ~= "cpp" then
		return configured
	end

	local c_family_result
	if cached then
		c_family_result = backend.detect_c_family_build_result_cached(filepath)
	else
		c_family_result = backend.detect_c_family_build_result(filepath)
	end
	if not c_family_result or c_family_result.system == nil then
		return configured
	end
	if c_family_result.system == "bazel" then
		return {}
	end
	if c_family_result.system == "make" then
		return filter_make_commands(configured)
	end
	if c_family_result.system == "cmake" or c_family_result.system == "meson" then
		return build_c_family_system_commands(configured, c_family_result.system, c_family_result.commands)
	end
	return configured
end

---@param filetype string
---@param filepath string
---@param detected table<string, string>|nil
---@param cached boolean|nil
---@return table<string, string>
local function merge_build_commands_internal(filetype, filepath, detected, cached)
	local merged = state.copy_string_map(detected)
	local configured = get_configured_build_commands_internal(filetype, filepath, cached)
	for key, value in pairs(configured) do
		if type(key) == "string" and type(value) == "string" then
			merged[key] = value
		end
	end
	return merged
end

---@param filetype string
---@param filepath string
---@param is_detection_enabled fun(flag: string): boolean
---@return table<string, string>
function M.collect_sync_detected_commands(filetype, filepath, is_detection_enabled)
	return collect_sync_project_detected_commands(filetype, filepath, is_detection_enabled, false)
end

---@param filetype string
---@param filepath string
---@param is_detection_enabled fun(flag: string): boolean
---@return table<string, string>
function M.collect_sync_detected_commands_cached(filetype, filepath, is_detection_enabled)
	return collect_sync_project_detected_commands(filetype, filepath, is_detection_enabled, true)
end

---@param filetype string
---@param filepath string
---@param is_detection_enabled fun(flag: string): boolean
---@return table<string, string>
function M.detect_tool_commands_for_filetype(filetype, filepath, is_detection_enabled)
	local commands = collect_sync_project_detected_commands(filetype, filepath, is_detection_enabled, false)
	return append_sync_tool_detector_commands(commands, filetype, is_detection_enabled)
end

---@param filetype string
---@param filepath string
---@param on_done fun(commands: table<string, string>|nil):nil
---@param force_refresh boolean|nil
---@param is_detection_enabled fun(flag: string): boolean
---@return nil
function M.detect_tool_commands_for_filetype_async(filetype, filepath, on_done, force_refresh, is_detection_enabled)
	local sync_commands = M.collect_sync_detected_commands(filetype, filepath, is_detection_enabled)
	finish_with_async_tool_detector(sync_commands, filetype, on_done, force_refresh, is_detection_enabled)
end

---@param filetype string
---@param filepath string
---@param on_done fun(commands: table<string, string>|nil):nil
---@param force_refresh boolean|nil
---@param is_detection_enabled fun(flag: string): boolean
---@return nil
function M.detect_tool_commands_for_filetype_async_cached(
	filetype,
	filepath,
	on_done,
	force_refresh,
	is_detection_enabled
)
	local sync_commands = M.collect_sync_detected_commands_cached(filetype, filepath, is_detection_enabled)
	finish_with_async_tool_detector(sync_commands, filetype, on_done, force_refresh, is_detection_enabled)
end

---@param filetype string
---@param filepath string
---@return table<string, string>
function M.get_configured_build_commands(filetype, filepath)
	return get_configured_build_commands_internal(filetype, filepath, false)
end

---@param filetype string
---@param filepath string
---@return table<string, string>
function M.get_configured_build_commands_cached(filetype, filepath)
	return get_configured_build_commands_internal(filetype, filepath, true)
end

---@param filetype string
---@param filepath string
---@param detected table<string, string>|nil
---@return table<string, string>
function M.merge_build_commands(filetype, filepath, detected)
	return merge_build_commands_internal(filetype, filepath, detected, false)
end

---@param filetype string
---@param filepath string
---@param detected table<string, string>|nil
---@return table<string, string>
function M.merge_build_commands_cached(filetype, filepath, detected)
	return merge_build_commands_internal(filetype, filepath, detected, true)
end

---@param filetype string
---@param filepath string
---@return table|nil
function M.get_preferred_project_command(filetype, filepath)
	local is_detection_enabled = config_detection_enabled()
	local build_cmds = M.merge_build_commands(
		filetype,
		filepath,
		M.detect_tool_commands_for_filetype(filetype, filepath, is_detection_enabled)
	)
	local root = utils.get_project_root(filepath, config.options.project)
	if not root then
		root = vim.fn.fnamemodify(filepath, ":h")
	end

	local preferred_name = build_cmds.run and "run"
		or M.select_live_command_name_for_filetype(filetype, filepath, build_cmds, is_detection_enabled)
		or build_cmds.start and "start"
		or build_cmds.build and "build"
		or nil
	if not preferred_name or type(build_cmds[preferred_name]) ~= "string" then
		return nil
	end
	return {
		name = string.format("%s Project", filetype:gsub("^%l", string.upper)),
		command = build_cmds[preferred_name],
		root = root,
	}
end

---@param filetype string
---@param filepath string
---@param build_cmds table<string, string>
---@param is_detection_enabled fun(flag: string): boolean
---@return string|nil
function M.select_live_command_name_for_filetype(filetype, filepath, build_cmds, is_detection_enabled)
	if
		(filetype == "javascript" or filetype == "typescript")
		and type(is_detection_enabled) == "function"
		and is_detection_enabled("js_package_scripts")
	then
		local detected_scripts = backend.detect_package_scripts(filepath)
		for _, candidate in ipairs(LIVE_COMMAND_PRIORITY) do
			if type(detected_scripts[candidate]) == "string" then
				return candidate
			end
		end

		local configured = M.get_configured_build_commands(filetype, filepath)
		local default_commands = get_default_build_commands(filetype)
		for _, candidate in ipairs(LIVE_COMMAND_PRIORITY) do
			local command = build_cmds[candidate]
			if type(command) == "string" then
				local configured_command = configured[candidate]
				local is_default_fallback = configured_command ~= nil
					and command == configured_command
					and configured_command == default_commands[candidate]
				if not is_default_fallback then
					return candidate
				end
			end
		end
		return nil
	end

	return M.select_live_command_name(build_cmds)
end

---@param build_cmds table<string, string>
---@return string|nil
function M.select_live_command_name(build_cmds)
	for _, candidate in ipairs(LIVE_COMMAND_PRIORITY) do
		if build_cmds[candidate] then
			return candidate
		end
	end
	return nil
end


return M
