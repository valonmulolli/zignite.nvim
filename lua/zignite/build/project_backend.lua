local config = require("zignite.config")
local common = require("zignite.build.common")
local detect_backend = require("zignite.build.detect.backend")
local state = require("zignite.build.state")
local systems = require("zignite.build.systems")
local utils = require("zignite.utils")

---@type table
local M = {}

---@param filepath string
---@return string
local function resolve_project_root(filepath)
	local root = utils.get_project_root(filepath, config.options.project)
	if root and root ~= "" then
		return root
	end
	return vim.fn.fnamemodify(filepath, ":h")
end

---@param project_file string
---@param cache table<string, table>
---@param order string[]
---@return table|nil
local function get_cached_entry(project_file, cache, order)
	local mtime_key = state.get_file_mtime_key(project_file)
	local cached = state.get_bounded_cache_entry(cache, order, project_file)
	if cached and cached.mtime_key == mtime_key then
		return cached
	end
	return nil
end

---@param project_file string
---@param cache table<string, table>
---@param order string[]
---@param max_entries integer
---@param entry table
---@return nil
local function set_cached_entry(project_file, cache, order, max_entries, entry)
	state.set_bounded_cache_entry(cache, order, max_entries, project_file, entry)
end

---@param filepath string
---@return table<string, string>
function M.detect_makefile_targets(filepath)
	if not filepath or filepath == "" then
		return {}
	end
	if type(vim.fn.filereadable) ~= "function" then
		return {}
	end

	local root = resolve_project_root(filepath)
	local makefile_path = vim.fs.joinpath(root, "Makefile")
	if vim.fn.filereadable(makefile_path) ~= 1 then
		return {}
	end

	local cached = get_cached_entry(makefile_path, state.make_target_cache, state.make_target_cache_order)
	if cached then
		return state.copy_string_map(cached.commands)
	end

	local zig_lines = detect_backend.parse_project_lines_once("make", makefile_path)
	if type(zig_lines) == "table" and #zig_lines > 0 then
		local commands = common.decode_backend_commands(zig_lines)
		set_cached_entry(makefile_path, state.make_target_cache, state.make_target_cache_order, state.MAKE_TARGET_CACHE_MAX, {
			mtime_key = state.get_file_mtime_key(makefile_path),
			commands = state.copy_string_map(commands),
		})
		return commands
	end

	set_cached_entry(makefile_path, state.make_target_cache, state.make_target_cache_order, state.MAKE_TARGET_CACHE_MAX, {
		mtime_key = state.get_file_mtime_key(makefile_path),
		commands = {},
	})
	return {}
end

---@param filepath string
---@return table<string, string>
function M.detect_package_scripts(filepath)
	if not filepath or filepath == "" then
		return {}
	end
	if type(vim.fn.filereadable) ~= "function" then
		return {}
	end

	local root = resolve_project_root(filepath)
	local package_json_path = vim.fs.joinpath(root, "package.json")
	if vim.fn.filereadable(package_json_path) ~= 1 then
		return {}
	end

	local package_manager = utils.detect_node_package_manager_root(root)
	local cached = get_cached_entry(package_json_path, state.package_script_cache, state.package_script_cache_order)
	if cached and cached.package_manager == package_manager then
		return state.copy_string_map(cached.commands)
	end

	local zig_lines = detect_backend.parse_project_lines_once("package-json", package_json_path, {
		"--package-manager=" .. package_manager,
	})
	if type(zig_lines) == "table" and #zig_lines > 0 then
		local commands = common.decode_backend_commands(zig_lines)
		set_cached_entry(
			package_json_path,
			state.package_script_cache,
			state.package_script_cache_order,
			state.PACKAGE_SCRIPT_CACHE_MAX,
			{
				mtime_key = state.get_file_mtime_key(package_json_path),
				package_manager = package_manager,
				commands = state.copy_string_map(commands),
			}
		)
		return commands
	end

	set_cached_entry(
		package_json_path,
		state.package_script_cache,
		state.package_script_cache_order,
		state.PACKAGE_SCRIPT_CACHE_MAX,
		{
			mtime_key = state.get_file_mtime_key(package_json_path),
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
	if not root or root == "" then
		return {}, nil
	end

	local cargo_toml_path = vim.fs.joinpath(root, "Cargo.toml")
	if vim.fn.filereadable(cargo_toml_path) ~= 1 then
		return {}, nil
	end

	local mtime_key = state.get_file_mtime_key(cargo_toml_path) or "missing"
	local cached = state.get_bounded_cache_entry(
		state.cargo_target_cache,
		state.cargo_target_cache_order,
		cargo_toml_path
	)
	if cached and cached.mtime_key == mtime_key and cached.match_path == filepath then
		return state.copy_string_map(cached.commands), nil
	end

	local zig_lines = detect_backend.parse_project_lines_once("cargo", cargo_toml_path, {
		"--match-path=" .. filepath,
	})
	if type(zig_lines) == "table" and #zig_lines > 0 then
		local commands = common.decode_backend_commands(zig_lines)
		state.set_bounded_cache_entry(
			state.cargo_target_cache,
			state.cargo_target_cache_order,
			state.CARGO_TARGET_CACHE_MAX,
			cargo_toml_path,
			{
				mtime_key = mtime_key,
				match_path = filepath,
				commands = state.copy_string_map(commands),
				info = nil,
			}
		)
		return commands, nil
	end

	state.set_bounded_cache_entry(
		state.cargo_target_cache,
		state.cargo_target_cache_order,
		state.CARGO_TARGET_CACHE_MAX,
		cargo_toml_path,
		{
			mtime_key = mtime_key,
			match_path = filepath,
			commands = {},
			info = nil,
		}
	)
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
	if not root or root == "" then
		return {}, nil
	end
	root = normalize_path(root)

	local go_work_path = vim.fs.joinpath(root, "go.work")
	local go_mod_path = vim.fs.joinpath(root, "go.mod")
	local cache_key = root .. "::" .. normalize_path(filepath)
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

	local project_path = vim.fn.filereadable(go_work_path) == 1 and go_work_path
		or (vim.fn.filereadable(go_mod_path) == 1 and go_mod_path or nil)
	if not project_path then
		state.set_bounded_cache_entry(
			state.go_project_cache,
			state.go_project_cache_order,
			state.GO_PROJECT_CACHE_MAX,
			cache_key,
			{ mtime_key = mtime_key, commands = {}, info = nil }
		)
		return {}, nil
	end

	local zig_lines = detect_backend.parse_project_lines_once("go", project_path, {
		"--match-path=" .. filepath,
	})
	if type(zig_lines) == "table" and #zig_lines > 0 then
		local commands = common.decode_backend_commands(zig_lines)
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

	local root, backend_system = systems.resolve_jvm_root(filepath)
	root = root or vim.fn.fnamemodify(filepath, ":h")

	---@type table<string, string>
	local commands = {}
	local pom_xml = vim.fs.joinpath(root, "pom.xml")
	local gradle_wrapper = vim.fs.joinpath(root, "gradlew")
	local gradle_build = vim.fs.joinpath(root, "build.gradle")
	local gradle_build_kts = vim.fs.joinpath(root, "build.gradle.kts")

	if backend_system == "maven" or vim.fn.filereadable(pom_xml) == 1 then
		local zig_lines = detect_backend.parse_project_lines_once("maven", pom_xml)
		if type(zig_lines) == "table" and #zig_lines > 0 then
			local decoded = common.decode_backend_commands(zig_lines)
			return decoded
		end
		return commands
	end
	if backend_system == "gradle"
		and vim.fn.filereadable(gradle_wrapper) ~= 1
		and vim.fn.filereadable(gradle_build) ~= 1
		and vim.fn.filereadable(gradle_build_kts) ~= 1
	then
		return commands
	end
	if vim.fn.filereadable(gradle_wrapper) == 1 or backend_system == "gradle" then
		local gradle_file = nil
		if vim.fn.filereadable(gradle_build_kts) == 1 then
			gradle_file = gradle_build_kts
		elseif vim.fn.filereadable(gradle_build) == 1 then
			gradle_file = gradle_build
		end
		if gradle_file then
			local zig_lines = detect_backend.parse_project_lines_once("gradle", gradle_file)
			if type(zig_lines) == "table" and #zig_lines > 0 then
				local decoded = common.decode_backend_commands(zig_lines)
				return decoded
			end
		end
		return commands
	elseif vim.fn.filereadable(gradle_build) == 1 or vim.fn.filereadable(gradle_build_kts) == 1 then
		local gradle_file = vim.fn.filereadable(gradle_build_kts) == 1 and gradle_build_kts or gradle_build
		local zig_lines = detect_backend.parse_project_lines_once("gradle", gradle_file)
		if type(zig_lines) == "table" and #zig_lines > 0 then
			local decoded = common.decode_backend_commands(zig_lines)
			return decoded
		end
		return commands
	end
	return commands
end

---@param filepath string
---@return table<string, string>
function M.detect_bazel_project_commands(filepath)
	if not filepath or filepath == "" or type(vim.fn.filereadable) ~= "function" then
		return {}
	end

	local root = systems.resolve_bazel_root(filepath)
	if not root then
		return {}
	end

	local zig_lines = detect_backend.parse_project_lines_once("bazel-workspace", root, {
		"--match-path=" .. filepath,
	})
	if type(zig_lines) == "table" and #zig_lines > 0 then
		return common.decode_backend_commands(zig_lines)
	end
	return {}
end

return M
