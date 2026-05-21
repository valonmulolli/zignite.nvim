---@type table
local M = {}

---@param value any
---@param allow_empty boolean|nil
---@return boolean
function M.contains_control_characters(value, allow_empty)
	if type(value) ~= "string" then
		return true
	end
	if not allow_empty and value == "" then
		return true
	end
	return value:find("[%c]") ~= nil
end

return M
