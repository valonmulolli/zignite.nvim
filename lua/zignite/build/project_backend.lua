local config = require("zignite.config")
local common = require("zignite.build.common")
local detect_backend = require("zignite.build.detect.backend")
local state = require("zignite.build.state")
local systems = require("zignite.build.systems")
local utils = require("zignite.utils")

---@type table
local M = {}

---@param filepath string
---@return table<string, string>
function M.detect_makefile_targets(filepath)
	if not filepath or filepath == "" then
		return {}
	end
	local cache_key = common.normalize_path_text(filepath)
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
		local commands = common.decode_backend_commands(zig_lines)
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
	local cache_key = common.normalize_path_text(filepath)
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
		local commands = common.decode_backend_commands(zig_lines)
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
		local commands = common.decode_backend_commands(zig_lines)
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

	local zig_lines = detect_backend.parse_project_lines_once("jvm-auto", filepath)
	if type(zig_lines) == "table" and #zig_lines > 0 then
		return common.decode_backend_commands(zig_lines)
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
		return common.decode_backend_commands(zig_lines)
	end
	return {}
end

return M
