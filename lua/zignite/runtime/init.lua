local argv = require("zignite.runtime.argv")
local backend = require("zignite.runtime.backend")
local command = require("zignite.runtime.command")
local filetype = require("zignite.runtime.filetype")
local state = require("zignite.runtime.state")

---@type table
local M = {}

M.resolve_supported_filetype = filetype.resolve_supported_filetype
M.build_temp_execution_path = filetype.build_temp_execution_path

M.resolve_command_arguments = command.resolve_command_arguments
M.get_normalized_runner_command = command.get_normalized_runner_command
M.is_reserved_argv_command = command.is_reserved_argv_command
M.command_for_display = command.command_for_display

M.command_to_argv = argv.command_to_argv
M.build_system_command = backend.build_system_command

---@return nil
function M.reset()
	state.reset()
end

---@return table
function M._debug_state()
	return state.debug_state()
end

return M
