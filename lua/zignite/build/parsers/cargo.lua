local config = require("zignite.config")
local common = require("zignite.build.parsers.common")
local detect_backend = require("zignite.build.detect.backend")
local state = require("zignite.build.state")
local utils = require("zignite.utils")

---@type table
local M = {}

---@param commands table<string, string>
---@param bin_name string
---@return nil
local function add_bin_commands(commands, bin_name)
	commands["cargo-build-" .. bin_name] = "cargo build --bin " .. bin_name
	commands["cargo-run-" .. bin_name] = "cargo run --bin " .. bin_name
	commands["cargo-test-" .. bin_name] = "cargo test --bin " .. bin_name
end

---@param cache_key string
---@param mtime_key string
---@param match_path string
---@param commands table<string, string>
---@param primary_bin string|nil
---@return table<string, string>, string|nil
local function store_cached_result(cache_key, mtime_key, match_path, commands, primary_bin)
	state.set_bounded_cache_entry(
		state.cargo_target_cache,
		state.cargo_target_cache_order,
		state.CARGO_TARGET_CACHE_MAX,
		cache_key,
		{
			mtime_key = mtime_key,
			match_path = match_path,
			commands = state.copy_string_map(commands),
			primary_bin = primary_bin,
		}
	)
	return commands, primary_bin
end

---@param zig_lines string[]
---@return table<string, string>, string|nil
local function parse_zig_targets(zig_lines)
	---@type table<string, string>
	local commands = {}
	local primary_bin = nil
	for _, raw_line in ipairs(zig_lines) do
		local line = tostring(raw_line or "")
		local kind, bin_name, matched_flag = line:match("^([^\t]+)\t([^\t]+)\t([01])$")
		if kind == "BIN" and bin_name and bin_name ~= "" then
			add_bin_commands(commands, bin_name)
			if matched_flag == "1" and not primary_bin then
				primary_bin = bin_name
			end
		end
	end
	return commands, primary_bin
end

---@param filepath string
---@param root string
---@return table<string, string>, string|nil
local function fallback_cargo_commands(filepath, root)
	local relative_filepath = common.normalize_path_text(common.make_relative_to_root(root, filepath))
	local primary_bin = relative_filepath:match("^src/bin/([^/]+)%.rs$")
	if not primary_bin or primary_bin == "" then
		return {}, nil
	end

	---@type table<string, string>
	local commands = {}
	add_bin_commands(commands, primary_bin)
	return commands, primary_bin
end

---@param filepath string
---@return table<string, string>, string|nil
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
		return state.copy_string_map(cached.commands), cached.primary_bin
	end

	local zig_lines = detect_backend.parse_project_lines_once("cargo", cargo_toml_path, {
		"--match-path=" .. filepath,
	})
	if type(zig_lines) == "table" and #zig_lines > 0 then
		local commands, primary_bin = parse_zig_targets(zig_lines)
		return store_cached_result(cargo_toml_path, mtime_key, filepath, commands, primary_bin)
	end

	local commands, primary_bin = fallback_cargo_commands(filepath, root)
	return store_cached_result(cargo_toml_path, mtime_key, filepath, commands, primary_bin)
end

return M
