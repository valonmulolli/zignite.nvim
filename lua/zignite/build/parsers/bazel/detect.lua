local bazel_common = require("zignite.build.parsers.bazel.common")
local detect_backend = require("zignite.build.detect.backend")
local systems = require("zignite.build.systems")

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
---@return table<string, string>, string|nil, string|nil, string|nil
local function parse_backend_command_lines(lines)
	---@type table<string, string>
	local commands = {}
	local primary_build = nil
	local primary_run = nil
	local primary_test = nil
	for _, raw_line in ipairs(lines or {}) do
		local line = tostring(raw_line or "")
		if line ~= "" then
			local fields = split_tab_fields(line)
			if fields[1] == "COMMAND" and type(fields[2]) == "string" and type(fields[3]) == "string" then
				commands[fields[2]] = fields[3]
			elseif fields[1] == "PRIMARY_BUILD" and type(fields[2]) == "string" and fields[2] ~= "" then
				primary_build = fields[2]
			elseif fields[1] == "PRIMARY_RUN" and type(fields[2]) == "string" and fields[2] ~= "" then
				primary_run = fields[2]
			elseif fields[1] == "PRIMARY_TEST" and type(fields[2]) == "string" and fields[2] ~= "" then
				primary_test = fields[2]
			end
		end
	end
	return commands, primary_build, primary_run, primary_test
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

	local build_files = bazel_common.find_build_files_for_path(filepath, root)
	if #build_files == 0 then
		return commands
	end
	local primary_build_label = nil
	local primary_run_label = nil
	local primary_test_label = nil

	for _, build_info in ipairs(build_files) do
		local zig_lines = detect_backend.parse_project_lines_once("bazel", build_info.build_file, {
			"--package-path=" .. build_info.package_path,
			"--match-path=" .. filepath,
		})
		if type(zig_lines) ~= "table" or #zig_lines == 0 then
			goto continue
		end

		local parsed_commands, primary_build, primary_run, primary_test = parse_backend_command_lines(zig_lines)
		for name, command in pairs(parsed_commands) do
			if commands[name] == nil then
				commands[name] = command
			end
		end
		if primary_build_label == nil and type(primary_build) == "string" then
			primary_build_label = primary_build
		end
		if primary_run_label == nil and type(primary_run) == "string" then
			primary_run_label = primary_run
		end
		if primary_test_label == nil and type(primary_test) == "string" then
			primary_test_label = primary_test
		end

		::continue::
	end

	if primary_build_label then
		commands["bazel-build"] = primary_build_label
	end
	if primary_run_label then
		commands["bazel-run"] = primary_run_label
	end
	if primary_test_label then
		commands["bazel-test"] = primary_test_label
	end

	return commands
end

return M
