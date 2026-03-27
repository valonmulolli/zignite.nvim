local build_resolve = require("zignite.backend.build_resolve")
local backend_client = require("zignite.backend.client")
local run_resolve = require("zignite.backend.run_resolve")
local picker_controller = require("zignite.build.picker.controller")
local config = require("zignite.config")
local ui_windows = require("zignite.ui.windows")

---@type table
local M = {}

local ERRORS = {
	NO_FILE = "Error: No file path. Please save the buffer.",
	NO_RUNNER = "Error: No runner configured for filetype: %s",
	VISUAL_EMPTY = "Error: Visual selection is empty.",
	TEMP_WRITE_FAIL = "Error: Could not write to temporary file.",
	ZIG_EXT = "Error: Zig files must have .zig extension. Current file: %s",
}

local TEMP_FILE_EXTENSION_MAP = {
	c = "c",
	cpp = "cpp",
	dart = "dart",
	elixir = "exs",
	fortran = "f90",
	go = "go",
	haskell = "hs",
	html = "html",
	java = "java",
	javascript = "js",
	json = "json",
	julia = "jl",
	kotlin = "kt",
	lua = "lua",
	odin = "odin",
	perl = "pl",
	php = "php",
	python = "py",
	r = "r",
	ruby = "rb",
	rust = "rs",
	sh = "sh",
	swift = "swift",
	typescript = "ts",
	zig = "zig",
	zsh = "zsh",
}

---@type table<string, string>
local last_build_commands = {}

local table_unpack = unpack
if table_unpack == nil and type(table) == "table" then
	table_unpack = rawget(table, "unpack")
end

---@param filetype string
---@return string|nil
local function get_last_build_command(filetype)
	return last_build_commands[filetype]
end

---@param filetype string
---@param command_name string
---@return nil
local function set_last_build_command(filetype, command_name)
	last_build_commands[filetype] = command_name
end

---@param filetype string
---@param filepath string
---@param on_refresh fun(result: table):nil|nil
---@return table
local function resolve_build_output(filetype, filepath, on_refresh)
	local resolved = build_resolve.resolve_sync(filepath, filetype)
	local output = type(resolved) == "table" and resolved or {}
	output.commands = type(output.commands) == "table" and output.commands or {}
	output.command_meta = type(output.command_meta) == "table" and output.command_meta or {}
	output.preferred_commands = type(output.preferred_commands) == "table" and output.preferred_commands or {}
	if type(on_refresh) == "function" then
		build_resolve.resolve_async(filepath, filetype, function(updated)
			local refreshed = type(updated) == "table" and updated or {}
			refreshed.commands = type(refreshed.commands) == "table" and refreshed.commands or {}
			refreshed.command_meta = type(refreshed.command_meta) == "table" and refreshed.command_meta or {}
			refreshed.preferred_commands = type(refreshed.preferred_commands) == "table" and refreshed.preferred_commands or {}
			on_refresh(refreshed)
		end)
	end
	return output
end

---@param filetype string
---@param filepath string
---@param on_refresh fun(result: table):nil|nil
---@return table
local function get_build_commands_for_picker(filetype, filepath, on_refresh)
	return resolve_build_output(filetype, filepath, on_refresh)
end

---@return nil
local function ensure_config()
	config.ensure()
end

---@param value string
---@return string
local function trim_text(value)
	if type(value) ~= "string" then
		return ""
	end
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param command_name string
---@param command_meta table|nil
---@param mode string
---@param provided_args string|nil
---@return string|false|nil
local function resolve_command_arguments(command_name, command_meta, mode, provided_args)
	if type(command_meta) ~= "table" or command_meta.requires_arguments ~= true then
		return nil
	end
	local prompt = tostring(command_meta.argument_prompt or (command_name .. " args"))
	if prompt == "" then
		return false
	end

	local entered = provided_args
	if entered == nil and type(vim.fn.input) ~= "function" then
		ui_windows.show_output(
			string.format("Command '%s' requires extra arguments, but input prompt is unavailable.", command_name),
			mode
		)
		return false
	end

	if entered == nil then
		entered = vim.fn.input(prompt .. ": ", "")
	end
	if entered == nil then
		return false
	end

	local trimmed = trim_text(entered)
	if trimmed == "" then
		ui_windows.show_output(string.format("Command '%s' requires an argument.", command_name), mode)
		return false
	end

	return trimmed
end

---@param filepath string
---@return string
local function get_file_extension(filepath)
	if type(filepath) ~= "string" or filepath == "" then
		return ""
	end
	local ext = vim.fn.fnamemodify(filepath, ":e")
	if type(ext) ~= "string" then
		return ""
	end
	return ext:lower()
end

---@param filepath string|nil
---@param requested_filetype string|nil
---@return string, string
local function resolve_source_context(filepath, requested_filetype)
	local source_path = filepath or vim.fn.expand("%:p")
	local filetype = trim_text(requested_filetype or vim.bo.filetype)
	return source_path, filetype
end

---@param requested_filetype string|nil
---@return string, string
local function resolve_current_source_context(requested_filetype)
	return resolve_source_context(vim.fn.expand("%:p"), requested_filetype or vim.bo.filetype)
end

---@param filepath string
---@param filetype string
---@return string
local function build_temp_execution_path(filepath, filetype)
	local temp_path
	if type(vim.fn.tempname) == "function" then
		temp_path = vim.fn.tempname()
	else
		temp_path = os.tmpname()
	end

	local ext = get_file_extension(filepath)
	if ext == "" then
		ext = TEMP_FILE_EXTENSION_MAP[filetype] or ""
	end
	if ext == "" then
		return temp_path
	end
	return temp_path .. "." .. ext
end

---@param filepath string
---@param filetype string
---@param context_path string|nil
---@return table|nil, string|nil, string
local function resolve_backend_runner(filepath, filetype, context_path)
	local resolved = run_resolve.resolve_sync(filepath, filetype, context_path)
	if type(resolved) ~= "table" or type(resolved.command) ~= "string" or resolved.command == "" then
		return nil, nil, filetype
	end
	local resolved_filetype = filetype
	if type(resolved.filetype) == "string" and resolved.filetype ~= "" then
		resolved_filetype = resolved.filetype
	end
	resolved.filetype = resolved_filetype
	if type(resolved.argv) ~= "table" or #resolved.argv == 0 then
		resolved.argv = nil
	end
	return resolved, resolved.source, resolved_filetype
end

---@return string
local function get_visual_selection()
	local _, start_line, start_col = table_unpack(vim.fn.getpos("'<"))
	local _, end_line, end_col = table_unpack(vim.fn.getpos("'>"))
	if start_line == 0 or end_line == 0 then
		return ""
	end
	return table.concat(vim.api.nvim_buf_get_text(0, start_line - 1, start_col, end_line - 1, end_col, {}), "\n")
end

---@param filetype string
---@param mode string
---@return nil
local function show_no_build_commands(filetype, mode)
	ui_windows.show_output(string.format("No build commands available for filetype: %s", filetype), mode)
end

---@param filetype string
---@param mode string
---@return nil
local function show_missing_live_command(filetype, mode)
	ui_windows.show_output(string.format("No live command resolved for %s.", filetype), mode)
end

---@param build_cmds table<string, string>
---@param preferred_command string|nil
---@return string|nil
local function resolve_preferred_command_name(build_cmds, preferred_command)
	if type(preferred_command) ~= "string" or preferred_command == "" then
		return nil
	end

	for command_name, command in pairs(build_cmds or {}) do
		if command == preferred_command then
			return command_name
		end
	end

	return nil
end

---@param execution_path string
---@param code_to_run string
---@return boolean, string|nil
local function write_temp_execution_file(execution_path, code_to_run)
	local file = io.open(execution_path, "w")
	if not file then
		return false, ERRORS.TEMP_WRITE_FAIL
	end

	local success, err = file:write(code_to_run)
	file:close()
	if not success then
		return false, ERRORS.TEMP_WRITE_FAIL .. ": " .. err
	end

	return true, nil
end

---@param range integer
---@param buffer_path string
---@param filetype string
---@param mode string
---@return string|nil
local function resolve_execution_path(range, buffer_path, filetype, mode)
	if range <= 0 then
		if buffer_path == "" then
			ui_windows.show_output(ERRORS.NO_FILE, mode)
			return nil
		end
		return buffer_path
	end

	local code_to_run = get_visual_selection()
	if code_to_run == "" then
		ui_windows.show_output(ERRORS.VISUAL_EMPTY, mode)
		return nil
	end

	local execution_path = build_temp_execution_path(buffer_path, filetype)
	local wrote_file, err = write_temp_execution_file(execution_path, code_to_run)
	if not wrote_file then
		ui_windows.show_output(err or ERRORS.TEMP_WRITE_FAIL, mode)
		return nil
	end

	return execution_path
end

---@param filetype string
---@param command_name string
---@param build_cmds table<string, string>
---@param mode string
---@return nil
local function show_build_command_missing(filetype, command_name, build_cmds, mode)
	if vim.tbl_isempty(build_cmds) then
		show_no_build_commands(filetype, mode)
		return
	end

	---@type string[]
	local available = {}
	for cmd_name, _ in pairs(build_cmds) do
		available[#available + 1] = cmd_name
	end
	table.sort(available)
	ui_windows.show_output(
		string.format(
			"Command '%s' not found for %s.\nAvailable commands: %s",
			command_name,
			filetype,
			table.concat(available, ", ")
		),
		mode
	)
end

---@param filetype string
---@param filepath string
---@param command_name string
---@param command_meta table|nil
---@param mode string
---@param provided_args string|nil
---@return nil
local function execute_build_command(filetype, filepath, command_name, command_meta, mode, provided_args)
	local command_args = resolve_command_arguments(command_name, command_meta, mode, provided_args)
	if command_args == false then
		return
	end

	local resolved = build_resolve.resolve_command_sync(filepath, filetype, command_name, command_args)
	if type(resolved) ~= "table" or type(resolved.exec_command) ~= "string" or resolved.exec_command == "" then
		ui_windows.show_output(
			string.format("Failed to resolve build command '%s' for %s.", command_name, filetype),
			mode
		)
		return
	end

	local cwd = resolved.cwd or vim.fn.fnamemodify(filepath, ":h")
	local system_command = backend_client.build_system_command(resolved.exec_command, nil)
	local display_name = resolved.name or command_name
	set_last_build_command(filetype, command_name)
	M.execute_command(system_command, filepath, 0, mode, display_name, nil, { cwd = cwd })
end

---@param filepath string
---@param requested_filetype string
---@return string|string[]|table|nil, string|nil, string
function M.get_command(filepath, requested_filetype)
	ensure_config()

	local source_path, filetype = resolve_source_context(filepath, requested_filetype)
	local backend_runner, backend_source, resolved_filetype = resolve_backend_runner(source_path, filetype, source_path)
	if backend_runner then
		return backend_runner, backend_source, resolved_filetype
	end
	return nil, nil, filetype
end

---@param range integer
---@param mode string
---@return nil
function M.run_code(range, mode)
	ensure_config()

	local buffer_path, filetype = resolve_current_source_context()
	local execution_path = resolve_execution_path(range, buffer_path, filetype, mode)
	if not execution_path then
		return
	end

	local runner, _, resolved_filetype = resolve_backend_runner(execution_path, filetype, buffer_path)
	if not runner then
		ui_windows.show_output(string.format(ERRORS.NO_RUNNER, resolved_filetype or filetype), mode)
		return
	end

	if range == 0 and (resolved_filetype or filetype) == "zig" and vim.fn.fnamemodify(execution_path, ":e") ~= "zig" then
		ui_windows.show_output(string.format(ERRORS.ZIG_EXT, execution_path), mode)
		return
	end

	local system_command = backend_client.build_system_command(runner.command, runner.argv)
	M.execute_command(system_command, execution_path, range, mode, runner.name, runner.cleanup_command, {
		cwd = runner.cwd,
	})
end

---@param system_command string|string[]
---@param execution_path string
---@param range integer
---@param mode string
---@param display_name string
---@param cleanup_command string|nil
---@param exec_opts table|nil
---@return nil
function M.execute_command(system_command, execution_path, range, mode, display_name, cleanup_command, exec_opts)
	ensure_config()
	mode = mode or config.options.mode or "float"

	---@return nil
	local function on_exit()
		if range > 0 and execution_path then
			os.remove(execution_path)
		end
		if cleanup_command then
			vim.fn.jobstart(cleanup_command, {
				cwd = exec_opts and exec_opts.cwd or nil,
				on_exit = function()
				end,
			})
		end
	end

	if mode == "float" then
		ui_windows.run_in_float_terminal(system_command, on_exit, display_name, exec_opts)
	else
		ui_windows.run_in_split_terminal(mode, system_command, on_exit, exec_opts)
	end
end

---@return nil
function M.stop_code()
	ui_windows.close_output(true)
	vim.notify("Runner stopped.", vim.log.levels.INFO)
end

---@param command_name string
---@param mode string
---@param provided_args string|nil
---@return nil
function M.run_build_command(command_name, mode, provided_args)
	ensure_config()

	local filepath, filetype = resolve_current_source_context()
	local resolved = resolve_build_output(filetype, filepath, nil)
	local build_cmds = resolved.commands or {}
	local command_template = build_cmds[command_name]
	if not command_template then
		show_build_command_missing(filetype, command_name, build_cmds, mode)
		return
	end
	execute_build_command(filetype, filepath, command_name, resolved.command_meta[command_name], mode, provided_args)
end

---@param mode string
---@return nil
function M.run_live(mode)
	ensure_config()

	local filepath, filetype = resolve_current_source_context()
	local resolved = resolve_build_output(filetype, filepath, nil)
	local build_cmds = resolved.commands or {}
	if vim.tbl_isempty(build_cmds) then
		show_no_build_commands(filetype, mode)
		return
	end
	local command_name = resolve_preferred_command_name(
		build_cmds,
		resolved and type(resolved.preferred_commands) == "table" and resolved.preferred_commands.live or nil
	)
	if not command_name then
		show_missing_live_command(filetype, mode)
		return
	end
	M.run_build_command(command_name, mode)
end

---@param mode string
---@return nil
function M.select_build_command(mode)
	ensure_config()

	local filepath, filetype = resolve_current_source_context()
	picker_controller.open({
		filetype = filetype,
		filepath = filepath,
		mode = mode,
		config_options = config.options,
		detect_runtime_opts = config.options.detect_runtime or {},
		get_build_commands_for_picker = get_build_commands_for_picker,
		run_build_command = M.run_build_command,
		get_last_build_command = get_last_build_command,
	})
end

---@param mode string
---@return nil
function M.run_last_build_command(mode)
	ensure_config()

	local _, filetype = resolve_current_source_context()
	local command_name = get_last_build_command(filetype)
	if not command_name then
		ui_windows.show_output(string.format("No previous build command for filetype: %s", filetype), mode)
		return
	end
	M.run_build_command(command_name, mode)
end

---@param filetype string
---@return table<string, string>
function M.get_build_commands_for_filetype(filetype)
	ensure_config()
	local filepath, ft = resolve_current_source_context(filetype)
	return resolve_build_output(ft, filepath, nil).commands
end

---@param filetype string
---@return table<string, string>
function M.get_build_commands_for_completion(filetype)
	ensure_config()
	local filepath, ft = resolve_current_source_context(filetype)
	return resolve_build_output(ft, filepath, nil).commands
end

---@return nil
function M.close_runner()
	ensure_config()
	local close_behavior = tostring(config.options.close_behavior or "stop"):lower()
	local should_stop = close_behavior ~= "hide"
	ui_windows.close_output(should_stop)
	if not should_stop then
		vim.notify("Runner closed (hide mode). Use :StopCode to terminate active jobs.", vim.log.levels.INFO)
	end
end

---@param opts table|nil
---@return nil
function M.setup(opts)
	ui_windows.reset()
	config.setup(opts)
	last_build_commands = {}
end

return M
