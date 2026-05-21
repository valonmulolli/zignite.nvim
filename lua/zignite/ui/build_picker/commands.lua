---@type table
local M = {}

---@param entries table[]|nil
---@return table[]
function M.normalize_command_entries(entries)
	if type(entries) ~= "table" then
		return {}
	end
	local normalized = {}
	for _, entry in ipairs(entries) do
		if type(entry) == "table" and type(entry.name) == "string" and type(entry.command) == "string" then
			normalized[#normalized + 1] = {
				name = entry.name,
				command = entry.command,
				display_command = type(entry.display_command) == "string" and entry.display_command or entry.command,
				requires_arguments = entry.requires_arguments == true,
				argument_prompt = type(entry.argument_prompt) == "string" and entry.argument_prompt or nil,
				argument_help = type(entry.argument_help) == "string" and entry.argument_help or nil,
				picker_section = type(entry.picker_section) == "string" and entry.picker_section or nil,
				picker_rank = tonumber(entry.picker_rank) or nil,
			}
		end
	end
	return normalized
end

---@param cmd table
---@return string
function M.command_section(cmd)
	return type(cmd) == "table" and type(cmd.picker_section) == "string" and cmd.picker_section or "other"
end

return M
