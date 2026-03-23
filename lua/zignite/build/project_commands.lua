local config = require("zignite.config")
local detect = require("zignite.build.detect")
local parsers = require("zignite.build.project_parsers")
local state = require("zignite.build.state")
local systems = require("zignite.build.systems")
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
local function mirror_command(target, alias, source_key)
	if target[source_key] then
		target[alias] = target[source_key]
	end
end

---@param target table<string, string>
---@param alias_map table<string, string>
---@return nil
local function mirror_commands(target, alias_map)
	for alias, source_key in pairs(alias_map or {}) do
		mirror_command(target, alias, source_key)
	end
end

---@param target table<string, string>
---@param candidates table<string, string|nil>
---@return nil
local function fill_missing_commands(target, candidates)
	for key, value in pairs(candidates or {}) do
		if target[key] == nil and type(value) == "string" and value ~= "" then
			target[key] = value
		end
	end
end

---@param commands table<string, string>|nil
---@return boolean
local function has_commands(commands)
	return type(commands) == "table" and next(commands) ~= nil
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

---@param filtered table<string, string>
---@param configured table<string, string>
---@param command_key string
---@param configured_key string
---@param primary_run string|nil
---@param fallback_build_command string|nil
---@return nil
local function set_system_run_command(
	filtered,
	configured,
	command_key,
	configured_key,
	primary_run,
	fallback_build_command
)
	if type(primary_run) == "string" and primary_run ~= "" then
		filtered[command_key] = primary_run
		filtered.run = filtered[command_key]
		return
	end

	local configured_run = configured[configured_key]
	if type(configured_run) ~= "string" or configured_run == "" then
		return
	end

	if type(fallback_build_command) == "string" and fallback_build_command ~= "" then
		filtered[command_key] = fallback_build_command .. " && " .. configured_run
	else
		filtered[command_key] = configured_run
	end
	filtered.run = filtered[command_key]
end

---@param configured table<string, string>
---@param parser_commands table<string, string>
---@param selected_keys string[]
---@param fallback_commands table<string, string|nil>
---@param alias_map table<string, string>
---@param run_command_key string
---@param run_configured_key string
---@param fallback_build_command string|nil
---@return table<string, string>
local function build_namespaced_system_commands(
	configured,
	parser_commands,
	selected_keys,
	fallback_commands,
	alias_map,
	run_command_key,
	run_configured_key,
	fallback_build_command
)
	local filtered = copy_selected_commands(configured, selected_keys)
	M.extend_string_map(filtered, parser_commands)
	fill_missing_commands(filtered, fallback_commands)
	mirror_commands(filtered, alias_map)
	set_system_run_command(
		filtered,
		configured,
		run_command_key,
		run_configured_key,
		parser_commands.run or parser_commands[run_command_key],
		fallback_build_command
	)
	return filtered
end

---@param configured table<string, string>
---@param parser_commands table<string, string>
---@param selected_keys string[]
---@return table<string, string>
local function build_backend_system_commands(configured, parser_commands, selected_keys)
	local filtered = copy_selected_commands(configured, selected_keys)
	M.extend_string_map(filtered, parser_commands)
	return filtered
end

---@param configured table<string, string>
---@param root string
---@param cmake_commands table<string, string>
---@param root string
---@return table<string, string>
local function build_cmake_commands(configured, root, cmake_commands)
	if has_commands(cmake_commands) then
		return build_backend_system_commands(configured, cmake_commands, {
			"cmake-config",
			"cmake-build",
			"cmake-clean",
			"cmake-debug",
			"cmake-release",
			"cmake-test",
			"cmake-run",
		})
	end

	return build_namespaced_system_commands(
		configured,
		cmake_commands,
		{
			"cmake-config",
			"cmake-build",
			"cmake-clean",
			"cmake-debug",
			"cmake-release",
			"cmake-test",
			"cmake-run",
			"install",
		},
		{
			["cmake-config"] = cmake_commands["cmake-config"] or systems.cmake_config_command(root),
			["cmake-clean"] = cmake_commands["cmake-clean"] or systems.cmake_clean_command(root),
			["cmake-debug"] = cmake_commands["cmake-debug"]
				or "cmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
			["cmake-release"] = cmake_commands["cmake-release"]
				or "cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
			["cmake-test"] = cmake_commands["cmake-test"] or "ctest --test-dir build",
			install = cmake_commands.install or "cmake --build build --target install",
			["cmake-build"] = cmake_commands["cmake-build"] or systems.cmake_build_command(root, nil),
		},
		{
			build = "cmake-build",
			clean = "cmake-clean",
			debug = "cmake-debug",
			release = "cmake-release",
			test = "cmake-test",
			config = "cmake-config",
		},
		"cmake-run",
		"cmake-run",
		cmake_commands["cmake-build"] or systems.cmake_build_command(root, nil)
	)
end

---@param configured table<string, string>
---@param root string
---@param meson_commands table<string, string>
---@param root string
---@return table<string, string>
local function build_meson_commands(configured, root, meson_commands)
	if has_commands(meson_commands) then
		return build_backend_system_commands(configured, meson_commands, {
			"meson-setup",
			"meson-build",
			"meson-clean",
			"meson-test",
			"meson-run",
		})
	end

	return build_namespaced_system_commands(
		configured,
		meson_commands,
		{
			"meson-setup",
			"meson-build",
			"meson-clean",
			"meson-test",
			"meson-run",
			"install",
		},
		{
			["meson-setup"] = meson_commands["meson-setup"] or systems.meson_setup_command(root),
			["meson-clean"] = meson_commands["meson-clean"] or systems.meson_clean_command(root),
			["meson-test"] = meson_commands["meson-test"] or "meson test -C build",
			install = meson_commands.install or "meson install -C build",
			["meson-build"] = meson_commands["meson-build"] or systems.meson_build_command(root, nil),
		},
		{
			build = "meson-build",
			clean = "meson-clean",
			test = "meson-test",
			setup = "meson-setup",
		},
		"meson-run",
		"meson-run",
		meson_commands["meson-build"] or systems.meson_build_command(root, nil)
	)
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

---@param filetype string
---@param filepath string
---@param is_detection_enabled fun(flag: string): boolean
---@return table<string, string>
function M.collect_sync_detected_commands(filetype, filepath, is_detection_enabled)
	return parsers.collect_sync_project_commands(filetype, filepath, is_detection_enabled)
end

---@param filetype string
---@param filepath string
---@param is_detection_enabled fun(flag: string): boolean
---@return table<string, string>
function M.detect_tool_commands_for_filetype(filetype, filepath, is_detection_enabled)
	local commands = M.collect_sync_detected_commands(filetype, filepath, is_detection_enabled)
	local detector = TOOL_DETECTORS[filetype]
	if detector and is_detection_enabled(detector.flag) then
		M.extend_string_map(commands, detector.sync())
	end
	return commands
end

---@param filetype string
---@param filepath string
---@param on_done fun(commands: table<string, string>|nil):nil
---@param force_refresh boolean|nil
---@param is_detection_enabled fun(flag: string): boolean
---@return nil
function M.detect_tool_commands_for_filetype_async(filetype, filepath, on_done, force_refresh, is_detection_enabled)
	local sync_commands = M.collect_sync_detected_commands(filetype, filepath, is_detection_enabled)

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
---@return table<string, string>
function M.get_configured_build_commands(filetype, filepath)
	local configured = state.copy_string_map(config.options.build_commands[filetype] or {})
	if filetype == "javascript" or filetype == "typescript" then
		return apply_node_package_manager_defaults(filetype, filepath, configured)
	end
	if filetype == "python" then
		return apply_python_tool_defaults(filepath, configured)
	end
	local parser_result = parsers.detect_parser_backed_build_result(filetype, filepath)
	if parser_result then
		local detect_enabled = config_detection_enabled()
		if parser_result.detect_flag and not detect_enabled(parser_result.detect_flag) then
			return configured
		end
		return merge_parser_backed_commands(configured, parser_result.commands)
	end
	if filetype ~= "c" and filetype ~= "cpp" then
		return configured
	end

	local c_family_result = parsers.detect_c_family_build_result(filepath)
	if not c_family_result or c_family_result.system == nil then
		return configured
	end
	if c_family_result.system == "bazel" then
		return {}
	end

	---@type table<string, string>
	local filtered = {}
	if c_family_result.system == "make" then
		for _, key in ipairs({ "build", "run", "clean", "test", "install", "debug" }) do
			if configured[key] then
				filtered[key] = configured[key]
			end
		end
		return filtered
	end

	if c_family_result.system == "cmake" then
			return build_cmake_commands(configured, c_family_result.root, c_family_result.commands)
		end

		if c_family_result.system == "meson" then
			return build_meson_commands(configured, c_family_result.root, c_family_result.commands)
		end

	return configured
end

---@param filetype string
---@param filepath string
---@param detected table<string, string>|nil
---@return table<string, string>
function M.merge_build_commands(filetype, filepath, detected)
	local merged = state.copy_string_map(detected)
	local configured = M.get_configured_build_commands(filetype, filepath)
	for key, value in pairs(configured) do
		if type(key) == "string" and type(value) == "string" then
			merged[key] = value
		end
	end
	return merged
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
		local detected_scripts = parsers.detect_package_scripts(filepath)
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
