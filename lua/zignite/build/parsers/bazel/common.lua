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

return M
