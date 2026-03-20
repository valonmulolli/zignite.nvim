local config = require("zignite.config")
local detect = require("zignite.build.detect")
local parsers = require("zignite.build.project_parsers")
local state = require("zignite.build.state")
local systems = require("zignite.build.systems")
local utils = require("zignite.utils")

---@type table
local M = {}

---@param configured table<string, string>
---@return table<string, string>
local function copy_commands(configured)
	return state.copy_string_map(configured or {})
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

	local default_commands = config.defaults.build_commands[filetype] or {}
	local updated = copy_commands(configured)

	for _, key in ipairs({ "start", "dev", "build", "test" }) do
		if updated[key] ~= nil and updated[key] == default_commands[key] then
			updated[key] = utils.format_package_script_command(package_manager, key)
		end
	end
	if updated.install ~= nil and updated.install == default_commands.install then
		updated.install = utils.format_package_install_command(package_manager)
	end

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

	local default_commands = config.defaults.build_commands.python or {}
	local updated = copy_commands(configured)

	if updated.run ~= nil and updated.run == default_commands.run then
		updated.run = "uv run -m main"
	end
	if updated.test ~= nil and updated.test == default_commands.test then
		updated.test = "uv run pytest"
	end
	if updated.install ~= nil and updated.install == default_commands.install then
		updated.install = "uv sync"
	end

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
	if filetype == "zig" and is_detection_enabled("zig") then
		M.extend_string_map(commands, detect.detect_zig_tool_commands())
	elseif filetype == "go" and is_detection_enabled("go") then
		M.extend_string_map(commands, detect.detect_go_tool_commands())
	elseif filetype == "rust" and is_detection_enabled("rust") then
		M.extend_string_map(commands, detect.detect_rust_tool_commands())
	elseif filetype == "odin" and is_detection_enabled("odin") then
		M.extend_string_map(commands, detect.detect_odin_tool_commands())
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

	if filetype == "zig" and is_detection_enabled("zig") then
		detect.detect_zig_tool_commands_async(finish, force_refresh)
		return
	end
	if filetype == "go" and is_detection_enabled("go") then
		detect.detect_go_tool_commands_async(finish, force_refresh)
		return
	end
	if filetype == "rust" and is_detection_enabled("rust") then
		detect.detect_rust_tool_commands_async(finish, force_refresh)
		return
	end
	if filetype == "odin" and is_detection_enabled("odin") then
		detect.detect_odin_tool_commands_async(finish, force_refresh)
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
		filtered["cmake-config"] = configured["cmake-config"] or systems.cmake_config_command(root)
		filtered["cmake-build"] = systems.cmake_build_command(root, nil)
		filtered["cmake-clean"] = systems.cmake_clean_command(root)
		filtered["cmake-debug"] = configured["cmake-debug"]
			or "cmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build"
		filtered["cmake-release"] = configured["cmake-release"]
			or "cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build"
		filtered["cmake-test"] = configured["cmake-test"] or "ctest --test-dir build"
		if filtered["cmake-build"] then
			filtered.build = filtered["cmake-build"]
		end
		if filtered["cmake-clean"] then
			filtered.clean = filtered["cmake-clean"]
		end
		if filtered["cmake-debug"] then
			filtered.debug = filtered["cmake-debug"]
		end
		if filtered["cmake-release"] then
			filtered.release = filtered["cmake-release"]
		end
		if filtered["cmake-test"] then
			filtered.test = filtered["cmake-test"]
		end
		if filtered["cmake-config"] then
			filtered.config = filtered["cmake-config"]
		end
		filtered.install = "cmake --build build --target install"
		local _, primary_target = parsers.detect_cmake_project_commands(filepath)
		if primary_target and primary_target ~= "" then
			filtered["cmake-run"] = systems.cmake_run_command(root, primary_target)
			filtered.run = filtered["cmake-run"]
		elseif configured["cmake-run"] then
			filtered["cmake-run"] = systems.has_cmake_build_tree(root)
				and configured["cmake-run"]
				or (systems.cmake_config_command(root) .. " && " .. configured["cmake-run"])
			filtered.run = filtered["cmake-run"]
		end
		return filtered
	end

	if system == "meson" then
		filtered["meson-setup"] = configured["meson-setup"] or systems.meson_setup_command(root)
		filtered["meson-build"] = systems.meson_build_command(root, nil)
		filtered["meson-clean"] = systems.meson_clean_command(root)
		filtered["meson-test"] = configured["meson-test"] or "meson test -C build"
		if filtered["meson-build"] then
			filtered.build = filtered["meson-build"]
		end
		if filtered["meson-clean"] then
			filtered.clean = filtered["meson-clean"]
		end
		if filtered["meson-test"] then
			filtered.test = filtered["meson-test"]
		end
		if filtered["meson-setup"] then
			filtered.setup = filtered["meson-setup"]
		end
		local _, primary_target = parsers.detect_meson_project_commands(filepath)
		if primary_target and primary_target ~= "" then
			filtered["meson-run"] = systems.meson_run_command(root, primary_target)
			filtered.run = filtered["meson-run"]
		elseif configured["meson-run"] then
			filtered["meson-run"] = systems.has_meson_build_tree(root)
				and configured["meson-run"]
				or (systems.meson_setup_command(root) .. " && " .. configured["meson-run"])
			filtered.run = filtered["meson-run"]
		end
		filtered.install = "meson install -C build"
		return filtered
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
	local build_cmds = M.merge_build_commands(
		filetype,
		filepath,
		M.detect_tool_commands_for_filetype(filetype, filepath, function(flag)
			local detect_options = config.options.detect or {}
			local value = detect_options[flag]
			if value == nil then
				return true
			end
			return value == true
		end)
	)
	local root = utils.get_project_root(filepath, config.options.project)
	if not root then
		root = vim.fn.fnamemodify(filepath, ":h")
	end

	local preferred_name = build_cmds.run and "run"
		or M.select_live_command_name(build_cmds)
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

---@param build_cmds table<string, string>
---@return string|nil
function M.select_live_command_name(build_cmds)
	for _, candidate in ipairs({ "live", "dev", "watch", "serve", "start", "preview" }) do
		if build_cmds[candidate] then
			return candidate
		end
	end
	return nil
end


return M
