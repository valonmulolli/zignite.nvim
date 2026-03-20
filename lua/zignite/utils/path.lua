---@type table
local M = {}

---@param root string
---@param name string
---@return string
function M.join_path(root, name)
	if vim.fs and type(vim.fs.joinpath) == "function" then
		return vim.fs.joinpath(root, name)
	end
	return tostring(root or "") .. "/" .. tostring(name or "")
end

---@param path string
---@return boolean
function M.file_exists(path)
	return type(vim.fn.filereadable) == "function" and vim.fn.filereadable(path) == 1
end

---@param path string
---@return string|nil
function M.read_text_file(path)
	if type(vim.fn.readfile) ~= "function" or not M.file_exists(path) then
		return nil
	end
	local lines = vim.fn.readfile(path)
	if type(lines) ~= "table" then
		return nil
	end
	return table.concat(lines, "\n")
end

---@param payload string
---@return table|nil
function M.decode_json_payload(payload)
	if type(payload) ~= "string" or payload == "" then
		return nil
	end
	if vim.json and type(vim.json.decode) == "function" then
		local ok, decoded = pcall(vim.json.decode, payload)
		if ok then
			return decoded
		end
	end
	if vim.fn and type(vim.fn.json_decode) == "function" then
		local ok, decoded = pcall(vim.fn.json_decode, payload)
		if ok then
			return decoded
		end
	end
	return nil
end

return M
