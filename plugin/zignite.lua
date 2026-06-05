-- Prevent loading the plugin twice
if vim.g.loaded_zignite then
	return
end
vim.g.loaded_zignite = true

local VALID_MODES = { "float", "tab", "split", "vsplit" }

---@return table
local function zignite()
	return require("zignite.init")
end

---@param mode string|nil
---@return string|nil
local function normalize_mode(mode)
	if mode and vim.tbl_contains(VALID_MODES, mode) then
		return mode
	end
	return nil
end

---@param mode string|nil
---@return string|nil
local function parse_mode(fargs, offset)
	local mode = fargs and fargs[offset or 1]
	if mode and vim.tbl_contains(VALID_MODES, mode) then
		return mode
	end
	return nil
end

---@param mode string
---@return nil
local function notify_invalid_mode(mode)
	vim.notify("Invalid mode: " .. mode .. ". Valid modes: float, tab, split, vsplit", vim.log.levels.ERROR)
end

---@return string[]
local function current_build_commands_for_completion()
	local config = require("zignite.config")
	local build_resolve = require("zignite.rpc.build_resolve")

	config.ensure()
	local filepath = vim.fn.expand("%:p")
	local filetype = tostring(vim.bo.filetype or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if type(filepath) ~= "string" or filepath == "" or filetype == "" then
		return {}
	end

	local resolved = build_resolve.resolve_sync(filepath, filetype)
	if type(resolved) ~= "table" or type(resolved.completion_names) ~= "table" then
		return {}
	end
	return resolved.completion_names
end

-- Create the :RunCode user command for visual selection
vim.api.nvim_create_user_command("RunCode", function(opts)
	local mode = normalize_mode(opts.fargs[1])
	if opts.fargs[1] and not mode then
		notify_invalid_mode(opts.fargs[1])
		return
	end
	zignite().run_code(opts.range, mode)
end, { range = true, nargs = "?" })

-- Create the :RunFile user command with optional mode
vim.api.nvim_create_user_command("RunFile", function(opts)
	local mode = normalize_mode(opts.fargs[1])
	if opts.fargs[1] and not mode then
		notify_invalid_mode(opts.fargs[1])
		return
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
	local mode = nil
	local args_start = 2

	if not command_name then
		vim.notify(
			"Usage: :RunBuild <command> [mode]\nExample: :RunBuild run, :RunBuild build, :RunBuild test",
			vim.log.levels.ERROR
		)
		return
	end

	mode = parse_mode(opts.fargs, 2)
	if opts.fargs[2] and not mode then
		args_start = 2
	elseif mode then
		args_start = 3
	end

	local provided_args = nil
	if #opts.fargs >= args_start then
		local tail = {}
		for index = args_start, #opts.fargs do
			tail[#tail + 1] = tostring(opts.fargs[index] or "")
		end
		if #tail > 0 then
			provided_args = table.concat(tail, " ")
		end
	end

	zignite().run_build_command(command_name, mode, provided_args)
end, {
	nargs = "+",
	---@param ArgLead string
	---@param _CmdLine string
	---@param _CursorPos integer
	---@return string[]
	complete = function(ArgLead, _CmdLine, _CursorPos)
		local build_cmds = current_build_commands_for_completion()

		if not build_cmds or vim.tbl_isempty(build_cmds) then
			return {}
		end

		local commands = {}
		for _, cmd_name in ipairs(build_cmds) do
			if ArgLead == "" or vim.startswith(cmd_name, ArgLead) then
				table.insert(commands, cmd_name)
			end
		end
		return commands
	end,
})

vim.api.nvim_create_user_command("RunBuildSelect", function(opts)
	local mode = normalize_mode(opts.fargs[1])
	if opts.fargs[1] and not mode then
		notify_invalid_mode(opts.fargs[1])
		return
	end

	zignite().select_build_command(mode)
end, { nargs = "?" })

vim.api.nvim_create_user_command("RunBuildLast", function(opts)
	local mode = normalize_mode(opts.fargs[1])
	if opts.fargs[1] and not mode then
		notify_invalid_mode(opts.fargs[1])
		return
	end

	zignite().run_last_build_command(mode)
end, { nargs = "?" })

vim.api.nvim_create_user_command("RunLive", function(opts)
	local mode = normalize_mode(opts.fargs[1])
	if opts.fargs[1] and not mode then
		notify_invalid_mode(opts.fargs[1])
		return
	end

	zignite().run_live(mode)
end, { nargs = "?" })

vim.api.nvim_create_autocmd("UIEnter", {
	group = vim.api.nvim_create_augroup("ZignitePreWarm", { clear = true }),
	callback = function()
		local ok, config_sync = pcall(require, "zignite.rpc.config_sync")
		if ok and type(config_sync.sync_current_async) == "function" then
			pcall(config_sync.sync_current_async)
		end
	end,
	once = true,
})
