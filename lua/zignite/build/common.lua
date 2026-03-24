---@type table
local M = {}

---@param text string
---@return string
function M.normalize_path_text(text)
	if type(text) ~= "string" then
		return ""
	end
	return vim.fs.normalize(text):gsub("\\", "/")
end

---@param lines string[]|nil
---@return table<string, string>
function M.decode_backend_commands(lines)
	---@type table<string, string>
	local commands = {}
	for _, raw_line in ipairs(lines or {}) do
		local kind, name, command = tostring(raw_line or ""):match("^([^\t]+)\t([^\t]+)\t(.+)$")
		if kind == "COMMAND" and type(name) == "string" and name ~= "" and type(command) == "string" and command ~= "" then
			commands[name] = command
		end
	end
	return commands
end

return M
