local config = require("zignite.config")
local systems = require("zignite.build.systems")
local utils = require("zignite.utils")

---@type table
local M = {}

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
		commands["mvn-build"] = "mvn compile"
		commands["mvn-test"] = "mvn test"
		commands["mvn-package"] = "mvn package"
		commands["mvn-run"] = "mvn exec:java"
	end
	if vim.fn.filereadable(gradle_wrapper) == 1 then
		commands["gradle-build"] = "./gradlew build"
		commands["gradle-test"] = "./gradlew test"
		commands["gradle-clean"] = "./gradlew clean"
		commands["gradle-run"] = "./gradlew run"
	elseif vim.fn.filereadable(gradle_build) == 1 or vim.fn.filereadable(gradle_build_kts) == 1 then
		commands["gradle-build"] = "gradle build"
		commands["gradle-test"] = "gradle test"
		commands["gradle-clean"] = "gradle clean"
		commands["gradle-run"] = "gradle run"
	end
	return commands
end

return M
