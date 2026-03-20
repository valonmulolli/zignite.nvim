local common = require("zignite.build.parsers.common")
local bazel_common = require("zignite.build.parsers.bazel.common")
local detect_backend = require("zignite.build.detect.backend")
local parser = require("zignite.build.parsers.bazel.parser")
local systems = require("zignite.build.systems")

---@type table
local M = {}

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

	local build_files = bazel_common.find_build_files_for_path(filepath, root)
	if #build_files == 0 then
		return commands
	end
	local basename = vim.fn.fnamemodify(filepath, ":t")
	local primary_build_label = nil
	local primary_run_label = nil
	local primary_test_label = nil

	for _, build_info in ipairs(build_files) do
		local relative_filepath = common.normalize_path_text(
			common.make_relative_to_root(build_info.package_dir, filepath)
		)
		local zig_lines = detect_backend.parse_project_lines_once("bazel", build_info.build_file)
		local parsed_targets
		if type(zig_lines) == "table" and #zig_lines > 0 then
			parsed_targets = parser.parse_backend_target_lines(zig_lines)
		else
			parsed_targets = parser.get_parsed_build_targets(build_info)
		end
		for _, target in ipairs(parsed_targets) do
			local label = bazel_common.bazel_label(build_info.package_path, target.target_name)
			local command_rule_name = target.rule_name

			if target.supports_run and not bazel_common.RUN_RULES[command_rule_name] then
				command_rule_name = "cc_binary"
			end
			if target.supports_test and not bazel_common.TEST_RULES[command_rule_name] then
				command_rule_name = "cc_test"
			end
			bazel_common.add_target_commands(command_rule_name, build_info.package_path, target.target_name, commands)

			local matched = false
			for _, source_entry in ipairs(target.source_entries) do
				if bazel_common.source_matches_file(source_entry, relative_filepath, basename) then
					matched = true
					break
				end
			end
			if not matched then
				matched = bazel_common.glob_matches_file(target.source_entries, relative_filepath, basename)
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

			if target.supports_test
				and not primary_test_label
				and bazel_common.source_entries_are_related_to_file(target.source_entries, filepath)
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
