local config = require("zignite.config")
local detect_backend = require("zignite.build.detect.backend")
local systems = require("zignite.build.systems")
local utils = require("zignite.utils")

---@type table
local M = {}

---@param run_command string|nil
---@return table<string, string>
local function build_maven_commands(run_command)
	---@type table<string, string>
	local commands = {
		["mvn-build"] = "mvn compile",
		["mvn-test"] = "mvn test",
		["mvn-package"] = "mvn package",
	}
	if type(run_command) == "string" and run_command ~= "" then
		commands["mvn-run"] = run_command
	end
	return commands
end

---@param prefix string
---@param run_task string|nil
---@return table<string, string>
local function build_gradle_commands(prefix, run_task)
	---@type table<string, string>
	local commands = {
		["gradle-build"] = prefix .. " build",
		["gradle-test"] = prefix .. " test",
		["gradle-clean"] = prefix .. " clean",
	}
	if type(run_task) == "string" and run_task ~= "" then
		commands["gradle-run"] = prefix .. " " .. run_task
	end
	return commands
end

---@param lines string[]|nil
---@return table<string, string>
local function decode_maven_commands(lines)
	---@type table<string, boolean>
	local seen = {}
	for _, raw_line in ipairs(lines or {}) do
		local goal = tostring(raw_line or "")
		if goal ~= "" then
			seen[goal] = true
		end
	end

	local run_command = nil
	if seen["spring-boot:run"] then
		run_command = "mvn spring-boot:run"
	elseif seen["exec:java"] then
		run_command = "mvn exec:java"
	end

	return build_maven_commands(run_command)
end

---@param prefix string
---@param lines string[]|nil
---@return table<string, string>
local function decode_gradle_commands(prefix, lines)
	---@type table<string, boolean>
	local seen = {}
	for _, raw_line in ipairs(lines or {}) do
		local task = tostring(raw_line or "")
		if task ~= "" then
			seen[task] = true
		end
	end

	local run_task = nil
	if seen.bootRun then
		run_task = "bootRun"
	elseif seen.run then
		run_task = "run"
	end

	return build_gradle_commands(prefix, run_task)
end

---@param filepath string
---@return table<string, string>
function M.detect_java_like_project_commands(filepath)
	if not filepath or filepath == "" or type(vim.fn.filereadable) ~= "function" then
		return {}
	end

	local root = utils.get_project_root(filepath, config.options.project)
	if not root then
		root = systems.find_root_for_files(filepath, { "pom.xml", "gradlew", "build.gradle", "build.gradle.kts" }, 12)
			or vim.fn.fnamemodify(filepath, ":h")
	end

	---@type table<string, string>
	local commands = {}
	local pom_xml = vim.fs.joinpath(root, "pom.xml")
	local gradle_wrapper = vim.fs.joinpath(root, "gradlew")
	local gradle_build = vim.fs.joinpath(root, "build.gradle")
	local gradle_build_kts = vim.fs.joinpath(root, "build.gradle.kts")

	if vim.fn.filereadable(pom_xml) == 1 then
		local zig_lines = detect_backend.parse_project_lines_once("maven", pom_xml)
		if type(zig_lines) == "table" and #zig_lines > 0 then
			return decode_maven_commands(zig_lines)
		end
		return build_maven_commands(nil)
	end
	if vim.fn.filereadable(gradle_wrapper) == 1 then
		local gradle_file = nil
		if vim.fn.filereadable(gradle_build_kts) == 1 then
			gradle_file = gradle_build_kts
		elseif vim.fn.filereadable(gradle_build) == 1 then
			gradle_file = gradle_build
		end
		if gradle_file then
			local zig_lines = detect_backend.parse_project_lines_once("gradle", gradle_file)
			if type(zig_lines) == "table" and #zig_lines > 0 then
				return decode_gradle_commands("./gradlew", zig_lines)
			end
		end
		return build_gradle_commands("./gradlew", nil)
	elseif vim.fn.filereadable(gradle_build) == 1 or vim.fn.filereadable(gradle_build_kts) == 1 then
		local gradle_file = vim.fn.filereadable(gradle_build_kts) == 1 and gradle_build_kts or gradle_build
		local zig_lines = detect_backend.parse_project_lines_once("gradle", gradle_file)
		if type(zig_lines) == "table" and #zig_lines > 0 then
			return decode_gradle_commands("gradle", zig_lines)
		end
		return build_gradle_commands("gradle", nil)
	end
	return commands
end

return M
