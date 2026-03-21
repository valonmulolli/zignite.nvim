local build = require("zignite.build")
local build_picker = require("zignite.build.picker")
local config = require("zignite.config")
local runtime = require("zignite.runtime")
local ui = require("zignite.ui")
local utils = require("zignite.utils")

---@type table
local M = {}

local ERRORS = {
	NO_FILE = "Error: No file path. Please save the buffer.",
	NO_RUNNER = "Error: No runner configured for filetype: %s",
	VISUAL_EMPTY = "Error: Visual selection is empty.",
	TEMP_WRITE_FAIL = "Error: Could not write to temporary file.",
	ZIG_EXT = "Error: Zig files must have .zig extension. Current file: %s",
	RESERVED_ARGV = "Error: '--argv' is reserved for Zignite internals. Remove it from your runner/build command.",
}

local table_unpack = unpack
if table_unpack == nil and type(table) == "table" then
	table_unpack = rawget(table, "unpack")
end

---@return nil
local function ensure_config()
	config.ensure()
end

---@param filepath string|nil
---@param requested_filetype string|nil
---@return string, string
local function resolve_source_context(filepath, requested_filetype)
	local source_path = filepath or vim.fn.expand("%:p")
	local filetype = runtime.resolve_supported_filetype(requested_filetype or vim.bo.filetype, source_path)
	return source_path, filetype
end

---@param requested_filetype string|nil
---@return string, string
local function resolve_current_source_context(requested_filetype)
	return resolve_source_context(vim.fn.expand("%:p"), requested_filetype or vim.bo.filetype)
end

---@param filepath string
---@return string
local function resolve_project_cwd(filepath)
	return utils.get_project_root(filepath, config.options.project) or vim.fn.fnamemodify(filepath, ":h")
end

---@param root string|nil
---@return boolean
local function has_build_zig(root)
	return type(root) == "string" and root ~= "" and vim.fn.filereadable(vim.fs.joinpath(root, "build.zig")) == 1
end

---@param filetype string
---@param filepath string
---@param runner string|string[]|table|nil
---@return string|string[]|table|nil
local function apply_smart_runner_defaults(filetype, filepath, runner)
	if type(runner) ~= "string" then
		return runner
	end

	if filetype == "python" then
		local default_runner = config.defaults.runners.python
		if runner ~= default_runner then
			return runner
		end
		if utils.detect_python_project_tool_fast(filepath, config.options.project) == "uv" then
			return "uv run python -u $file"
		end
		return runner
	end

	if filetype == "go" then
		local default_runner = config.defaults.runners.go
		if runner ~= default_runner then
			return runner
		end
		local project = utils.detect_project(filepath, config.options.project)
		if project and project.name == "Go Project" then
			return {
				cmd = "go run .",
				cwd = "$dir",
			}
		end
	end

	return runner
end

---@param source string|nil
---@param runner string|string[]|table
---@param filetype string
---@param buffer_path string
---@param execution_path string
---@return string, string|nil, string, string|nil
local function resolve_runner_execution(source, runner, filetype, buffer_path, execution_path)
	if source == "project" then
		return runner.command, nil, runner.name, resolve_project_cwd(buffer_path ~= "" and buffer_path or execution_path)
	end

	local cleanup_command
	local command_cwd
	if type(runner) == "table" and runner.cleanup_command then
		cleanup_command = runner.cleanup_command
	end
	if type(runner) == "table" and type(runner.cwd) == "string" and runner.cwd ~= "" then
		command_cwd = utils.substitute_variables_raw(runner.cwd, execution_path)
	end

	return runtime.get_normalized_runner_command(filetype, runner), cleanup_command, filetype, command_cwd
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
---@param command_name string
---@param build_cmds table<string, string>
---@param mode string
---@return nil
local function show_build_command_missing(filetype, command_name, build_cmds, mode)
	if vim.tbl_isempty(build_cmds) then
		ui.show_output(string.format("No build commands available for filetype: %s", filetype), mode)
		return
	end

	---@type string[]
	local available = {}
	for cmd_name, _ in pairs(build_cmds) do
		available[#available + 1] = cmd_name
	end
	table.sort(available)
	ui.show_output(
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
---@param command_template string
---@param mode string
---@param provided_args string|nil
---@return nil
local function execute_build_command(filetype, filepath, command_name, command_template, mode, provided_args)
	local resolved_template = runtime.resolve_command_arguments(
		filetype,
		command_name,
		command_template,
		mode,
		provided_args
	)
	if not resolved_template then
		return
	end

	local command = resolved_template
	if runtime.is_reserved_argv_command(command) then
		ui.show_output(ERRORS.RESERVED_ARGV, mode)
		return
	end

	local cwd = resolve_project_cwd(filepath)

	if filetype == "zig" and command_name == "run" then
		if not has_build_zig(cwd) then
			local zig_runner = utils.normalize_command(config.options.runners.zig)
			if type(zig_runner) ~= "string" or zig_runner:match("zig%s+build") then
				zig_runner = "zig run $file"
			end
			if runtime.is_reserved_argv_command(zig_runner) then
				ui.show_output(ERRORS.RESERVED_ARGV, mode)
				return
			end
			local standalone_cmd = utils.substitute_variables(zig_runner, filepath)
			local standalone_dir = vim.fn.fnamemodify(filepath, ":h")
			local standalone_argv = runtime.command_to_argv(zig_runner, filepath)
			local standalone_system_command = runtime.build_system_command(standalone_cmd, standalone_argv)
			M.execute_command(standalone_system_command, filepath, 0, mode, "zig: run", nil, {
				cwd = standalone_dir,
			})
			return
		end
	end

	command = utils.substitute_variables(command, filepath)
	local argv_command = runtime.command_to_argv(resolved_template, filepath)
	if not cwd then
		argv_command = nil
	end

	local system_command = runtime.build_system_command(command, argv_command)
	local display_name = string.format("%s: %s", filetype, command_name)
	build.set_last_build_command(filetype, command_name)
	M.execute_command(system_command, filepath, 0, mode, display_name, nil, { cwd = cwd })
end

---@param filepath string
---@param requested_filetype string
---@return string|string[]|table|nil, string|nil, string
function M.get_command(filepath, requested_filetype)
	ensure_config()

	local source_path, filetype = resolve_source_context(filepath, requested_filetype)
	local ft_runner = apply_smart_runner_defaults(filetype, source_path, config.options.runners[filetype])
	local legacy_project = utils.detect_project(source_path, config.options.project)

	if filetype == "zig" and legacy_project and legacy_project.command then
		local project = build.get_preferred_project_command(filetype, source_path)
		return project or legacy_project, "project", filetype
	end
	if ft_runner then
		return ft_runner, "filetype", filetype
	end

	local project = build.get_preferred_project_command(filetype, source_path)
	if project and project.command then
		return project, "project", filetype
	end
	if legacy_project and legacy_project.command then
		return legacy_project, "project", filetype
	end
	return nil, nil, filetype
end

---@param range integer
---@param mode string
---@return nil
function M.run_code(range, mode)
	ensure_config()

	local buffer_path, filetype = resolve_current_source_context()
	local execution_path
	local code_to_run

	if range > 0 then
		code_to_run = get_visual_selection()
		if code_to_run == "" then
			ui.show_output(ERRORS.VISUAL_EMPTY, mode)
			return
		end
		execution_path = runtime.build_temp_execution_path(buffer_path, filetype)
		local file = io.open(execution_path, "w")
		if file then
			local success, err = file:write(code_to_run)
			file:close()
			if not success then
				ui.show_output(ERRORS.TEMP_WRITE_FAIL .. ": " .. err, mode)
				return
			end
		else
			ui.show_output(ERRORS.TEMP_WRITE_FAIL, mode)
			return
		end
	else
		execution_path = buffer_path
		if execution_path == "" then
			ui.show_output(ERRORS.NO_FILE, mode)
			return
		end
	end

	local runner, source = M.get_command(buffer_path, vim.bo.filetype)
	if not runner then
		ui.show_output(string.format(ERRORS.NO_RUNNER, filetype), mode)
		return
	end

	if range == 0 and filetype == "zig" and vim.fn.fnamemodify(execution_path, ":e") ~= "zig" then
		ui.show_output(string.format(ERRORS.ZIG_EXT, execution_path), mode)
		return
	end

	local command_str, cleanup_command, display_name, command_cwd =
		resolve_runner_execution(source, runner, filetype, buffer_path, execution_path)

	if runtime.is_reserved_argv_command(command_str) then
		ui.show_output(ERRORS.RESERVED_ARGV, mode)
		return
	end

	local final_command = utils.substitute_variables(command_str, execution_path)
	local argv_command = runtime.command_to_argv(command_str, execution_path)

	if filetype == "zig" and source == "filetype" then
		local uses_zig_build = final_command:match("zig%s+build") ~= nil
		if not has_build_zig(vim.fn.fnamemodify(execution_path, ":h")) and uses_zig_build then
			final_command = utils.substitute_variables("zig run $file", execution_path)
			argv_command = runtime.command_to_argv("zig run $file", execution_path)
		end
	end

	if source == "project" and not command_cwd then
		argv_command = nil
	end

	local system_command = runtime.build_system_command(final_command, argv_command)
	M.execute_command(system_command, execution_path, range, mode, display_name, cleanup_command, {
		cwd = command_cwd,
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
			vim.fn.jobstart(utils.substitute_variables(cleanup_command, execution_path), {
				cwd = exec_opts and exec_opts.cwd or nil,
				on_exit = function()
				end,
			})
		end
	end

	if mode == "float" then
		ui.run_in_float_terminal(system_command, on_exit, display_name, exec_opts)
	else
		ui.run_in_split_terminal(mode, system_command, on_exit, exec_opts)
	end
end

---@return nil
function M.stop_code()
	ui.close_output(true)
	vim.notify("Runner stopped.", vim.log.levels.INFO)
end

---@param command_name string
---@param mode string
---@param provided_args string|nil
---@return nil
function M.run_build_command(command_name, mode, provided_args)
	ensure_config()

	local filepath, filetype = resolve_current_source_context()
	local settled = false

	---@param build_cmds table<string, string>
	---@return boolean
	local function try_run(build_cmds)
		if settled then
			return true
		end
		local command_template = build_cmds[command_name]
		if not command_template then
			return false
		end
		settled = true
		execute_build_command(filetype, filepath, command_name, command_template, mode, provided_args)
		return true
	end

	local build_cmds, refresh_started = build.get_build_commands_for_cached_lookup(
		filetype,
		filepath,
		function(updated_commands)
			if try_run(updated_commands) then
				return
			end
			if settled then
				return
			end
			settled = true
			show_build_command_missing(filetype, command_name, updated_commands, mode)
		end
	)

	if try_run(build_cmds) then
		return
	end
	if refresh_started then
		return
	end
	show_build_command_missing(filetype, command_name, build_cmds, mode)
end

---@param mode string
---@return nil
function M.run_live(mode)
	ensure_config()

	local filepath, filetype = resolve_current_source_context()
	local settled = false

	---@return nil
	local function show_missing_live()
		ui.show_output(
			string.format(
				"No live/watch command found for %s. Add one of: %s",
				filetype,
				table.concat({ "live", "dev", "watch", "serve", "start", "preview" }, ", ")
			),
			mode
		)
	end

	---@param build_cmds table<string, string>
	---@return boolean
	local function try_run_live(build_cmds)
		if settled then
			return true
		end
		if vim.tbl_isempty(build_cmds) then
			return false
		end
		local command_name = build.select_live_command_name_for_filetype(filetype, filepath, build_cmds)
		if not command_name then
			return false
		end
		settled = true
		M.run_build_command(command_name, mode)
		return true
	end

	local build_cmds, refresh_started = build.get_build_commands_for_cached_lookup(
		filetype,
		filepath,
		function(updated_commands)
			if try_run_live(updated_commands) then
				return
			end
			if settled then
				return
			end
			settled = true
			show_missing_live()
		end
	)

	if try_run_live(build_cmds) then
		return
	end
	if refresh_started then
		return
	end
	if vim.tbl_isempty(build_cmds) then
		ui.show_output(string.format("No build commands available for filetype: %s", filetype), mode)
		return
	end
	show_missing_live()
end

---@param mode string
---@return nil
function M.select_build_command(mode)
	ensure_config()

	local filepath, filetype = resolve_current_source_context()
	build_picker.open({
		filetype = filetype,
		filepath = filepath,
		mode = mode,
		config_options = config.options,
		command_for_display = runtime.command_for_display,
		get_detect_runtime_options = build.get_detect_runtime_options,
		get_build_commands_for_picker = build.get_build_commands_for_picker,
		can_detect_build_commands_for_filetype = build.can_detect_build_commands_for_filetype,
		run_build_command = M.run_build_command,
		get_last_build_command = build.get_last_build_command,
		command_requires_arguments = runtime.command_requires_arguments,
		get_command_argument_prompt = runtime.get_command_argument_prompt,
	})
end

---@param mode string
---@return nil
function M.run_last_build_command(mode)
	ensure_config()

	local _, filetype = resolve_current_source_context()
	local command_name = build.get_last_build_command(filetype)
	if not command_name then
		ui.show_output(string.format("No previous build command for filetype: %s", filetype), mode)
		return
	end
	M.run_build_command(command_name, mode)
end

---@param filetype string
---@return table<string, string>
function M.get_build_commands_for_filetype(filetype)
	ensure_config()
	local filepath, ft = resolve_current_source_context(filetype)
	return build.get_build_commands_for_filetype(ft, filepath)
end

---@param filetype string
---@return table<string, string>
function M.get_build_commands_for_completion(filetype)
	ensure_config()
	local filepath, ft = resolve_current_source_context(filetype)
	local build_cmds = build.get_build_commands_for_cached_lookup(ft, filepath, nil)
	return build_cmds
end

---@return nil
function M.close_runner()
	ensure_config()
	local close_behavior = tostring(config.options.close_behavior or "stop"):lower()
	local should_stop = close_behavior ~= "hide"
	ui.close_output(should_stop)
	if not should_stop then
		vim.notify("Runner closed (hide mode). Use :StopCode to terminate active jobs.", vim.log.levels.INFO)
	end
end

---@param opts table|nil
---@return nil
function M.setup(opts)
	runtime.reset()
	build.reset()
	ui.reset()
	config.setup(opts)
	utils.clear_project_cache()
end

return M
