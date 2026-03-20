local parser_common = require("zignite.build.parsers.common")

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

M.RUN_RULES = RUN_RULES
M.TEST_RULES = TEST_RULES

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
function M.collect_quoted_values(text)
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
function M.basename_without_extension(path)
	local basename = vim.fn.fnamemodify(path, ":t")
	return basename:gsub("%.[^%.]+$", "")
end

---@param name string
---@return string
function M.normalize_related_stem(name)
	local value = M.basename_without_extension(name):lower()
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
function M.package_path_from_dir(build_dir, workspace_root)
	local normalized_dir = parser_common.normalize_path_text(build_dir)
	local normalized_root = parser_common.normalize_path_text(workspace_root)
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
function M.bazel_label(package_path, target_name)
	if package_path == "" then
		return "//:" .. target_name
	end
	return "//" .. package_path .. ":" .. target_name
end

---@param start_path string
---@param workspace_root string
---@return ZigniteBazelBuildFile[]
function M.find_build_files_for_path(start_path, workspace_root)
	---@type ZigniteBazelBuildFile[]
	local build_files = {}
	local dir = vim.fn.fnamemodify(start_path, ":h")
	local normalized_root = parser_common.normalize_path_text(workspace_root)

	while type(dir) == "string" and dir ~= "" do
		for _, file_name in ipairs({ "BUILD.bazel", "BUILD" }) do
			local candidate = vim.fs.joinpath(dir, file_name)
			if vim.fn.filereadable(candidate) == 1 then
				build_files[#build_files + 1] = {
					build_file = candidate,
					package_dir = dir,
					package_path = M.package_path_from_dir(dir, workspace_root),
				}
				break
			end
		end

		local normalized_dir = parser_common.normalize_path_text(dir)
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
function M.parse_named_string(block, key)
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
function M.parse_string_list(block, key)
	local list_body = block:match(key .. "%s*=%s*%[(.-)%]")
	if type(list_body) ~= "string" or list_body == "" then
		return {}
	end
	return M.collect_quoted_values(list_body)
end

---@param block string
---@param key string
---@return string[]
function M.parse_glob_list(block, key)
	local list_body = block:match(key .. "%s*=%s*glob%s*%(%s*%[(.-)%]")
	if type(list_body) ~= "string" or list_body == "" then
		return {}
	end
	return M.collect_quoted_values(list_body)
end

---@param value string
---@return string
function M.glob_to_lua_pattern(value)
	local normalized = parser_common.normalize_path_text(value)
	local escaped = parser_common.escape_lua_pattern(normalized)
	escaped = escaped:gsub("%%%*%%%*", ".-")
	escaped = escaped:gsub("%%%*", "[^/]*")
	escaped = escaped:gsub("%%%?", ".")
	return "^" .. escaped .. "$"
end

---@param source_entry string
---@param relative_filepath string
---@param basename string
---@return boolean
function M.source_matches_file(source_entry, relative_filepath, basename)
	local normalized_source = parser_common.normalize_path_text(source_entry)
	if normalized_source == "" then
		return false
	end
	if normalized_source:find("//", 1, true) or normalized_source:find(":", 1, true) then
		return false
	end
	return normalized_source == relative_filepath
		or normalized_source == basename
		or normalized_source:match("/" .. parser_common.escape_lua_pattern(basename) .. "$") ~= nil
end

---@param patterns string[]
---@param relative_filepath string
---@param basename string
---@return boolean
function M.glob_matches_file(patterns, relative_filepath, basename)
	for _, pattern in ipairs(patterns) do
		local lua_pattern = M.glob_to_lua_pattern(pattern)
		if relative_filepath:match(lua_pattern) or basename:match(lua_pattern) then
			return true
		end
	end
	return false
end

---@param source_entries string[]
---@param filepath string
---@return boolean
function M.source_entries_are_related_to_file(source_entries, filepath)
	local current_stem = M.normalize_related_stem(filepath)
	if current_stem == "" then
		return false
	end
	for _, source_entry in ipairs(source_entries) do
		local source_stem = M.normalize_related_stem(source_entry)
		if source_stem ~= "" and source_stem == current_stem then
			return true
		end
	end
	return false
end

---@param name string
---@return boolean
function M.looks_like_test_name(name)
	local value = tostring(name or ""):lower()
	return value:find("test", 1, true) ~= nil or value:find("spec", 1, true) ~= nil
end

---@param rule_name string
---@param block string
---@return boolean
function M.rule_supports_run(rule_name, block)
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
	return M.parse_named_string(block, "main") ~= nil or M.parse_named_string(block, "entry_point") ~= nil
end

---@param rule_name string
---@param target_name string
---@param source_entries string[]
---@return boolean
function M.rule_supports_test(rule_name, target_name, source_entries)
	if TEST_RULES[rule_name] then
		return true
	end
	local normalized_rule = tostring(rule_name or ""):lower()
	if normalized_rule:find("test", 1, true) ~= nil or normalized_rule:find("spec", 1, true) ~= nil then
		return true
	end
	if M.looks_like_test_name(target_name) then
		return true
	end
	for _, source_entry in ipairs(source_entries) do
		if M.looks_like_test_name(source_entry) then
			return true
		end
	end
	return false
end

---@param block string
---@return string[]
function M.collect_rule_source_entries(block)
	---@type string[]
	local entries = {}
	for _, key in ipairs({ "srcs", "hdrs", "textual_hdrs", "main", "src", "sources", "test_srcs", "tests" }) do
		local value = M.parse_named_string(block, key)
		if type(value) == "string" and value ~= "" then
			entries[#entries + 1] = value
		end
		for _, item in ipairs(M.parse_string_list(block, key)) do
			entries[#entries + 1] = item
		end
		for _, item in ipairs(M.parse_glob_list(block, key)) do
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
function M.add_target_commands(rule_name, package_path, target_name, commands)
	local label = M.bazel_label(package_path, target_name)
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
function M.copy_string_list(entries)
	---@type string[]
	local copied = {}
	for _, entry in ipairs(entries or {}) do
		copied[#copied + 1] = tostring(entry)
	end
	return copied
end

---@param targets ZigniteBazelParsedTarget[]
---@return ZigniteBazelParsedTarget[]
function M.copy_parsed_targets(targets)
	---@type ZigniteBazelParsedTarget[]
	local copied = {}
	for _, target in ipairs(targets or {}) do
		copied[#copied + 1] = {
			rule_name = tostring(target.rule_name or ""),
			target_name = tostring(target.target_name or ""),
			source_entries = M.copy_string_list(target.source_entries),
			supports_run = target.supports_run == true,
			supports_test = target.supports_test == true,
		}
	end
	return copied
end

return M
