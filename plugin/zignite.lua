-- Prevent loading the plugin twice
if vim.g.loaded_zignite then
	return
end
vim.g.loaded_zignite = true

---@return table
local function zignite()
	return require("zignite.init")
end

-- Create the :RunCode user command for visual selection
vim.api.nvim_create_user_command("RunCode", function(opts)
	zignite().run_code(opts.range)
end, { range = true })

-- Create the :RunFile user command with optional mode
vim.api.nvim_create_user_command("RunFile", function(opts)
	local mode = nil
	if opts.fargs[1] then
		local valid_modes = { "float", "tab", "split", "vsplit" }
		if vim.tbl_contains(valid_modes, opts.fargs[1]) then
			mode = opts.fargs[1]
		else
			vim.notify(
				"Invalid mode: " .. opts.fargs[1] .. ". Valid modes: float, tab, split, vsplit",
				vim.log.levels.ERROR
			)
			return
		end
	end
	zignite().run_code(0, mode)
end, { nargs = "?" })

-- Create the :RunClose user command
vim.api.nvim_create_user_command("RunClose", function()
	zignite().close_runner()
end, {})

-- Create the :StopCode user command
vim.api.nvim_create_user_command("StopCode", function()
	zignite().stop_code()
end, {})

-- Create the :RunBuild user command for build commands
-- Usage: :RunBuild build, :RunBuild run, :RunBuild test, etc.
vim.api.nvim_create_user_command("RunBuild", function(opts)
	local command_name = opts.fargs[1]
	local mode = opts.fargs[2]

	if not command_name then
		vim.notify(
			"Usage: :RunBuild <command> [mode]\nExample: :RunBuild run, :RunBuild build, :RunBuild test",
			vim.log.levels.ERROR
		)
		return
	end

	if mode and not vim.tbl_contains({ "float", "tab", "split", "vsplit" }, mode) then
		vim.notify("Invalid mode: " .. mode .. ". Valid modes: float, tab, split, vsplit", vim.log.levels.ERROR)
		return
	end

	zignite().run_build_command(command_name, mode)
end, {
	nargs = "+",
	---@param ArgLead string
	---@param _CmdLine string
	---@param _CursorPos integer
	---@return string[]
	complete = function(ArgLead, _CmdLine, _CursorPos)
		local filetype = vim.bo.filetype
		local build_cmds = zignite().get_build_commands_for_completion(filetype)

		if not build_cmds or vim.tbl_isempty(build_cmds) then
			return {}
		end

		local commands = {}
		for cmd_name, _ in pairs(build_cmds) do
			if ArgLead == "" or cmd_name:sub(1, #ArgLead) == ArgLead then
				table.insert(commands, cmd_name)
			end
		end
		table.sort(commands)
		return commands
	end,
})

vim.api.nvim_create_user_command("RunBuildSelect", function(opts)
	local mode = opts.fargs[1]

	if mode and not vim.tbl_contains({ "float", "tab", "split", "vsplit" }, mode) then
		vim.notify("Invalid mode: " .. mode .. ". Valid modes: float, tab, split, vsplit", vim.log.levels.ERROR)
		return
	end

	zignite().select_build_command(mode)
end, { nargs = "?" })

vim.api.nvim_create_user_command("RunBuildLast", function(opts)
	local mode = opts.fargs[1]

	if mode and not vim.tbl_contains({ "float", "tab", "split", "vsplit" }, mode) then
		vim.notify("Invalid mode: " .. mode .. ". Valid modes: float, tab, split, vsplit", vim.log.levels.ERROR)
		return
	end

	zignite().run_last_build_command(mode)
end, { nargs = "?" })

vim.api.nvim_create_user_command("RunLive", function(opts)
	local mode = opts.fargs[1]

	if mode and not vim.tbl_contains({ "float", "tab", "split", "vsplit" }, mode) then
		vim.notify("Invalid mode: " .. mode .. ". Valid modes: float, tab, split, vsplit", vim.log.levels.ERROR)
		return
	end

	zignite().run_live(mode)
end, { nargs = "?" })
