local common = require("zignite.build.parsers.common")
local state = require("zignite.build.state")
local systems = require("zignite.build.systems")

---@type table<string, boolean>
local RUN_RULES = {
	cc_binary = true,
	go_binary = true,
	java_binary = true,
	py_binary = true,
	rust_binary = true,
	sh_binary = true,
}

---@type table<string, boolean>
local TEST_RULES = {
	cc_test = true,
	go_test = true,
	java_test = true,
	py_test = true,
	rust_test = true,
	sh_test = true,
}

---@type table
local M = {}

---@class ZigniteBazelBuildFile
---@field build_file string
---@field package_dir string
---@field package_path string

---@class ZigniteBazelParsedTarget
---@field rule_name string
---@field target_name string
---@field source_entries string[]
---@field supports_run boolean
---@field supports_test boolean

---@param text string
---@return string[]
local function collect_quoted_values(text)
	---@type string[]
	local values = {}
	local source = tostring(text or "")
	for value in source:gmatch('"([^"]+)"') do
		values[#values + 1] = value
	end
	for value in source:gmatch("'([^']+)'") do
		values[#values + 1] = value
	end
	return values
end

---@param path string
---@return string
local function basename_without_extension(path)
	local basename = vim.fn.fnamemodify(path, ":t")
	return basename:gsub("%.[^%.]+$", "")
end

---@param name string
---@return string
local function normalize_related_stem(name)
	local value = basename_without_extension(name):lower()
	value = value:gsub("^test[%._%-]", "")
	value = value:gsub("^test", "")
	value = value:gsub("[%._%-]tests?$", "")
	value = value:gsub("tests?$", "")
	value = value:gsub("[%._%-]specs?$", "")
	value = value:gsub("specs?$", "")
	return value
end

---@param build_dir string
---@param workspace_root string
---@return string
local function package_path_from_dir(build_dir, workspace_root)
	local normalized_dir = common.normalize_path_text(build_dir)
	local normalized_root = common.normalize_path_text(workspace_root)
	if normalized_dir == normalized_root then
		return ""
	end
	if normalized_dir:sub(1, #normalized_root + 1) == (normalized_root .. "/") then
		return normalized_dir:sub(#normalized_root + 2)
	end
	return ""
end

---@param package_path string
---@param target_name string
---@return string
local function bazel_label(package_path, target_name)
	if package_path == "" then
		return "//:" .. target_name
	end
	return "//" .. package_path .. ":" .. target_name
end

---@param start_path string
---@param workspace_root string
---@return ZigniteBazelBuildFile[]
local function find_build_files_for_path(start_path, workspace_root)
	---@type ZigniteBazelBuildFile[]
	local build_files = {}
	local dir = vim.fn.fnamemodify(start_path, ":h")
	local normalized_root = common.normalize_path_text(workspace_root)

	while type(dir) == "string" and dir ~= "" do
		for _, file_name in ipairs({ "BUILD.bazel", "BUILD" }) do
			local candidate = vim.fs.joinpath(dir, file_name)
			if vim.fn.filereadable(candidate) == 1 then
				build_files[#build_files + 1] = {
					build_file = candidate,
					package_dir = dir,
					package_path = package_path_from_dir(dir, workspace_root),
				}
				break
			end
		end

		local normalized_dir = common.normalize_path_text(dir)
		if normalized_dir == normalized_root then
			break
		end

		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then
			break
		end
		dir = parent
	end

	return build_files
end

---@param block string
---@param key string
---@return string|nil
local function parse_named_string(block, key)
	local double_quoted = block:match(key .. '%s*=%s*"([^"]+)"')
	if double_quoted and double_quoted ~= "" then
		return double_quoted
	end
	local single_quoted = block:match(key .. "%s*=%s*'([^']+)'")
	if single_quoted and single_quoted ~= "" then
		return single_quoted
	end
	return nil
end

---@param block string
---@param key string
---@return string[]
local function parse_string_list(block, key)
	local list_body = block:match(key .. "%s*=%s*%[(.-)%]")
	if type(list_body) ~= "string" or list_body == "" then
		return {}
	end
	return collect_quoted_values(list_body)
end

---@param block string
---@param key string
---@return string[]
local function parse_glob_list(block, key)
	local list_body = block:match(key .. "%s*=%s*glob%s*%(%s*%[(.-)%]")
	if type(list_body) ~= "string" or list_body == "" then
		return {}
	end
	return collect_quoted_values(list_body)
end

---@param value string
---@return string
local function glob_to_lua_pattern(value)
	local normalized = common.normalize_path_text(value)
	local escaped = common.escape_lua_pattern(normalized)
	escaped = escaped:gsub("%%%*%%%*", ".-")
	escaped = escaped:gsub("%%%*", "[^/]*")
	escaped = escaped:gsub("%%%?", ".")
	return "^" .. escaped .. "$"
end

---@param source_entry string
---@param relative_filepath string
---@param basename string
---@return boolean
local function source_matches_file(source_entry, relative_filepath, basename)
	local normalized_source = common.normalize_path_text(source_entry)
	if normalized_source == "" then
		return false
	end
	if normalized_source:find("//", 1, true) or normalized_source:find(":", 1, true) then
		return false
	end
	return normalized_source == relative_filepath
		or normalized_source == basename
		or normalized_source:match("/" .. common.escape_lua_pattern(basename) .. "$") ~= nil
end

---@param patterns string[]
---@param relative_filepath string
---@param basename string
---@return boolean
local function glob_matches_file(patterns, relative_filepath, basename)
	for _, pattern in ipairs(patterns) do
		local lua_pattern = glob_to_lua_pattern(pattern)
		if relative_filepath:match(lua_pattern) or basename:match(lua_pattern) then
			return true
		end
	end
	return false
end

---@param source_entries string[]
---@param filepath string
---@return boolean
local function source_entries_are_related_to_file(source_entries, filepath)
	local current_stem = normalize_related_stem(filepath)
	if current_stem == "" then
		return false
	end
	for _, source_entry in ipairs(source_entries) do
		local source_stem = normalize_related_stem(source_entry)
		if source_stem ~= "" and source_stem == current_stem then
			return true
		end
	end
	return false
end

---@param name string
---@return boolean
local function looks_like_test_name(name)
	local value = tostring(name or ""):lower()
	return value:find("test", 1, true) ~= nil or value:find("spec", 1, true) ~= nil
end

---@param rule_name string
---@param block string
---@return boolean
local function rule_supports_run(rule_name, block)
	if RUN_RULES[rule_name] then
		return true
	end
	local normalized_name = tostring(rule_name or ""):lower()
	if normalized_name:find("test", 1, true) ~= nil then
		return false
	end
	if normalized_name:find("binary", 1, true) ~= nil or normalized_name:find("_bin", 1, true) ~= nil then
		return true
	end
	return parse_named_string(block, "main") ~= nil or parse_named_string(block, "entry_point") ~= nil
end

---@param rule_name string
---@param target_name string
---@param source_entries string[]
---@return boolean
local function rule_supports_test(rule_name, target_name, source_entries)
	if TEST_RULES[rule_name] then
		return true
	end
	local normalized_rule = tostring(rule_name or ""):lower()
	if normalized_rule:find("test", 1, true) ~= nil or normalized_rule:find("spec", 1, true) ~= nil then
		return true
	end
	if looks_like_test_name(target_name) then
		return true
	end
	for _, source_entry in ipairs(source_entries) do
		if looks_like_test_name(source_entry) then
			return true
		end
	end
	return false
end

---@param block string
---@return string[]
local function collect_rule_source_entries(block)
	---@type string[]
	local entries = {}
	for _, key in ipairs({ "srcs", "hdrs", "textual_hdrs", "main", "src", "sources", "test_srcs", "tests" }) do
		local value = parse_named_string(block, key)
		if type(value) == "string" and value ~= "" then
			entries[#entries + 1] = value
		end
		for _, item in ipairs(parse_string_list(block, key)) do
			entries[#entries + 1] = item
		end
		for _, item in ipairs(parse_glob_list(block, key)) do
			entries[#entries + 1] = item
		end
	end
	return entries
end

---@param rule_name string
---@param package_path string
---@param target_name string
---@param commands table<string, string>
---@return nil
local function add_target_commands(rule_name, package_path, target_name, commands)
	local label = bazel_label(package_path, target_name)
	if commands["bazel-build-" .. target_name] == nil then
		commands["bazel-build-" .. target_name] = "bazel build " .. label
	end
	if commands["bazel-run-" .. target_name] == nil and RUN_RULES[rule_name] then
		commands["bazel-run-" .. target_name] = "bazel run " .. label
	end
	if commands["bazel-test-" .. target_name] == nil and TEST_RULES[rule_name] then
		commands["bazel-test-" .. target_name] = "bazel test " .. label
	end
end

---@param entries string[]
---@return string[]
local function copy_string_list(entries)
	---@type string[]
	local copied = {}
	for _, entry in ipairs(entries or {}) do
		copied[#copied + 1] = tostring(entry)
	end
	return copied
end

---@param targets ZigniteBazelParsedTarget[]
---@return ZigniteBazelParsedTarget[]
local function copy_parsed_targets(targets)
	---@type ZigniteBazelParsedTarget[]
	local copied = {}
	for _, target in ipairs(targets or {}) do
		copied[#copied + 1] = {
			rule_name = tostring(target.rule_name or ""),
			target_name = tostring(target.target_name or ""),
			source_entries = copy_string_list(target.source_entries),
			supports_run = target.supports_run == true,
			supports_test = target.supports_test == true,
		}
	end
	return copied
end

---@param lines string[]
---@return ZigniteBazelParsedTarget[]
local function parse_build_targets(lines)
	---@type ZigniteBazelParsedTarget[]
	local targets = {}
	local capture_rule = nil
	local capture_lines = nil
	local depth = 0

	---@param rule_name string
	---@param block string
	---@return nil
	local function commit_block(rule_name, block)
		if rule_name == "load" or rule_name == "package" then
			return
		end

		local target_name = parse_named_string(block, "name")
		if type(target_name) ~= "string" or target_name == "" then
			return
		end

		local source_entries = collect_rule_source_entries(block)
		targets[#targets + 1] = {
			rule_name = rule_name,
			target_name = target_name,
			source_entries = source_entries,
			supports_run = rule_supports_run(rule_name, block),
			supports_test = rule_supports_test(rule_name, target_name, source_entries),
		}
	end

	for _, raw_line in ipairs(lines) do
		local line = common.strip_hash_comment(raw_line)
		if capture_rule == nil then
			local rule_name = line:match("^%s*([%a_][%w_]*)%s*%(")
			if rule_name then
				capture_rule = rule_name
				capture_lines = { line }
				local opens = select(2, line:gsub("%(", ""))
				local closes = select(2, line:gsub("%)", ""))
				depth = opens - closes
				if depth <= 0 then
					commit_block(capture_rule, table.concat(capture_lines, "\n"))
					capture_rule = nil
					capture_lines = nil
				end
			end
		else
			capture_lines[#capture_lines + 1] = line
			local opens = select(2, line:gsub("%(", ""))
			local closes = select(2, line:gsub("%)", ""))
			depth = depth + opens - closes
			if depth <= 0 then
				commit_block(capture_rule, table.concat(capture_lines, "\n"))
				capture_rule = nil
				capture_lines = nil
			end
		end
	end

	return targets
end

---@param build_info ZigniteBazelBuildFile
---@return ZigniteBazelParsedTarget[]
local function get_parsed_build_targets(build_info)
	local mtime_key = state.get_file_mtime_key(build_info.build_file)
	local cached = state.get_bounded_cache_entry(
		state.bazel_build_cache,
		state.bazel_build_cache_order,
		build_info.build_file
	)
	if cached and cached.mtime_key == mtime_key and type(cached.targets) == "table" then
		return copy_parsed_targets(cached.targets)
	end

	local lines = vim.fn.readfile(build_info.build_file)
	if type(lines) ~= "table" or #lines == 0 then
		state.set_bounded_cache_entry(
			state.bazel_build_cache,
			state.bazel_build_cache_order,
			state.BAZEL_BUILD_CACHE_MAX,
			build_info.build_file,
			{
				mtime_key = mtime_key,
				targets = {},
			}
		)
		return {}
	end

	local targets = parse_build_targets(lines)
	state.set_bounded_cache_entry(
		state.bazel_build_cache,
		state.bazel_build_cache_order,
		state.BAZEL_BUILD_CACHE_MAX,
		build_info.build_file,
		{
			mtime_key = mtime_key,
			targets = copy_parsed_targets(targets),
		}
	)
	return targets
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

	---@type table<string, string>
	local commands = {
		["bazel-build"] = "bazel build $zignite_args",
		["bazel-run"] = "bazel run $zignite_args",
		["bazel-test"] = "bazel test $zignite_args",
		["bazel-query"] = "bazel query $zignite_args",
		["bazel-clean"] = "bazel clean",
		["bazel-build-all"] = "bazel build //...",
		["bazel-test-all"] = "bazel test //...",
	}

	if type(vim.fn.readfile) ~= "function" then
		return commands
	end

	local build_files = find_build_files_for_path(filepath, root)
	if #build_files == 0 then
		return commands
	end
	local basename = vim.fn.fnamemodify(filepath, ":t")
	local primary_build_label = nil
	local primary_run_label = nil
	local primary_test_label = nil

	for _, build_info in ipairs(build_files) do
		local relative_filepath = common.normalize_path_text(common.make_relative_to_root(build_info.package_dir, filepath))
		for _, target in ipairs(get_parsed_build_targets(build_info)) do
			local label = bazel_label(build_info.package_path, target.target_name)
			local command_rule_name = target.rule_name

			if target.supports_run and not RUN_RULES[command_rule_name] then
				command_rule_name = "cc_binary"
			end
			if target.supports_test and not TEST_RULES[command_rule_name] then
				command_rule_name = "cc_test"
			end
			add_target_commands(command_rule_name, build_info.package_path, target.target_name, commands)

			local matched = false
			for _, source_entry in ipairs(target.source_entries) do
				if source_matches_file(source_entry, relative_filepath, basename) then
					matched = true
					break
				end
			end
			if not matched then
				matched = glob_matches_file(target.source_entries, relative_filepath, basename)
			end

			if matched and not primary_build_label then
				primary_build_label = label
			end
			if matched and target.supports_run and not primary_run_label then
				primary_run_label = label
			end
			if matched and target.supports_test and not primary_test_label then
				primary_test_label = label
			end

			if
				target.supports_test
				and not primary_test_label
				and source_entries_are_related_to_file(target.source_entries, filepath)
			then
				primary_test_label = label
			end
		end
	end

	if primary_build_label then
		commands["bazel-build"] = "bazel build " .. primary_build_label
	end
	if primary_run_label then
		commands["bazel-run"] = "bazel run " .. primary_run_label
	end
	if primary_test_label then
		commands["bazel-test"] = "bazel test " .. primary_test_label
	end

	return commands
end

return M
