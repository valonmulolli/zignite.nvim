local common = require("zignite.build.common")
local detect_backend = require("zignite.build.detect.backend")
local state = require("zignite.build.state")
local systems = require("zignite.build.systems")

---@type table
local M = {}

---@param commands table<string, string>|nil
---@return table<string, string>|nil
local function copy_preferred_commands(commands)
	if type(commands) ~= "table" then
		return nil
	end
	local copied = state.copy_string_map(commands)
	return next(copied) ~= nil and copied or nil
end

---@param info table|nil
---@return table|nil
local function copy_info(info)
	if type(info) ~= "table" then
		return nil
	end
	return {
		primary_target = info.primary_target,
		primary_run_path = info.primary_run_path,
		primary_run = info.primary_run,
		preferred_commands = copy_preferred_commands(info.preferred_commands),
	}
end

---@param cache_key string
---@param mtime_key string
---@param commands table<string, string>
---@param info table|nil
---@return table<string, string>, table|nil
local function store_cached_result(cache_key, mtime_key, commands, info)
	state.set_bounded_cache_entry(
		state.meson_target_cache,
		state.meson_target_cache_order,
		state.MESON_TARGET_CACHE_MAX,
		cache_key,
		{
			mtime_key = mtime_key,
			commands = state.copy_string_map(commands),
			info = copy_info(info),
		}
	)
	return commands, copy_info(info)
end

---@param zig_lines string[]
---@return table<string, string>, table|nil
local function parse_zig_targets(zig_lines)
	---@type table<string, string>
	local commands = {}
	---@type table<string, string>
	local preferred = {}
	local primary_target = nil
	local primary_run_path = nil
	local primary_run = nil

	for _, raw_line in ipairs(zig_lines or {}) do
		local line = tostring(raw_line or "")
		local kind, value, extra = line:match("^([^\t]+)\t([^\t]*)\t?(.*)$")
		if kind == "COMMAND" and value ~= "" and extra ~= "" then
			commands[value] = extra
		elseif kind == "PRIMARY_TARGET" and value ~= "" then
			primary_target = value
		elseif kind == "PRIMARY_RUN_PATH" and value ~= "" then
			primary_run_path = value
		elseif kind == "PREFERRED" and value ~= "" and extra ~= "" then
			preferred[value] = extra
			if value == "run" then
				primary_run = extra
			end
		end
	end

	local info = nil
	if primary_target or primary_run_path or primary_run or next(preferred) ~= nil then
		info = {
			primary_target = primary_target,
			primary_run_path = primary_run_path,
			primary_run = primary_run,
			preferred_commands = next(preferred) ~= nil and preferred or nil,
		}
	end

	return commands, copy_info(info)
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
	local cache_key = meson_build_path .. "::" .. common.normalize_path_text(filepath)
	local cached = state.get_bounded_cache_entry(
		state.meson_target_cache,
		state.meson_target_cache_order,
		cache_key
	)
	if cached and cached.mtime_key == mtime_key then
		return state.copy_string_map(cached.commands), copy_info(cached.info)
	end

	local zig_lines = detect_backend.parse_project_lines_once("meson", meson_build_path, {
		"--match-path=" .. filepath,
	})
	if type(zig_lines) == "table" and #zig_lines > 0 then
		local commands, info = parse_zig_targets(zig_lines)
		return store_cached_result(cache_key, mtime_key, commands, info)
	end

	return store_cached_result(cache_key, mtime_key, {}, nil)
end

return M
