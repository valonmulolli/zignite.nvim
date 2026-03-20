local ui = require("zignite.ui")
local state = require("zignite.runtime.state")
local utils = require("zignite.utils")

---@type table
local M = {}

---@param filetype string
---@param command_name string
---@param command_template string
---@param mode string
---@return string|nil
function M.resolve_command_arguments(filetype, command_name, command_template, mode)
	if type(command_template) ~= "string" then
		return command_template
	end
	if not command_template:find(state.BUILD_ARG_PLACEHOLDER, 1, true) then
		return command_template
	end

	if type(vim.fn.input) ~= "function" then
		ui.show_output(
			string.format("Command '%s' requires extra arguments, but input prompt is unavailable.", command_name),
			mode
		)
		return nil
	end

	local prompt = string.format("%s %s args: ", filetype, command_name)
	if filetype == "zig" and command_name == "fetch" then
		prompt = "zig fetch url/path: "
	end

	local entered = vim.fn.input(prompt, "")
	if entered == nil then
		return nil
	end

	local trimmed = state.trim_text(entered)
	if trimmed == "" then
		ui.show_output(string.format("Command '%s' requires an argument.", command_name), mode)
		return nil
	end

	return (command_template:gsub(state.BUILD_ARG_PLACEHOLDER, state.shellescape_text(trimmed)))
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

	local normalized = utils.normalize_command(runner)
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
