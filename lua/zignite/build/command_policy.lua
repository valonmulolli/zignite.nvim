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
local C_FAMILY_FALLBACK_KEYS = {
	cmake = {
		"cmake-config",
		"cmake-build",
		"cmake-clean",
		"cmake-debug",
		"cmake-release",
		"cmake-test",
		"cmake-run",
		"install",
	},
	meson = {
		"meson-setup",
		"meson-build",
		"meson-clean",
		"meson-test",
		"meson-run",
		"install",
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
---@param default_commands table<string, string>|nil
---@param available_commands table<string, string>|nil
---@return table<string, string>
local function select_configured_command_overrides(configured, default_commands, available_commands)
	local selected = {}
	for key, value in pairs(configured or {}) do
		if type(key) == "string" and type(value) == "string" and available_commands and available_commands[key] ~= nil then
			local is_default_fallback = default_commands and default_commands[key] ~= nil and value == default_commands[key]
			if not is_default_fallback or value == available_commands[key] then
				selected[key] = value
			end
		end
	end
	return selected
end

---@param filetype string
---@param configured table<string, string>
---@param available_commands table<string, string>|nil
---@return table<string, string>
local function select_contextual_overrides(filetype, configured, available_commands)
	local default_commands = get_default_build_commands(filetype)
	if vim.tbl_isempty(default_commands) then
		return select_configured_command_overrides(configured, nil, available_commands)
	end
	return select_configured_command_overrides(configured, default_commands, available_commands)
end

---@param filetype string
---@param configured table<string, string>
---@param available_commands table<string, string>|nil
---@return table<string, string>
local function merge_contextual_command_map(filetype, configured, available_commands)
	local merged = state.copy_string_map(available_commands or {})
	M.extend_string_map(merged, select_contextual_overrides(filetype, configured, available_commands))
	return merged
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
---@param system string
---@return table<string, string>
local function build_c_family_fallback_commands(configured, system)
	local selected_keys = C_FAMILY_FALLBACK_KEYS[system]
	if type(selected_keys) ~= "table" then
		return copy_commands(configured)
	end
	local filtered = copy_selected_commands(configured, selected_keys)
	if system == "cmake" then
		filtered.config = filtered["cmake-config"]
		filtered.build = filtered["cmake-build"]
		filtered.clean = filtered["cmake-clean"]
		filtered.debug = filtered["cmake-debug"]
		filtered.release = filtered["cmake-release"]
		filtered.test = filtered["cmake-test"]
		filtered.run = filtered["cmake-run"]
	elseif system == "meson" then
		filtered.setup = filtered["meson-setup"]
		filtered.build = filtered["meson-build"]
		filtered.clean = filtered["meson-clean"]
		filtered.test = filtered["meson-test"]
		filtered.run = filtered["meson-run"]
	end
	return filtered
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
		if detect_enabled("js_package_scripts") then
			local package_commands = backend.detect_package_scripts(filepath)
			if next(package_commands) ~= nil then
				return merge_contextual_command_map(filetype, configured, package_commands)
			end
		end
		return apply_node_package_manager_defaults(filetype, filepath, configured)
	end
	if filetype == "python" then
		local python_commands = backend.detect_python_project_commands(filepath)
		if next(python_commands) ~= nil then
			return merge_contextual_command_map(filetype, configured, python_commands)
		end
		return configured
	end
	if cached and detect_enabled("bazel_project") and systems.supports_bazel_project_commands(filetype) then
		local bazel_commands = backend.detect_bazel_project_commands_cached(filepath)
		if next(bazel_commands) ~= nil then
			return merge_contextual_command_map(filetype, configured, bazel_commands)
		end
	end
	if cached and (filetype == "java" or filetype == "kotlin") and detect_enabled("java_kotlin_project") then
		local java_commands = backend.detect_java_like_project_commands_cached(filepath)
		if next(java_commands) ~= nil then
			return merge_contextual_command_map(filetype, configured, java_commands)
		end
	end

	local parser_result = backend.detect_parser_backed_build_result(filetype, filepath)
	if parser_result then
		if parser_result.detect_flag and not detect_enabled(parser_result.detect_flag) then
			return configured
		end
		if next(parser_result.commands or {}) ~= nil then
			return merge_contextual_command_map(filetype, configured, parser_result.commands)
		end
		return configured
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
	if next(c_family_result.commands or {}) ~= nil then
		return merge_contextual_command_map(filetype, configured, c_family_result.commands)
	end
	if c_family_result.system == "make" then
		return filter_make_commands(configured)
	end
	if c_family_result.system == "cmake" or c_family_result.system == "meson" then
		return build_c_family_fallback_commands(configured, c_family_result.system)
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
	local _ = filepath
	if
		(filetype == "javascript" or filetype == "typescript")
		and type(is_detection_enabled) == "function"
		and is_detection_enabled("js_package_scripts")
	then
		if type(build_cmds.live) == "string" then
			return "live"
		end

		local default_commands = get_default_build_commands(filetype)
		for _, candidate in ipairs(LIVE_COMMAND_PRIORITY) do
			if candidate == "live" then
				goto continue
			end
			local command = build_cmds[candidate]
			if type(command) == "string" and command ~= default_commands[candidate] then
				return candidate
			end
			::continue::
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
