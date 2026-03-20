local config = require("zignite.config")
local state = require("zignite.runtime.state")

---@type table
local M = {}

---@return boolean
local function has_zig_backend()
	local cached = state.get_zig_backend_available()
	if cached == nil then
		cached = vim.fn.executable(state.ZIG_EXECUTABLE) == 1
		state.set_zig_backend_available(cached)
	end
	return cached
end

---@return nil
local function notify_backend_missing_once()
	if state.get_zig_missing_notified() then
		return
	end
	state.set_zig_missing_notified(true)
	vim.notify(
		"Zignite executable not found at " .. state.ZIG_EXECUTABLE .. ", falling back to direct shell execution",
		vim.log.levels.INFO
	)
end

---@param final_command string|string[]
---@param argv_command string[]|nil
---@return string|string[]
function M.build_system_command(final_command, argv_command)
	if has_zig_backend() then
		---@type string[]
		local system_command = { state.ZIG_EXECUTABLE }
		if config.options.timeout and type(config.options.timeout) == "number" then
			system_command[#system_command + 1] = "--timeout=" .. config.options.timeout
		end
		if argv_command and #argv_command > 0 then
			system_command[#system_command + 1] = "--argv"
			for _, arg in ipairs(argv_command) do
				system_command[#system_command + 1] = arg
			end
		else
			system_command[#system_command + 1] = final_command
		end
		return system_command
	end

	notify_backend_missing_once()
	if argv_command and #argv_command > 0 then
		return argv_command
	end
	return final_command
end

return M
