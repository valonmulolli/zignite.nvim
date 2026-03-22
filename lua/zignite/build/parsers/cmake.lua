local common = require("zignite.build.parsers.common")
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
---@param run_path string|nil
---@return nil
local function add_target_commands(root, commands, target, run_path)
	commands["cmake-build-" .. target] = systems.cmake_build_command(root, target)
	commands["cmake-run-" .. target] = systems.cmake_run_command(root, target, run_path)
end

---@param root string
---@param primary_target string|nil
---@param primary_run_path string|nil
---@return table|nil
local function build_target_info(root, primary_target, primary_run_path)
	if type(primary_target) ~= "string" or primary_target == "" then
		return nil
	end
	return {
		primary_target = primary_target,
		primary_run_path = primary_run_path,
		primary_run = systems.cmake_run_command(root, primary_target, primary_run_path),
		preferred_commands = {
			run = systems.cmake_run_command(root, primary_target, primary_run_path),
		},
	}
end

---@param commands table<string, string>
---@return string|nil
local function first_target_name(commands)
	for key, _ in pairs(commands) do
		local target = key:match("^cmake%-build%-(.+)$")
		if target then
			return target
		end
	end
	return nil
end

---@param cache_key string
---@param mtime_key string
---@param commands table<string, string>
---@param info table|nil
---@return table<string, string>, table|nil
local function store_cached_result(cache_key, mtime_key, commands, info)
	state.set_bounded_cache_entry(
		state.cmake_target_cache,
		state.cmake_target_cache_order,
		state.CMAKE_TARGET_CACHE_MAX,
		cache_key,
			{
				mtime_key = mtime_key,
				commands = state.copy_string_map(commands),
				info = copy_info(info),
			}
		)
	return commands, copy_info(info)
end

---@param root string
---@param zig_lines string[]
---@return table<string, string>, table|nil
local function parse_zig_targets(root, zig_lines)
	---@type table<string, string>
	local commands = {}
	local primary_target = nil
	---@type table<string, string>
	local run_paths = {}
	local primary_run_path = nil
	---@type string[]
	local targets = {}
	---@type table<string, boolean>
	local seen_targets = {}
	for _, raw_line in ipairs(zig_lines) do
		local line = tostring(raw_line or "")
		local kind, target, matched_flag = line:match("^([^\t]+)\t([^\t]+)\t([01])$")
		if kind == "TARGET" and target and target ~= "" then
			if not seen_targets[target] then
				seen_targets[target] = true
				targets[#targets + 1] = target
			end
			if matched_flag == "1" and not primary_target then
				primary_target = target
			end
		else
			local value_kind, value, extra = line:match("^([^\t]+)\t([^\t]*)\t?(.*)$")
			if value_kind == "RUN_PATH" and value ~= "" and extra ~= "" then
				run_paths[value] = extra
			elseif value_kind == "PRIMARY_RUN_PATH" and value ~= "" then
				primary_run_path = value
			elseif value_kind == "PRIMARY_TARGET" and value ~= "" then
				primary_target = value
			end
		end
	end
	for _, target in ipairs(targets) do
		add_target_commands(root, commands, target, run_paths[target])
	end
	primary_target = primary_target or first_target_name(commands)
	if not primary_run_path and primary_target then
		primary_run_path = run_paths[primary_target]
	end
	local info = build_target_info(root, primary_target, primary_run_path)
	if info then
		for _, raw_line in ipairs(zig_lines) do
			local value_kind, value, extra = tostring(raw_line or ""):match("^([^\t]+)\t([^\t]*)\t?(.*)$")
			if value_kind == "PREFERRED" and value ~= "" and extra ~= "" then
				info.preferred_commands = info.preferred_commands or {}
				info.preferred_commands[value] = extra
			end
		end
	end
	return commands, info
end

---@param lines string[]
---@param root string
---@param filepath string
---@return table<string, string>, table|nil
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
		local args = block:match("[Aa][Dd][Dd]_[Ee][Xx][Ee][Cc][Uu][Tt][Aa][Bb][Ll][Ee]%s*%((.*)%)")
		if not args then
			return
		end

		local tokens = common.tokenize_cmake_args(args)
		if #tokens == 0 then
			return
		end

		local index = 1
		while index <= #tokens do
			local token = tokens[index]
			if token == "WIN32" or token == "MACOSX_BUNDLE" or token == "EXCLUDE_FROM_ALL" then
				index = index + 1
			else
				break
			end
		end

		local target = tostring(tokens[index] or "")
		if target == "" or target:find("%${", 1, true) then
			return
		end

		local matched = false
		for source_index = index + 1, #tokens do
			local normalized_source = common.normalize_path_text(tokens[source_index])
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
			local start_col = line:find("[Aa][Dd][Dd]_[Ee][Xx][Ee][Cc][Uu][Tt][Aa][Bb][Ll][Ee]%s*%(")
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

	return commands, build_target_info(root, primary_target or first_target_name(commands), nil)
end

---@param filepath string
---@return table<string, string>, table|nil
function M.detect_cmake_project_commands(filepath)
	if not filepath or filepath == "" then
		return {}, nil
	end
	if type(vim.fn.filereadable) ~= "function" or type(vim.fn.readfile) ~= "function" then
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
	local cache_key = cmake_lists_path .. "::" .. common.normalize_path_text(filepath)
	local cached = state.get_bounded_cache_entry(
		state.cmake_target_cache,
		state.cmake_target_cache_order,
		cache_key
	)
	if cached and cached.mtime_key == mtime_key then
		return state.copy_string_map(cached.commands), copy_info(cached.info)
	end

	local zig_lines = detect_backend.parse_project_lines_once("cmake", cmake_lists_path, {
		"--match-path=" .. filepath,
	})
	if type(zig_lines) == "table" and #zig_lines > 0 then
			local commands, info = parse_zig_targets(root, zig_lines)
			return store_cached_result(cache_key, mtime_key, commands, info)
	end

	local lines = vim.fn.readfile(cmake_lists_path)
	if type(lines) ~= "table" then
		return store_cached_result(cache_key, mtime_key, {}, nil)
	end

	local commands, info = parse_basic_lua_targets(lines, root, filepath)
	return store_cached_result(cache_key, mtime_key, commands, info)
end

return M
