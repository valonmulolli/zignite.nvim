---@type table
local M = {}

---@param commands table[]
---@param command_name string
---@return integer|nil
function M.find_command_index(commands, command_name)
	for index, cmd in ipairs(commands) do
		if cmd.name == command_name then
			return index
		end
	end
	return nil
end

---@param all_commands table[]
---@param filter_query string
---@param selected_index integer
---@param command_for_display fun(command: string): string
---@return table[], integer
function M.apply_filter(all_commands, filter_query, selected_index, command_for_display)
	local query = tostring(filter_query or ""):lower()
	---@type table[]
	local filtered_commands = {}
	for _, cmd in ipairs(all_commands) do
		local display_command = command_for_display(cmd.command)
		local name_match = cmd.name:lower():find(query, 1, true) ~= nil
		local command_match = display_command:lower():find(query, 1, true) ~= nil
		if query == "" or name_match or command_match then
			filtered_commands[#filtered_commands + 1] = cmd
		end
	end

	if #filtered_commands == 0 then
		return filtered_commands, 0
	end
	if selected_index < 1 then
		return filtered_commands, 1
	end
	if selected_index > #filtered_commands then
		return filtered_commands, #filtered_commands
	end
	return filtered_commands, selected_index
end

return M
