local common = require("zignite.build.parsers.common")
local detect_backend = require("zignite.build.detect.backend")
local state = require("zignite.build.state")
local systems = require("zignite.build.systems")

---@type table
local M = {}

---@param filepath string
---@return table<string, string>, string|nil
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
		return state.copy_string_map(cached.commands), cached.primary_target
	end

	local zig_lines = detect_backend.parse_project_lines_once("cmake", cmake_lists_path, {
		"--match-path=" .. filepath,
	})
	if type(zig_lines) == "table" and #zig_lines > 0 then
		---@type table<string, string>
		local commands = {}
		local primary_target = nil
		for _, raw_line in ipairs(zig_lines) do
			local line = tostring(raw_line or "")
			local kind, target, matched_flag = line:match("^([^\t]+)\t([^\t]+)\t([01])$")
			if kind == "TARGET" and target and target ~= "" then
				commands["cmake-build-" .. target] = systems.cmake_build_command(root, target)
				commands["cmake-run-" .. target] = systems.cmake_run_command(root, target)
				if matched_flag == "1" and not primary_target then
					primary_target = target
				end
			end
		end
		if not primary_target then
			for key, _ in pairs(commands) do
				local target = key:match("^cmake%-build%-(.+)$")
				if target then
					primary_target = target
					break
				end
			end
		end
		state.set_bounded_cache_entry(
			state.cmake_target_cache,
			state.cmake_target_cache_order,
			state.CMAKE_TARGET_CACHE_MAX,
			cache_key,
			{
				mtime_key = mtime_key,
				commands = state.copy_string_map(commands),
				primary_target = primary_target,
			}
		)
		return commands, primary_target
	end

	local lines = vim.fn.readfile(cmake_lists_path)
	if type(lines) ~= "table" then
		state.set_bounded_cache_entry(
			state.cmake_target_cache,
			state.cmake_target_cache_order,
			state.CMAKE_TARGET_CACHE_MAX,
			cache_key,
			{ mtime_key = mtime_key, commands = {}, primary_target = nil }
		)
		return {}, nil
	end

	local project_name = common.parse_cmake_project_name(lines)
	local relative_filepath = common.normalize_path_text(common.make_relative_to_root(root, filepath))
	local basename = vim.fn.fnamemodify(filepath, ":t")
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
			local token = common.resolve_cmake_token(tokens[index], project_name)
			if token == "WIN32" or token == "MACOSX_BUNDLE" or token == "EXCLUDE_FROM_ALL" then
				index = index + 1
			else
				break
			end
		end

		local target = common.resolve_cmake_token(tokens[index] or "", project_name)
		if target == "" or target:find("%${", 1, true) then
			return
		end

		local matched = false
		for source_index = index + 1, #tokens do
			local source_token = common.resolve_cmake_token(tokens[source_index], project_name)
			local normalized_source = common.normalize_path_text(source_token)
			if normalized_source ~= "" and (
				normalized_source == relative_filepath
				or normalized_source == basename
				or normalized_source:match("/" .. common.escape_lua_pattern(basename) .. "$")
			) then
				matched = true
				break
			end
		end

		commands["cmake-build-" .. target] = systems.cmake_build_command(root, target)
		commands["cmake-run-" .. target] = systems.cmake_run_command(root, target)
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

	if not primary_target then
		for key, _ in pairs(commands) do
			local target = key:match("^cmake%-build%-(.+)$")
			if target then
				primary_target = target
				break
			end
		end
	end

	state.set_bounded_cache_entry(
		state.cmake_target_cache,
		state.cmake_target_cache_order,
		state.CMAKE_TARGET_CACHE_MAX,
		cache_key,
		{
			mtime_key = mtime_key,
			commands = state.copy_string_map(commands),
			primary_target = primary_target,
		}
	)
	return commands, primary_target
end

return M
