local common = require("zignite.build.parsers.common")
local bazel_common = require("zignite.build.parsers.bazel.common")
local state = require("zignite.build.state")

---@type table
local M = {}

---@param line string
---@return string[]
local function split_tab_fields(line)
	---@type string[]
	local fields = {}
	local start_idx = 1
	while true do
		local tab_idx = line:find("\t", start_idx, true)
		if not tab_idx then
			fields[#fields + 1] = line:sub(start_idx)
			break
		end
		fields[#fields + 1] = line:sub(start_idx, tab_idx - 1)
		start_idx = tab_idx + 1
	end
	return fields
end

---@param lines string[]
---@return ZigniteBazelParsedTarget[]
function M.parse_backend_target_lines(lines)
	---@type ZigniteBazelParsedTarget[]
	local targets = {}
	for _, raw_line in ipairs(lines or {}) do
		local line = tostring(raw_line or "")
		if line ~= "" then
			local fields = split_tab_fields(line)
			if fields[1] == "TARGET" and type(fields[2]) == "string" and type(fields[3]) == "string" then
				---@type string[]
				local source_entries = {}
				for index = 6, #fields do
					if fields[index] ~= "" then
						source_entries[#source_entries + 1] = fields[index]
					end
				end
				targets[#targets + 1] = {
					rule_name = fields[2],
					target_name = fields[3],
					source_entries = source_entries,
					supports_run = fields[4] == "1",
					supports_test = fields[5] == "1",
				}
			end
		end
	end
	return targets
end

---@param lines string[]
---@return ZigniteBazelParsedTarget[]
function M.parse_build_targets(lines)
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

		local target_name = bazel_common.parse_named_string(block, "name")
		if type(target_name) ~= "string" or target_name == "" then
			return
		end

		local source_entries = bazel_common.collect_rule_source_entries(block)
		targets[#targets + 1] = {
			rule_name = rule_name,
			target_name = target_name,
			source_entries = source_entries,
			supports_run = bazel_common.rule_supports_run(rule_name, block),
			supports_test = bazel_common.rule_supports_test(rule_name, target_name, source_entries),
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
function M.get_parsed_build_targets(build_info)
	local mtime_key = state.get_file_mtime_key(build_info.build_file)
	local cached = state.get_bounded_cache_entry(
		state.bazel_build_cache,
		state.bazel_build_cache_order,
		build_info.build_file
	)
	if cached and cached.mtime_key == mtime_key and type(cached.targets) == "table" then
		return bazel_common.copy_parsed_targets(cached.targets)
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

	local targets = M.parse_build_targets(lines)
	state.set_bounded_cache_entry(
		state.bazel_build_cache,
		state.bazel_build_cache_order,
		state.BAZEL_BUILD_CACHE_MAX,
		build_info.build_file,
		{
			mtime_key = mtime_key,
			targets = bazel_common.copy_parsed_targets(targets),
		}
	)
	return targets
end

return M
