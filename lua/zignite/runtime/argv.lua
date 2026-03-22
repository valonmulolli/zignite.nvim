local state = require("zignite.runtime.state")
local utils = require("zignite.utils")

---@type table
local M = {}

---@param command string
---@return boolean
local function has_unsupported_shell_syntax(command)
	if type(command) ~= "string" or command == "" then
		return true
	end

	local quote = nil
	local index = 1
	while index <= #command do
		local ch = command:sub(index, index)
		if ch:find("[%c]") then
			return true
		end

		if quote then
			if ch == quote then
				quote = nil
			elseif ch == "\\" and quote == '"' and index < #command then
				index = index + 1
			end
		else
			if ch == "'" or ch == '"' then
				quote = ch
			elseif ch == "`" or ch == "|" or ch == ";" or ch == "<" or ch == ">" or ch == "&" then
				return true
			elseif ch == "$" and command:sub(index + 1, index + 1) == "(" then
				return true
			elseif ch == "\\" and index < #command then
				index = index + 1
			end
		end
		index = index + 1
	end

	if quote then
		return true
	end
	return false
end

---@param command string
---@return boolean
local function has_unresolved_placeholders(command)
	local quote = nil
	local index = 1
	while index <= #command do
		local ch = command:sub(index, index)
		if quote then
			if ch == quote then
				quote = nil
			elseif ch == "\\" and quote == '"' and index < #command then
				index = index + 1
			elseif quote == '"' and ch == "$" then
				local next_char = command:sub(index + 1, index + 1)
				if next_char == "(" or next_char == "{" or next_char:match("[%w_]") then
					return true
				end
			end
		else
			if ch == "'" or ch == '"' then
				quote = ch
			elseif ch == "\\" and index < #command then
				index = index + 1
			elseif ch == "$" then
				local next_char = command:sub(index + 1, index + 1)
				if next_char == "(" or next_char == "{" or next_char:match("[%w_]") then
					return true
				end
			end
		end
		index = index + 1
	end
	return quote ~= nil
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

	if has_unsupported_shell_syntax(command_template) then
		state.set_argv_cache(key, { ok = false })
		return nil
	end

	local expanded_command = utils.substitute_variables_raw(command_template, filepath)
	if has_unresolved_placeholders(expanded_command) then
		state.set_argv_cache(key, { ok = false })
		return nil
	end

	local tokens = tokenize_command(expanded_command)
	if not tokens or #tokens == 0 then
		state.set_argv_cache(key, { ok = false })
		return nil
	end

	state.set_argv_cache(key, { ok = true, argv = state.copy_list(tokens) })
	return tokens
end

return M
