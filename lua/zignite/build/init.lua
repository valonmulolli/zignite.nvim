local detect = require("zignite.build.detect")
local resolve = require("zignite.build.resolve")

---@type table
local M = {}

M.get_detect_runtime_options = resolve.get_detect_runtime_options
M.select_live_command_name = resolve.select_live_command_name
M.select_live_command_name_for_filetype = resolve.select_live_command_name_for_filetype
M.can_detect_build_commands_for_filetype = resolve.can_detect_build_commands_for_filetype
M.get_build_commands_for_filetype = resolve.get_build_commands_for_filetype
M.get_build_commands_for_cached_lookup = resolve.get_build_commands_for_cached_lookup
M.get_build_commands_for_picker = resolve.get_build_commands_for_picker
M.get_preferred_project_command = resolve.get_preferred_project_command
M.set_last_build_command = resolve.set_last_build_command
M.get_last_build_command = resolve.get_last_build_command
M._debug_state = resolve._debug_state

---@return nil
function M.reset()
	detect.reset()
	resolve.reset()
end

return M
