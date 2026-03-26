local ui_windows = require("zignite.ui.windows")
local state = require("zignite.runtime.state")
local command_utils = require("zignite.utils.command")

---@type table
local M = {}

---@param value string
---@return string
local function normalize_github_repo_reference(value)
	local trimmed = state.trim_text(value)
	if trimmed == "" then
		return trimmed
	end

	if trimmed:match("^%-%-") then
		return trimmed
	end

	local git_url = trimmed:match("^(git%+https?://github%.com/.+)$")
	if git_url ~= nil then
		return "--save " .. git_url
	end

	local base_url, path = trimmed:match("^(https?://github%.com/)(.+)$")
	if base_url == nil or path == nil then
		local shorthand, ref = trimmed:match("^([%w_.-]+/[%w_.-]+)#(.+)$")
		if shorthand ~= nil then
			return "--save git+https://github.com/" .. shorthand:gsub("%.git$", "") .. "#" .. ref
		end
		if trimmed:match("^[%w_.-]+/[%w_.-]+$") then
			return "--save git+https://github.com/" .. trimmed:gsub("%.git$", "")
		end
		return trimmed
	end

	local url_without_fragment, fragment = path:match("^(.-)#(.+)$")
	path = url_without_fragment or path
	local url_without_query = path:match("^(.-)%?.*$")
	path = url_without_query or path
	path = path:gsub("/+$", "")

	local owner, repo, remainder = path:match("^([^/]+)/([^/]+)(.*)$")
	if owner == nil or repo == nil then
		return trimmed
	end

	repo = repo:gsub("%.git$", "")
	if remainder ~= "" and remainder ~= nil then
		local tree_ref = remainder:match("^/tree/(.+)$")
		if tree_ref ~= nil then
			fragment = tree_ref
		else
			return trimmed
		end
	end

	local normalized = "--save git+" .. base_url .. owner .. "/" .. repo
	if fragment ~= nil and fragment ~= "" then
		normalized = normalized .. "#" .. fragment
	end
	return normalized
end

---@param filetype string
---@param command_name string
---@param value string
---@return string
local function normalize_command_arguments(filetype, command_name, value)
	if filetype == "zig" and command_name == "fetch" then
		return normalize_github_repo_reference(value)
	end
	return value
end

---@param filetype string
---@param command_name string
---@return boolean
local function should_shellescape_command_arguments(filetype, command_name)
	if filetype == "zig" and command_name == "fetch" then
		return false
	end
	return true
end

---@param filetype string
---@param command_name string
---@return string
function M.get_command_argument_prompt(filetype, command_name)
	local prompt = string.format("%s %s args", filetype, command_name)
	if filetype == "zig" and command_name == "fetch" then
		return "zig fetch url/path"
	end
	return prompt
end

---@param command_template string
---@return boolean
function M.command_requires_arguments(command_template)
	return type(command_template) == "string"
		and command_template:find(state.BUILD_ARG_PLACEHOLDER, 1, true) ~= nil
end

---@param filetype string
---@param command_name string
---@param command_template string
---@param mode string
---@param provided_args string|nil
---@return string|nil
function M.resolve_command_arguments(filetype, command_name, command_template, mode, provided_args)
	if type(command_template) ~= "string" then
		return command_template
	end
	if not M.command_requires_arguments(command_template) then
		return command_template
	end

	local entered = provided_args
	if entered == nil and type(vim.fn.input) ~= "function" then
		ui_windows.show_output(
			string.format("Command '%s' requires extra arguments, but input prompt is unavailable.", command_name),
			mode
		)
		return nil
	end

	if entered == nil then
		entered = vim.fn.input(M.get_command_argument_prompt(filetype, command_name) .. ": ", "")
	end

	if entered == nil then
		return nil
	end

	local trimmed = state.trim_text(entered)
	if trimmed == "" then
		ui_windows.show_output(string.format("Command '%s' requires an argument.", command_name), mode)
		return nil
	end

	trimmed = normalize_command_arguments(filetype, command_name, trimmed)
	if should_shellescape_command_arguments(filetype, command_name) then
		trimmed = state.shellescape_text(trimmed)
	end

	return (command_template:gsub(state.BUILD_ARG_PLACEHOLDER, trimmed))
end

---@param filetype string
---@param runner string|string[]|table
---@return string|nil
function M.get_normalized_runner_command(filetype, runner)
	local key = tostring(filetype) .. "\0" .. tostring(runner)
	local cached = state.get_normalized_runner_cache(key)
	if cached ~= nil then
		return cached
	end

	local normalized = command_utils.normalize_command(runner)
	if normalized ~= nil then
		state.set_normalized_runner_cache(key, normalized)
	end
	return normalized
end

---@param command string
---@return boolean
function M.is_reserved_argv_command(command)
	if type(command) ~= "string" then
		return false
	end
	local trimmed = command:match("^%s*(.-)%s*$") or ""
	return trimmed == "--argv" or trimmed:match("^%-%-argv%s+") ~= nil
end

---@param command string
---@return string
function M.command_for_display(command)
	if type(command) ~= "string" then
		return ""
	end
	return (command:gsub(state.BUILD_ARG_PLACEHOLDER, state.BUILD_ARG_DISPLAY_PLACEHOLDER))
end

return M
