local config = require("zignite.config")
local detect_backend = require("zignite.build.detect.backend")
local state = require("zignite.build.state")
local systems = require("zignite.build.systems")
local utils = require("zignite.utils")

---@type table
local M = {}
local PARSER_BACKED_BUILD_SOURCES

---@param text string
---@return string
local function normalize_path_text(text)
	if type(text) ~= "string" then
		return ""
	end
	return vim.fs.normalize(text):gsub("\\", "/")
end

---@param lines string[]|nil
---@return table<string, string>
local function decode_backend_commands(lines)
	---@type table<string, string>
	local commands = {}
	for _, raw_line in ipairs(lines or {}) do
		local kind, name, command = tostring(raw_line or ""):match("^([^\t]+)\t([^\t]+)\t(.+)$")
		if kind == "COMMAND" and type(name) == "string" and name ~= "" and type(command) == "string" and command ~= "" then
			commands[name] = command
		end
	end
	return commands
end

---@param lines string[]|nil
---@return table
local function decode_backend_project_result(lines)
	local result = {
		commands = decode_backend_commands(lines),
	}
	for _, raw_line in ipairs(lines or {}) do
		local kind, value = tostring(raw_line or ""):match("^([^\t]+)\t(.+)$")
		if kind == "SYSTEM" and type(value) == "string" and value ~= "" then
			result.system = value
		elseif kind == "ROOT" and type(value) == "string" and value ~= "" then
			result.root = value
		elseif kind == "BUILD_READY" then
			result.build_ready = value == "1"
		end
	end
	return result
end

---@param filepath string
---@return table<string, string>
function M.detect_makefile_targets(filepath)
	if not filepath or filepath == "" then
		return {}
	end
	local cache_key = normalize_path_text(filepath)
	local cached = state.get_bounded_cache_entry(
		state.make_target_cache,
		state.make_target_cache_order,
		cache_key
	)
	if cached then
		return state.copy_string_map(cached.commands)
	end

	local zig_lines = detect_backend.parse_project_lines_once("make-auto", filepath)
	if type(zig_lines) == "table" and #zig_lines > 0 then
		local commands = decode_backend_commands(zig_lines)
		state.set_bounded_cache_entry(
			state.make_target_cache,
			state.make_target_cache_order,
			state.MAKE_TARGET_CACHE_MAX,
			cache_key,
			{
			mtime_key = "auto",
			commands = state.copy_string_map(commands),
			}
		)
		return commands
	end

	state.set_bounded_cache_entry(
		state.make_target_cache,
		state.make_target_cache_order,
		state.MAKE_TARGET_CACHE_MAX,
		cache_key,
		{
		mtime_key = "auto",
		commands = {},
		}
	)
	return {}
end

---@param filepath string
---@return table<string, string>
function M.detect_package_scripts(filepath)
	if not filepath or filepath == "" then
		return {}
	end

	local package_manager = utils.detect_node_package_manager(filepath, config.options.project)
	local cache_key = normalize_path_text(filepath)
	local cached = state.get_bounded_cache_entry(
		state.package_script_cache,
		state.package_script_cache_order,
		cache_key
	)
	if cached and cached.package_manager == package_manager then
		return state.copy_string_map(cached.commands)
	end

	local zig_lines = detect_backend.parse_project_lines_once("package-json-auto", filepath, {
		"--package-manager=" .. package_manager,
	})
	if type(zig_lines) == "table" and #zig_lines > 0 then
		local commands = decode_backend_commands(zig_lines)
		state.set_bounded_cache_entry(
			state.package_script_cache,
			state.package_script_cache_order,
			state.PACKAGE_SCRIPT_CACHE_MAX,
			cache_key,
			{
				mtime_key = "auto",
				package_manager = package_manager,
				commands = state.copy_string_map(commands),
			}
		)
		return commands
	end

	state.set_bounded_cache_entry(
		state.package_script_cache,
		state.package_script_cache_order,
		state.PACKAGE_SCRIPT_CACHE_MAX,
		cache_key,
		{
			mtime_key = "auto",
			package_manager = package_manager,
			commands = {},
		}
	)
	return {}
end

---@param filepath string
---@return table<string, string>, table|nil
function M.detect_cargo_project_commands(filepath)
	if not filepath or filepath == "" or type(vim.fn.filereadable) ~= "function" then
		return {}, nil
	end

	local root = utils.get_project_root(filepath, config.options.project)
	if type(root) ~= "string" or root == "" then
		return {}, nil
	end
	local cargo_toml_path = (type(root) == "string" and root ~= "") and vim.fs.joinpath(root, "Cargo.toml") or nil

	if cargo_toml_path and vim.fn.filereadable(cargo_toml_path) == 1 then
		local mtime_key = state.get_file_mtime_key(cargo_toml_path) or "missing"
		local cached = state.get_bounded_cache_entry(
			state.cargo_target_cache,
			state.cargo_target_cache_order,
			cargo_toml_path
		)
		if cached and cached.mtime_key == mtime_key and cached.match_path == filepath then
			return state.copy_string_map(cached.commands), nil
		end
	end

	local zig_lines = detect_backend.parse_project_lines_once("cargo-auto", filepath)
	if type(zig_lines) == "table" and #zig_lines > 0 then
		local commands = decode_backend_commands(zig_lines)
		if cargo_toml_path and vim.fn.filereadable(cargo_toml_path) == 1 then
			state.set_bounded_cache_entry(
				state.cargo_target_cache,
				state.cargo_target_cache_order,
				state.CARGO_TARGET_CACHE_MAX,
				cargo_toml_path,
				{
					mtime_key = state.get_file_mtime_key(cargo_toml_path) or "missing",
					match_path = filepath,
					commands = state.copy_string_map(commands),
					info = nil,
				}
			)
		end
		return commands, nil
	end

	if cargo_toml_path and vim.fn.filereadable(cargo_toml_path) == 1 then
		state.set_bounded_cache_entry(
			state.cargo_target_cache,
			state.cargo_target_cache_order,
			state.CARGO_TARGET_CACHE_MAX,
			cargo_toml_path,
			{
				mtime_key = state.get_file_mtime_key(cargo_toml_path) or "missing",
				match_path = filepath,
				commands = {},
				info = nil,
			}
		)
	end
	return {}, nil
end

---@param raw_path string
---@return string
local function normalize_path(raw_path)
	return vim.fs.normalize(tostring(raw_path or "")):gsub("\\", "/")
end

---@param filepath string
---@return table<string, string>, table|nil
function M.detect_go_project_commands(filepath)
	if not filepath or filepath == "" or type(vim.fn.filereadable) ~= "function" then
		return {}, nil
	end

	local root = utils.get_project_root(filepath, config.options.project)
	if type(root) ~= "string" or root == "" then
		return {}, nil
	end
	local normalized_filepath = normalize_path(filepath)
	local cache_key = normalize_path(root) .. "::" .. normalized_filepath
	root = normalize_path(root)
	local go_work_path = vim.fs.joinpath(root, "go.work")
	local go_mod_path = vim.fs.joinpath(root, "go.mod")
	local mtime_key = string.format(
		"%s|%s",
		state.get_file_mtime_key(go_work_path) or "missing",
		state.get_file_mtime_key(go_mod_path) or "missing"
	)
	local cached = state.get_bounded_cache_entry(
		state.go_project_cache,
		state.go_project_cache_order,
		cache_key
	)
	if cached and cached.mtime_key == mtime_key then
		return state.copy_string_map(cached.commands), nil
	end

	local zig_lines = detect_backend.parse_project_lines_once("go-auto", filepath)
	if type(zig_lines) == "table" and #zig_lines > 0 then
		local commands = decode_backend_commands(zig_lines)
		state.set_bounded_cache_entry(
			state.go_project_cache,
			state.go_project_cache_order,
			state.GO_PROJECT_CACHE_MAX,
			cache_key,
			{
				mtime_key = mtime_key,
				commands = state.copy_string_map(commands),
				info = nil,
			}
		)
		return state.copy_string_map(commands), nil
	end

	state.set_bounded_cache_entry(
		state.go_project_cache,
		state.go_project_cache_order,
		state.GO_PROJECT_CACHE_MAX,
		cache_key,
		{
			mtime_key = mtime_key,
			commands = {},
			info = nil,
		}
	)

	return {}, nil
end

---@param lines string[]|nil
---@return table<string, string>
---@param filepath string
---@return table<string, string>
function M.detect_java_like_project_commands(filepath)
	if not filepath or filepath == "" or type(vim.fn.filereadable) ~= "function" then
		return {}
	end

	local zig_lines = detect_backend.parse_project_lines_once("jvm-auto", filepath)
	if type(zig_lines) == "table" and #zig_lines > 0 then
		return decode_backend_commands(zig_lines)
	end
	return {}
end

---@param filepath string
---@return table<string, string>
function M.detect_bazel_project_commands(filepath)
	if not filepath or filepath == "" or type(vim.fn.filereadable) ~= "function" then
		return {}
	end

	if not systems.resolve_bazel_root(filepath) then
		return {}
	end

	local zig_lines = detect_backend.parse_project_lines_once("bazel-auto", filepath)
	if type(zig_lines) == "table" and #zig_lines > 0 then
		return decode_backend_commands(zig_lines)
	end
	return {}
end

---@param cache table<string, table>
---@param order string[]
---@param max_entries integer
---@param cache_key string
---@param mtime_key string
---@param commands table<string, string>
---@return table<string, string>, nil
local function store_system_cached_result(cache, order, max_entries, cache_key, mtime_key, commands)
	state.set_bounded_cache_entry(
		cache,
		order,
		max_entries,
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
	local cache_key = cmake_lists_path .. "::" .. normalize_path_text(filepath)
	local cached = state.get_bounded_cache_entry(
		state.cmake_target_cache,
		state.cmake_target_cache_order,
		cache_key
	)
	if cached and cached.mtime_key == mtime_key then
		return state.copy_string_map(cached.commands), nil
	end

	local zig_lines = detect_backend.parse_project_lines_once("cmake-auto", filepath)
	if type(zig_lines) == "table" and #zig_lines > 0 then
		return store_system_cached_result(
			state.cmake_target_cache,
			state.cmake_target_cache_order,
			state.CMAKE_TARGET_CACHE_MAX,
			cache_key,
			mtime_key,
			decode_backend_commands(zig_lines)
		)
	end

	return store_system_cached_result(
		state.cmake_target_cache,
		state.cmake_target_cache_order,
		state.CMAKE_TARGET_CACHE_MAX,
		cache_key,
		mtime_key,
		{}
	)
end

---@param filepath string
---@return table<string, string>, table|nil
function M.detect_meson_project_commands(filepath)
	if not filepath or filepath == "" then
		return {}, nil
	end
	if type(vim.fn.filereadable) ~= "function" then
		return {}, nil
	end

	local system, root = systems.detect_c_family_build_system(filepath)
	if system ~= "meson" or not root then
		return {}, nil
	end

	local meson_build_path = vim.fs.joinpath(root, "meson.build")
	if vim.fn.filereadable(meson_build_path) ~= 1 then
		return {}, nil
	end

	local meson_build_ready = systems.has_meson_build_tree(root) and "1" or "0"
	local mtime_key = string.format(
		"%s|build:%s",
		state.get_file_mtime_key(meson_build_path) or "missing",
		meson_build_ready
	)
	local cache_key = meson_build_path .. "::" .. normalize_path_text(filepath)
	local cached = state.get_bounded_cache_entry(
		state.meson_target_cache,
		state.meson_target_cache_order,
		cache_key
	)
	if cached and cached.mtime_key == mtime_key then
		return state.copy_string_map(cached.commands), nil
	end

	local zig_lines = detect_backend.parse_project_lines_once("meson-auto", filepath)
	if type(zig_lines) == "table" and #zig_lines > 0 then
		return store_system_cached_result(
			state.meson_target_cache,
			state.meson_target_cache_order,
			state.MESON_TARGET_CACHE_MAX,
			cache_key,
			mtime_key,
			decode_backend_commands(zig_lines)
		)
	end

	return store_system_cached_result(
		state.meson_target_cache,
		state.meson_target_cache_order,
		state.MESON_TARGET_CACHE_MAX,
		cache_key,
		mtime_key,
		{}
	)
end

PARSER_BACKED_BUILD_SOURCES = {
	go = {
		default_key = "go",
		detect = M.detect_go_project_commands,
	},
	rust = {
		default_key = "rust",
		detect = M.detect_cargo_project_commands,
		detect_flag = "rust",
	},
}

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
	if not filepath or filepath == "" then
		return nil
	end
	local local_system, local_root = systems.detect_c_family_build_system(filepath)
	if not local_system then
		return nil
	end
	if local_system == "bazel" then
		return {
			system = local_system,
			root = local_root,
			commands = {},
			info = nil,
		}
	end

	local root = local_root or systems.resolve_project_root_for_detection(filepath)
	local cache_key = normalize_path_text(filepath)
	local mtime_key = table.concat({
		"Makefile:" .. systems.detect_file_signature(vim.fs.joinpath(root, "Makefile")),
		"CMakeLists.txt:" .. systems.detect_file_signature(vim.fs.joinpath(root, "CMakeLists.txt")),
		"meson.build:" .. systems.detect_file_signature(vim.fs.joinpath(root, "meson.build")),
		"build/CMakeCache.txt:" .. systems.detect_file_signature(vim.fs.joinpath(root, "build", "CMakeCache.txt")),
		"build/build.ninja:" .. systems.detect_file_signature(vim.fs.joinpath(root, "build", "build.ninja")),
		"build/meson-private/coredata.dat:"
			.. systems.detect_file_signature(vim.fs.joinpath(root, "build", "meson-private", "coredata.dat")),
	}, "|")
	local cached = state.get_bounded_cache_entry(
		state.c_family_project_cache,
		state.c_family_project_cache_order,
		cache_key
	)
	if cached and cached.mtime_key == mtime_key then
		if type(cached.system) ~= "string" or cached.system == "" then
			return nil
		end
		return {
			system = cached.system,
			root = cached.root,
			detect_flag = cached.detect_flag,
			commands = state.copy_string_map(cached.commands),
			info = nil,
		}
	end

	local zig_lines = detect_backend.parse_project_lines_once("c-family-auto", filepath, {
		"--project-root=" .. root,
	})
	local decoded = decode_backend_project_result(zig_lines)
	local system = decoded.system
	if type(system) ~= "string" or system == "" then
		system = local_system
		decoded.system = local_system
		decoded.root = local_root or decoded.root or root
	end
	local detect_flag = system == "make" and "c_cpp_make" or nil
	state.set_bounded_cache_entry(
		state.c_family_project_cache,
		state.c_family_project_cache_order,
		state.C_FAMILY_PROJECT_CACHE_MAX,
		cache_key,
		{
			mtime_key = mtime_key,
			system = system,
			root = decoded.root or root,
			detect_flag = detect_flag,
			commands = state.copy_string_map(decoded.commands),
		}
	)
	if type(system) ~= "string" or system == "" then
		return nil
	end
	return {
		system = system,
		root = decoded.root or root,
		detect_flag = detect_flag,
		commands = decoded.commands or {},
		info = nil,
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
		for key, value in pairs(M.detect_package_scripts(filepath)) do
			if type(key) == "string" and type(value) == "string" then
				commands[key] = value
			end
		end
	end
	if (filetype == "java" or filetype == "kotlin") and is_detection_enabled("java_kotlin_project") then
		for key, value in pairs(M.detect_java_like_project_commands(filepath)) do
			if type(key) == "string" and type(value) == "string" then
				commands[key] = value
			end
		end
	end
	if is_detection_enabled("bazel_project") and systems.supports_bazel_project_commands(filetype) then
		for key, value in pairs(M.detect_bazel_project_commands(filepath)) do
			if type(key) == "string" and type(value) == "string" then
				commands[key] = value
			end
		end
	end

	return commands
end

return M
