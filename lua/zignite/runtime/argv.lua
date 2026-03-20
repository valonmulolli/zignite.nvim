local state = require("zignite.runtime.state")
local utils = require("zignite.utils")

---@type table
local M = {}

---@param command string
---@return boolean
local function is_simple_command(command)
	if type(command) ~= "string" or command == "" then
		return false
	end
	if command:find("[%c]") or command:find("[|&;<>`]") then
		return false
	end
	if command:find("%$%(") then
		return false
	end
	return true
end

---@param command string
---@return string[]|nil
local function tokenize_command(command)
	---@type string[]
	local tokens = {}
	---@type string[]
	local current = {}
	local quote = nil
	local index = 1

	---@return nil
	local function push_current()
		if #current > 0 then
			tokens[#tokens + 1] = table.concat(current)
			current = {}
		end
	end

	while index <= #command do
		local ch = command:sub(index, index)
		if quote then
			if ch == quote then
				quote = nil
			elseif ch == "\\" and quote == '"' and index < #command then
				index = index + 1
				current[#current + 1] = command:sub(index, index)
			else
				current[#current + 1] = ch
			end
		else
			if ch == "'" or ch == '"' then
				quote = ch
			elseif ch:match("%s") then
				push_current()
			elseif ch == "\\" and index < #command then
				index = index + 1
				current[#current + 1] = command:sub(index, index)
			else
				current[#current + 1] = ch
			end
		end
		index = index + 1
	end

	if quote then
		return nil
	end

	push_current()
	return tokens
end

---@param command_template string
---@param filepath string
---@return string[]|nil
function M.command_to_argv(command_template, filepath)
	local key = tostring(command_template) .. "\0" .. tostring(filepath)
	local cached = state.get_argv_cache(key)
	if cached ~= nil then
		if cached.ok then
			return state.copy_list(cached.argv)
		end
		return nil
	end

	if not is_simple_command(command_template) then
		state.set_argv_cache(key, { ok = false })
		return nil
	end

	local tokens = tokenize_command(command_template)
	if not tokens or #tokens == 0 then
		state.set_argv_cache(key, { ok = false })
		return nil
	end

	for index, token in ipairs(tokens) do
		local expanded = utils.substitute_variables_raw(token, filepath)
		if expanded:find("%$[%w_]+") then
			state.set_argv_cache(key, { ok = false })
			return nil
		end
		tokens[index] = expanded
	end

	state.set_argv_cache(key, { ok = true, argv = state.copy_list(tokens) })
	return tokens
end

return M
