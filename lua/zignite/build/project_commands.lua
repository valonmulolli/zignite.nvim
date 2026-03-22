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
---@param build_tree_ready boolean
---@param setup_command string
---@return nil
local function set_system_run_command(
	filtered,
	configured,
	command_key,
	configured_key,
	primary_run,
	build_tree_ready,
	setup_command
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

	filtered[command_key] = build_tree_ready
		and configured_run
		or (setup_command .. " && " .. configured_run)
	filtered.run = filtered[command_key]
end

---@param configured table<string, string>
---@param filepath string
---@param root string
---@return table<string, string>
local function build_cmake_commands(configured, filepath, root)
	---@type table<string, string>
	local filtered = {}
	filtered["cmake-config"] = configured["cmake-config"] or systems.cmake_config_command(root)
	filtered["cmake-build"] = systems.cmake_build_command(root, nil)
	filtered["cmake-clean"] = systems.cmake_clean_command(root)
	filtered["cmake-debug"] = configured["cmake-debug"]
		or "cmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build"
	filtered["cmake-release"] = configured["cmake-release"]
		or "cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build"
	filtered["cmake-test"] = configured["cmake-test"] or "ctest --test-dir build"
	filtered.install = "cmake --build build --target install"
	mirror_commands(filtered, {
		build = "cmake-build",
		clean = "cmake-clean",
		debug = "cmake-debug",
		release = "cmake-release",
		test = "cmake-test",
		config = "cmake-config",
	})

	local _, cmake_info = parsers.detect_cmake_project_commands(filepath)
	set_system_run_command(
		filtered,
		configured,
		"cmake-run",
		"cmake-run",
		cmake_info and cmake_info.primary_run or nil,
		systems.has_cmake_build_tree(root),
		systems.cmake_config_command(root)
	)

	return filtered
end

---@param configured table<string, string>
---@param filepath string
---@param root string
---@return table<string, string>
local function build_meson_commands(configured, filepath, root)
	---@type table<string, string>
	local filtered = {}
	filtered["meson-setup"] = configured["meson-setup"] or systems.meson_setup_command(root)
	filtered["meson-build"] = systems.meson_build_command(root, nil)
	filtered["meson-clean"] = systems.meson_clean_command(root)
	filtered["meson-test"] = configured["meson-test"] or "meson test -C build"
	filtered.install = "meson install -C build"
	mirror_commands(filtered, {
		build = "meson-build",
		clean = "meson-clean",
		test = "meson-test",
		setup = "meson-setup",
	})

	local _, meson_info = parsers.detect_meson_project_commands(filepath)
	set_system_run_command(
		filtered,
		configured,
		"meson-run",
		"meson-run",
		meson_info and meson_info.primary_run or nil,
		systems.has_meson_build_tree(root),
		systems.meson_setup_command(root)
	)

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

---@param filetype string
---@param filepath string
---@param is_detection_enabled fun(flag: string): boolean
---@return table<string, string>
function M.collect_sync_detected_commands(filetype, filepath, is_detection_enabled)
	---@type table<string, string>
	local commands = {}

	if filetype == "c" or filetype == "cpp" then
		local system = systems.detect_c_family_build_system(filepath)
		if system == "make" and is_detection_enabled("c_cpp_make") then
			M.extend_string_map(commands, parsers.detect_makefile_targets(filepath))
		elseif system == "cmake" then
			local cmake_commands = parsers.detect_cmake_project_commands(filepath)
			M.extend_string_map(commands, cmake_commands)
		elseif system == "meson" then
			local meson_commands = parsers.detect_meson_project_commands(filepath)
			M.extend_string_map(commands, meson_commands)
		end
	end
	if (filetype == "javascript" or filetype == "typescript") and is_detection_enabled("js_package_scripts") then
		M.extend_string_map(commands, parsers.detect_package_scripts(filepath))
	end
	if (filetype == "java" or filetype == "kotlin") and is_detection_enabled("java_kotlin_project") then
		M.extend_string_map(commands, parsers.detect_java_like_project_commands(filepath))
	end
	if is_detection_enabled("bazel_project") and systems.supports_bazel_project_commands(filetype) then
		M.extend_string_map(commands, parsers.detect_bazel_project_commands(filepath))
	end

	return commands
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
	if filetype == "go" then
		local updated = copy_commands(configured)
		local go_commands, go_info = parsers.detect_go_project_commands(filepath)
		M.extend_string_map(updated, go_commands)
		local default_commands = get_default_build_commands("go")
		replace_default_commands(updated, default_commands, {
			build = go_info and go_info.primary_build or nil,
			run = go_info and go_info.primary_run or nil,
			test = go_info and go_info.primary_test or nil,
		})
		return updated
	end
	if filetype == "rust" then
		local detect_options = config.options.detect or {}
		if detect_options.rust == false then
			return configured
		end
		local updated = copy_commands(configured)
		local cargo_commands, cargo_info = parsers.detect_cargo_project_commands(filepath)
		M.extend_string_map(updated, cargo_commands)
		local default_commands = get_default_build_commands("rust")
		replace_default_command(updated, default_commands, "run", cargo_info and cargo_info.primary_run or nil)
		replace_default_command(
			updated,
			default_commands,
			"release-run",
			cargo_info and cargo_info.primary_release_run or nil
		)
		return updated
	end
	if filetype ~= "c" and filetype ~= "cpp" then
		return configured
	end

	local system, root = systems.detect_c_family_build_system(filepath)
	if system == nil then
		return configured
	end
	if system == "bazel" then
		return {}
	end

	---@type table<string, string>
	local filtered = {}
	if system == "make" then
		for _, key in ipairs({ "build", "run", "clean", "test", "install", "debug" }) do
			if configured[key] then
				filtered[key] = configured[key]
			end
		end
		return filtered
	end

	if system == "cmake" then
		return build_cmake_commands(configured, filepath, root)
	end

	if system == "meson" then
		return build_meson_commands(configured, filepath, root)
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
