local common = require("zignite.build.parsers.common")
local detect_backend = require("zignite.build.detect.backend")
local state = require("zignite.build.state")
local systems = require("zignite.build.systems")

---@type table
local M = {}

---@param root string
---@param filepath string
---@return string, string
local function make_match_context(root, filepath)
	return common.normalize_path_text(common.make_relative_to_root(root, filepath)), vim.fn.fnamemodify(filepath, ":t")
end

---@param normalized_source string
---@param relative_filepath string
---@param basename string
---@return boolean
local function source_matches_file(normalized_source, relative_filepath, basename)
	return normalized_source ~= "" and (
		normalized_source == relative_filepath
		or normalized_source == basename
		or normalized_source:match("/" .. common.escape_lua_pattern(basename) .. "$")
	)
end

---@param root string
---@param commands table<string, string>
---@param target string
---@return nil
local function add_target_commands(root, commands, target)
	commands["meson-build-" .. target] = systems.meson_build_command(root, target)
	commands["meson-run-" .. target] = systems.meson_run_command(root, target)
end

---@param commands table<string, string>
---@return string|nil
local function first_target_name(commands)
	for key, _ in pairs(commands) do
		local target = key:match("^meson%-build%-(.+)$")
		if target then
			return target
		end
	end
	return nil
end

---@param cache_key string
---@param mtime_key string
---@param commands table<string, string>
---@param primary_target string|nil
---@return table<string, string>, string|nil
local function store_cached_result(cache_key, mtime_key, commands, primary_target)
	state.set_bounded_cache_entry(
		state.meson_target_cache,
		state.meson_target_cache_order,
		state.MESON_TARGET_CACHE_MAX,
		cache_key,
		{
			mtime_key = mtime_key,
			commands = state.copy_string_map(commands),
			primary_target = primary_target,
		}
	)
	return commands, primary_target
end

---@param root string
---@param zig_lines string[]
---@return table<string, string>, string|nil
local function parse_zig_targets(root, zig_lines)
	---@type table<string, string>
	local commands = {}
	local primary_target = nil
	for _, raw_line in ipairs(zig_lines) do
		local line = tostring(raw_line or "")
		local kind, target, matched_flag = line:match("^([^\t]+)\t([^\t]+)\t([01])$")
		if kind == "TARGET" and target and target ~= "" then
			add_target_commands(root, commands, target)
			if matched_flag == "1" and not primary_target then
				primary_target = target
			end
		end
	end
	return commands, primary_target or first_target_name(commands)
end

---@param lines string[]
---@param root string
---@param filepath string
---@return table<string, string>, string|nil
local function parse_basic_lua_targets(lines, root, filepath)
	local relative_filepath, basename = make_match_context(root, filepath)
	---@type table<string, string>
	local commands = {}
	local primary_target = nil
	local capture = nil
	local depth = 0

	---@param block string
	---@return nil
	local function commit_block(block)
		local args = block:match("[Ee][Xx][Ee][Cc][Uu][Tt][Aa][Bb][Ll][Ee]%s*%((.*)%)")
		if not args then
			return
		end

		local tokens = common.tokenize_quoted_args(args)
		local target = tostring(tokens[1] or "")
		if target == "" then
			return
		end

		local matched = false
		for token_index = 2, #tokens do
			local normalized_source = common.normalize_path_text(tokens[token_index])
			if source_matches_file(normalized_source, relative_filepath, basename) then
				matched = true
				break
			end
		end

		add_target_commands(root, commands, target)
		if matched and not primary_target then
			primary_target = target
		end
	end

	for _, raw_line in ipairs(lines) do
		local line = common.strip_hash_comment(raw_line)
		if capture == nil then
			local start_col = line:find("[Ee][Xx][Ee][Cc][Uu][Tt][Aa][Bb][Ll][Ee]%s*%(")
			if start_col then
				capture = { line:sub(start_col) }
				local opens = select(2, capture[1]:gsub("%(", ""))
				local closes = select(2, capture[1]:gsub("%)", ""))
				depth = opens - closes
				if depth <= 0 then
					commit_block(table.concat(capture, " "))
					capture = nil
				end
			end
		else
			capture[#capture + 1] = line
			local opens = select(2, line:gsub("%(", ""))
			local closes = select(2, line:gsub("%)", ""))
			depth = depth + opens - closes
			if depth <= 0 then
				commit_block(table.concat(capture, " "))
				capture = nil
			end
		end
	end

	return commands, primary_target or first_target_name(commands)
end

---@param filepath string
---@return table<string, string>, string|nil
function M.detect_meson_project_commands(filepath)
	if not filepath or filepath == "" then
		return {}, nil
	end
	if type(vim.fn.filereadable) ~= "function" or type(vim.fn.readfile) ~= "function" then
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
		return state.copy_string_map(cached.commands), cached.primary_target
	end

	local zig_lines = detect_backend.parse_project_lines_once("meson", meson_build_path, {
		"--match-path=" .. filepath,
	})
	if type(zig_lines) == "table" and #zig_lines > 0 then
		local commands, primary_target = parse_zig_targets(root, zig_lines)
		return store_cached_result(cache_key, mtime_key, commands, primary_target)
	end

	local lines = vim.fn.readfile(meson_build_path)
	if type(lines) ~= "table" then
		return store_cached_result(cache_key, mtime_key, {}, nil)
	end

	local commands, primary_target = parse_basic_lua_targets(lines, root, filepath)
	return store_cached_result(cache_key, mtime_key, commands, primary_target)
end

return M
