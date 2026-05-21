---@type table
local M = {}

---@param lines string[]|nil
---@return table|nil
function M.decode(lines)
	local json_text = nil
	for _, raw_line in ipairs(lines or {}) do
		local line = tostring(raw_line or "")
		local payload = line:match("^RESULT_JSON\t(.+)$")
		if payload then
			json_text = payload
			break
		end
	end
	if type(json_text) ~= "string" or json_text == "" then
		return nil
	end

	local decode = vim.json and vim.json.decode or vim.fn.json_decode
	if type(decode) ~= "function" then
		return nil
	end

	local ok, decoded = pcall(decode, json_text)
	if not ok or type(decoded) ~= "table" then
		return nil
	end
	return decoded
end

return M
