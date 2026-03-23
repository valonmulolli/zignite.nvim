local cmake = require("zignite.build.cmake")
local meson = require("zignite.build.meson")
local project_backend = require("zignite.build.project_backend")
local systems = require("zignite.build.systems")

---@type table
local M = {}
local PARSER_BACKED_BUILD_SOURCES = {
	go = {
		default_key = "go",
		detect = project_backend.detect_go_project_commands,
	},
	rust = {
		default_key = "rust",
		detect = project_backend.detect_cargo_project_commands,
		detect_flag = "rust",
	},
}
local C_FAMILY_BUILD_SOURCES = {
	make = {
		detect = project_backend.detect_makefile_targets,
		detect_flag = "c_cpp_make",
	},
	cmake = {
		detect = cmake.detect_cmake_project_commands,
	},
	meson = {
		detect = meson.detect_meson_project_commands,
	},
}

M.detect_cmake_project_commands = cmake.detect_cmake_project_commands
M.detect_meson_project_commands = meson.detect_meson_project_commands
M.detect_makefile_targets = project_backend.detect_makefile_targets
M.detect_package_scripts = project_backend.detect_package_scripts
M.detect_java_like_project_commands = project_backend.detect_java_like_project_commands
M.detect_bazel_project_commands = project_backend.detect_bazel_project_commands
M.detect_cargo_project_commands = project_backend.detect_cargo_project_commands
M.detect_go_project_commands = project_backend.detect_go_project_commands

---@param filetype string
---@param filepath string
---@return table|nil
function M.detect_parser_backed_build_result(filetype, filepath)
	local source = PARSER_BACKED_BUILD_SOURCES[filetype]
	if not source then
		return nil
	end

	local commands, info = source.detect(filepath)
	return {
		filetype = filetype,
		default_key = source.default_key or filetype,
		detect_flag = source.detect_flag,
		commands = commands or {},
		info = info,
	}
end

---@param filepath string
---@return table|nil
function M.detect_c_family_build_result(filepath)
	local system, root = systems.detect_c_family_build_system(filepath)
	if not system then
		return nil
	end

	local source = C_FAMILY_BUILD_SOURCES[system]
	if not source then
		return {
			system = system,
			root = root,
			commands = {},
			info = nil,
		}
	end

	local commands, info = source.detect(filepath)
	return {
		system = system,
		root = root,
		detect_flag = source.detect_flag,
		commands = commands or {},
		info = info,
	}
end

---@param filetype string
---@param filepath string
---@param is_detection_enabled fun(flag: string): boolean
---@return table<string, string>
function M.collect_sync_project_commands(filetype, filepath, is_detection_enabled)
	---@type table<string, string>
	local commands = {}

	if filetype == "c" or filetype == "cpp" then
		local result = M.detect_c_family_build_result(filepath)
		if result and (not result.detect_flag or is_detection_enabled(result.detect_flag)) then
			for key, value in pairs(result.commands or {}) do
				if type(key) == "string" and type(value) == "string" then
					commands[key] = value
				end
			end
		end
	end
	if (filetype == "javascript" or filetype == "typescript") and is_detection_enabled("js_package_scripts") then
		for key, value in pairs(project_backend.detect_package_scripts(filepath)) do
			if type(key) == "string" and type(value) == "string" then
				commands[key] = value
			end
		end
	end
	if (filetype == "java" or filetype == "kotlin") and is_detection_enabled("java_kotlin_project") then
		for key, value in pairs(project_backend.detect_java_like_project_commands(filepath)) do
			if type(key) == "string" and type(value) == "string" then
				commands[key] = value
			end
		end
	end
	if is_detection_enabled("bazel_project") and systems.supports_bazel_project_commands(filetype) then
		for key, value in pairs(project_backend.detect_bazel_project_commands(filepath)) do
			if type(key) == "string" and type(value) == "string" then
				commands[key] = value
			end
		end
	end

	return commands
end

return M
