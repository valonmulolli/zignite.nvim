local project = require("zignite.utils.project")

---@type table
local M = {}

---@param s string
---@return string
local function trim(s)
	return s:match("^%s*(.-)%s*$")
end

---@param tbl string[]
---@return string[]
local function filter_empty(tbl)
	---@type string[]
	local new_tbl = {}
	for _, v in ipairs(tbl) do
		local trimmed = trim(v)
		if trimmed ~= "" then
			table.insert(new_tbl, trimmed)
		end
	end
	return new_tbl
end

---@param command string
---@param filepath string
---@return string
function M.substitute_variables(command, filepath)
	if not filepath or filepath == "" then
		return command
	end

	local file = vim.fn.expand(filepath)
	local fileName = vim.fn.fnamemodify(file, ":t")
	local fileNameWithoutExt = vim.fn.fnamemodify(file, ":t:r")
	local dir = vim.fn.fnamemodify(file, ":h")
	local fileExt = vim.fn.fnamemodify(file, ":e")
	local dirName = vim.fn.fnamemodify(dir, ":t")
	local fileDirPath = dir
	local relativeFile = vim.fn.fnamemodify(file, ":.")
	local relativeDir = vim.fn.fnamemodify(dir, ":.")

	local projectName = dirName
	local project_root = project.get_project_root(file)
	if project_root then
		projectName = vim.fn.fnamemodify(project_root, ":t")
	end
	local projectNameShort = projectName:gsub("%-cli$", ""):gsub("%-tui$", ""):gsub("%-app$", "")

	local substitutions = {
		["$dir"] = vim.fn.shellescape(dir),
		["$file"] = vim.fn.shellescape(file),
		["$fileName"] = vim.fn.shellescape(fileName),
		["$fileNameWithoutExt"] = vim.fn.shellescape(fileNameWithoutExt),
		["$fileExt"] = fileExt,
		["$dirName"] = vim.fn.shellescape(dirName),
		["$fileDirPath"] = vim.fn.shellescape(fileDirPath),
		["$relativeFile"] = vim.fn.shellescape(relativeFile),
		["$relativeDir"] = vim.fn.shellescape(relativeDir),
		["$projectName"] = vim.fn.shellescape(projectName),
		["$projectNameShort"] = vim.fn.shellescape(projectNameShort),
		["$DIR"] = dir,
		["$FILE"] = file,
		["$FILENAME"] = fileName,
		["$FILENAMEWITHOUTEXT"] = fileNameWithoutExt,
		["$PROJECTNAME"] = projectName,
		["$PROJECTNAMESHORT"] = projectNameShort,
		["%%"] = vim.fn.shellescape(file),
	}

	return command:gsub("%$([%w_]+)", function(var)
		return substitutions["$" .. var] or ("$" .. var)
	end)
end

---@param command string
---@param filepath string
---@return string
function M.substitute_variables_raw(command, filepath)
	if not filepath or filepath == "" then
		return command
	end

	local file = vim.fn.expand(filepath)
	local fileName = vim.fn.fnamemodify(file, ":t")
	local fileNameWithoutExt = vim.fn.fnamemodify(file, ":t:r")
	local dir = vim.fn.fnamemodify(file, ":h")
	local fileExt = vim.fn.fnamemodify(file, ":e")

	local substitutions = {
		["$dir"] = dir,
		["$file"] = file,
		["$fileName"] = fileName,
		["$fileNameWithoutExt"] = fileNameWithoutExt,
		["$fileExt"] = fileExt,
		["%%"] = file,
	}

	local result = command
	for pattern, replacement in pairs(substitutions) do
		local escaped_pattern = pattern:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
		result = result:gsub(escaped_pattern, replacement)
	end
	result = result:gsub("%$([%w_]+)", function(var)
		return substitutions["$" .. var] or ("$" .. var)
	end)

	return result
end

---@param runner string|string[]|table
---@return string|nil
function M.normalize_command(runner)
	if type(runner) == "string" then
		return runner
	elseif type(runner) == "table" then
		---@type string[]
		local commands
		if runner.cmd then
			if type(runner.cmd) == "table" then
				commands = filter_empty(runner.cmd)
			else
				commands = { trim(runner.cmd) }
			end
		else
			commands = filter_empty(runner)
		end

		if #commands == 0 then
			return nil
		elseif #commands == 1 then
			return commands[1]
		else
			return table.concat(commands, " && ")
		end
	end
	return nil
end

return M
