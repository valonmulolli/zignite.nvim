local config = require("zignite.config")
local detect_backend = require("zignite.build.detect.backend")
local systems = require("zignite.build.systems")
local utils = require("zignite.utils")

---@type table
local M = {}

---@param lines string[]|nil
---@return table<string, string>
local function decode_maven_commands(lines)
	---@type table<string, string>
	local commands = {}
	---@type table<string, boolean>
	local seen = {}
	for _, raw_line in ipairs(lines or {}) do
		local goal = tostring(raw_line or "")
		if goal ~= "" then
			seen[goal] = true
		end
	end

	if seen.compile then
		commands["mvn-build"] = "mvn compile"
	end
	if seen.test then
		commands["mvn-test"] = "mvn test"
	end
	if seen.package then
		commands["mvn-package"] = "mvn package"
	end
	if seen["spring-boot:run"] then
		commands["mvn-run"] = "mvn spring-boot:run"
	elseif seen["exec:java"] then
		commands["mvn-run"] = "mvn exec:java"
	end

	return commands
end

---@param prefix string
---@param lines string[]|nil
---@return table<string, string>
local function decode_gradle_commands(prefix, lines)
	---@type table<string, string>
	local commands = {}
	---@type table<string, boolean>
	local seen = {}
	for _, raw_line in ipairs(lines or {}) do
		local task = tostring(raw_line or "")
		if task ~= "" then
			seen[task] = true
		end
	end

	if seen.build then
		commands["gradle-build"] = prefix .. " build"
	end
	if seen.test then
		commands["gradle-test"] = prefix .. " test"
	end
	if seen.clean then
		commands["gradle-clean"] = prefix .. " clean"
	end
	if seen.bootRun then
		commands["gradle-run"] = prefix .. " bootRun"
	elseif seen.run then
		commands["gradle-run"] = prefix .. " run"
	end

	return commands
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
		commands["mvn-build"] = "mvn compile"
		commands["mvn-test"] = "mvn test"
		commands["mvn-package"] = "mvn package"
		commands["mvn-run"] = "mvn exec:java"
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
		commands["gradle-build"] = "./gradlew build"
		commands["gradle-test"] = "./gradlew test"
		commands["gradle-clean"] = "./gradlew clean"
		commands["gradle-run"] = "./gradlew run"
	elseif vim.fn.filereadable(gradle_build) == 1 or vim.fn.filereadable(gradle_build_kts) == 1 then
		local gradle_file = vim.fn.filereadable(gradle_build_kts) == 1 and gradle_build_kts or gradle_build
		local zig_lines = detect_backend.parse_project_lines_once("gradle", gradle_file)
		if type(zig_lines) == "table" and #zig_lines > 0 then
			return decode_gradle_commands("gradle", zig_lines)
		end
		commands["gradle-build"] = "gradle build"
		commands["gradle-test"] = "gradle test"
		commands["gradle-clean"] = "gradle clean"
		commands["gradle-run"] = "gradle run"
	end
	return commands
end

return M
