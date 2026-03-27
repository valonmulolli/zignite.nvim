local config = require("zignite.config")
local build_resolve = require("zignite.backend.build_resolve")
local config_sync = require("zignite.backend.config_sync")
local tooling_query = require("zignite.build.tooling.query")
local project_query = require("zignite.build.project_query")
local cache_state = require("zignite.build.cache_state")
local systems = require("zignite.build.system_runtime")
local project_utils = require("zignite.utils.project")

---@type table
local M = {}
local LIVE_COMMAND_PRIORITY = { "live", "dev", "watch", "serve", "start", "preview" }
local TOOL_DETECTORS = {
	zig = {
		flag = "zig",
		sync = tooling_query.detect_zig_tool_commands,
		async = tooling_query.detect_zig_tool_commands_async,
	},
	go = {
		flag = "go",
		sync = tooling_query.detect_go_tool_commands,
		async = tooling_query.detect_go_tool_commands_async,
	},
	rust = {
		flag = "rust",
		sync = tooling_query.detect_rust_tool_commands,
		async = tooling_query.detect_rust_tool_commands_async,
	},
	odin = {
		flag = "odin",
		sync = tooling_query.detect_odin_tool_commands,
		async = tooling_query.detect_odin_tool_commands_async,
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
local function extend_string_map(target, source)
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

---@param filetype string
---@param configured table<string, string>
---@param available_commands table<string, string>|nil
---@return table<string, string>
local function merge_contextual_command_map(filetype, configured, available_commands)
	local merged = cache_state.copy_string_map(available_commands or {})
	extend_string_map(merged, select_contextual_overrides(filetype, configured, available_commands))
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
		return cache_state.copy_string_map(configured or {})
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

---@param commands table<string, string>
---@param filetype string
---@param is_detection_enabled fun(flag: string): boolean
---@return table<string, string>
local function append_sync_tool_detector_commands(commands, filetype, is_detection_enabled)
	local detector = TOOL_DETECTORS[filetype]
	if detector and is_detection_enabled(detector.flag) then
		extend_string_map(commands, detector.sync())
	end
	return commands
end

---@param filetype string
---@param is_detection_enabled fun(flag: string): boolean
---@return table<string, string>
function M.detect_direct_tool_commands_for_filetype(filetype, is_detection_enabled)
	return append_sync_tool_detector_commands({}, filetype, is_detection_enabled)
end

---@param filepath string
---@return boolean
local function can_use_backend_build_resolve(filepath)
	if type(filepath) ~= "string" or filepath == "" then
		return false
	end
	return tonumber(config_sync.get_last_synced_revision and config_sync.get_last_synced_revision() or 0)
		== tonumber(config.revision or 0)
end

---@param filepath string
---@return string|nil
local function resolve_backend_project_root(filepath)
	return project_utils.get_project_root(filepath, config.options.project)
end

---@param resolved table|nil
---@return table|nil
local function normalize_backend_resolved_commands(resolved)
	if type(resolved) ~= "table" or type(resolved.commands) ~= "table" or vim.tbl_isempty(resolved.commands) then
		return nil
	end
	return resolved
end

---@param filetype string
---@param filepath string
---@return boolean
function M.can_resolve_backend_build_commands(filetype, filepath)
	local _ = filetype
	return can_use_backend_build_resolve(filepath)
end

---@param filetype string
---@param filepath string
---@return table|nil
function M.resolve_backend_build_commands(filetype, filepath)
	if not M.can_resolve_backend_build_commands(filetype, filepath) then
		return nil
	end

	return normalize_backend_resolved_commands(
		build_resolve.resolve_sync(filepath, filetype, resolve_backend_project_root(filepath))
	)
end

---@param filetype string
---@param filepath string
---@param on_done fun(resolved: table|nil):nil
---@return boolean
function M.resolve_backend_build_commands_async(filetype, filepath, on_done)
	if not M.can_resolve_backend_build_commands(filetype, filepath) then
		return false
	end

	return build_resolve.resolve_async(filepath, filetype, resolve_backend_project_root(filepath), function(resolved)
		on_done(normalize_backend_resolved_commands(resolved))
	end)
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
				on_done(cache_state.copy_string_map(sync_commands))
			end
			return
		end

		local merged = cache_state.copy_string_map(sync_commands)
		extend_string_map(merged, async_commands)
		on_done(merged)
	end

	local detector = TOOL_DETECTORS[filetype]
	if detector and is_detection_enabled(detector.flag) then
		detector.async(finish, force_refresh)
		return
	end
	vim.schedule(function()
		on_done(cache_state.copy_string_map(sync_commands))
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
		commands = project_query.collect_sync_project_commands_cached(filetype, filepath, is_detection_enabled)
	else
		commands = project_query.collect_sync_project_commands(filetype, filepath, is_detection_enabled)
	end
	return commands
end

---@param filepath string
---@param cached boolean|nil
---@param detect_enabled fun(flag: string): boolean
---@return table<string, string>|nil
local function detect_javascript_project_commands(filepath, cached, detect_enabled)
	if detect_enabled("js_package_scripts") then
		local package_commands = project_query.detect_package_scripts(filepath)
		if next(package_commands) ~= nil then
			return package_commands
		end
	end
	local detect_node = cached and project_query.detect_node_project_commands_cached
		or project_query.detect_node_project_commands
	local node_commands = detect_node(filepath)
	if next(node_commands) ~= nil then
		return node_commands
	end
	return nil
end

---@param filepath string
---@param cached boolean|nil
---@return table<string, string>|nil
local function detect_python_project_commands(filepath, cached)
	local detect_python = cached
			and project_query.detect_python_project_commands_cached
		or project_query.detect_python_project_commands
	local python_commands = detect_python(filepath)
	if next(python_commands) ~= nil then
		return python_commands
	end
	return nil
end

---@param filetype string
---@param filepath string
---@param cached boolean|nil
---@param detect_enabled fun(flag: string): boolean
---@return table<string, string>|nil
local function detect_contextual_project_commands(filetype, filepath, cached, detect_enabled)
	if filetype == "javascript" or filetype == "typescript" then
		return detect_javascript_project_commands(filepath, cached, detect_enabled)
	end
	if filetype == "python" then
		return detect_python_project_commands(filepath, cached)
	end
	if cached and detect_enabled("bazel_project") and systems.supports_bazel_project_commands(filetype) then
		local bazel_commands = project_query.detect_bazel_project_commands_cached(filepath)
		if next(bazel_commands) ~= nil then
			return bazel_commands
		end
	end
	if cached and (filetype == "java" or filetype == "kotlin") and detect_enabled("java_kotlin_project") then
		local java_commands = project_query.detect_java_like_project_commands_cached(filepath)
		if next(java_commands) ~= nil then
			return java_commands
		end
	end
	return nil
end

---@param configured table<string, string>
---@param filetype string
---@param c_family_result table|nil
---@return table<string, string>
local function resolve_c_family_configured_commands(configured, filetype, c_family_result)
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
---@param cached boolean|nil
---@return table<string, string>
local function get_configured_build_commands_internal(filetype, filepath, cached)
	local configured = cache_state.copy_string_map(config.options.build_commands[filetype] or {})
	local detect_enabled = config_detection_enabled()
	local contextual_commands = detect_contextual_project_commands(filetype, filepath, cached, detect_enabled)
	if contextual_commands then
		return merge_contextual_command_map(filetype, configured, contextual_commands)
	end

	local parser_result = project_query.detect_parser_backed_build_result(filetype, filepath)
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

	local c_family_result = cached and project_query.detect_c_family_build_result_cached(filepath)
		or project_query.detect_c_family_build_result(filepath)
	return resolve_c_family_configured_commands(configured, filetype, c_family_result)
end

---@param filetype string
---@param filepath string
---@param detected table<string, string>|nil
---@param cached boolean|nil
---@return table<string, string>
local function merge_build_commands_internal(filetype, filepath, detected, cached)
	local merged = cache_state.copy_string_map(detected)
	extend_string_map(merged, get_configured_build_commands_internal(filetype, filepath, cached))
	return merged
end

---@param filetype string
---@param filepath string
---@param is_detection_enabled fun(flag: string): boolean
---@return table<string, string>
local function collect_sync_detected_commands(filetype, filepath, is_detection_enabled)
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
	local sync_commands = collect_sync_detected_commands(filetype, filepath, is_detection_enabled)
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
	local backend_resolved = M.resolve_backend_build_commands(filetype, filepath)
	local build_cmds
	if backend_resolved then
		build_cmds = M.detect_direct_tool_commands_for_filetype(filetype, is_detection_enabled)
		extend_string_map(build_cmds, backend_resolved.commands)
	else
		build_cmds = M.merge_build_commands(
			filetype,
			filepath,
			M.detect_tool_commands_for_filetype(filetype, filepath, is_detection_enabled)
		)
	end
	local root = project_utils.get_project_root(filepath, config.options.project)
	if not root then
		root = vim.fn.fnamemodify(filepath, ":h")
	end

	local preferred_commands = type(backend_resolved) == "table" and backend_resolved.preferred_commands or nil
	local preferred_name = type(preferred_commands) == "table" and preferred_commands.run and "run"
		or M.select_live_command_name_for_filetype(
			filetype,
			filepath,
			type(preferred_commands) == "table" and preferred_commands or build_cmds,
			is_detection_enabled
		)
		or (type(preferred_commands) == "table" and preferred_commands.start and "start")
		or (type(preferred_commands) == "table" and preferred_commands.build and "build")
		or build_cmds.run and "run"
		or M.select_live_command_name_for_filetype(filetype, filepath, build_cmds, is_detection_enabled)
		or build_cmds.start and "start"
		or build_cmds.build and "build"
		or nil
	local preferred_source = type(preferred_commands) == "table" and preferred_commands or build_cmds
	if not preferred_name or type(preferred_source[preferred_name]) ~= "string" then
		return nil
	end
	return {
		name = string.format("%s Project", filetype:gsub("^%l", string.upper)),
		command = preferred_source[preferred_name],
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
		return type(build_cmds.live) == "string" and "live" or nil
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
