local build = require("zignite.build.runtime_lookup")
local build_detect = require("zignite.build.detect")
local build_picker = require("zignite.build.picker")
local build_systems = require("zignite.build.system_runtime")
local config = require("zignite.config")
local runtime_argv = require("zignite.runtime.argv")
local runtime_backend = require("zignite.runtime.backend")
local runtime_command = require("zignite.runtime.command")
local runtime_filetype = require("zignite.runtime.filetype")
local runtime_state = require("zignite.runtime.state")
local ui_windows = require("zignite.ui.windows")
local command_utils = require("zignite.utils.command")
local package_utils = require("zignite.utils.package")
local project_utils = require("zignite.utils.project")

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

local LIVE_COMMAND_NAMES = { "live", "dev", "watch", "serve", "start", "preview" }

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
	local filetype = runtime_filetype.resolve_supported_filetype(requested_filetype or vim.bo.filetype, source_path)
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
	return project_utils.get_project_root(filepath, config.options.project) or vim.fn.fnamemodify(filepath, ":h")
end

---@param root string|nil
---@return boolean
local function has_build_zig(root)
	return type(root) == "string" and root ~= "" and vim.fn.filereadable(vim.fs.joinpath(root, "build.zig")) == 1
end

---@param filepath string
---@return boolean
local function uses_warmed_uv_python(filepath)
	local project_root = project_utils.get_project_root(filepath, config.options.project)
	local cached = build_systems.get_cached_system_query_result("python-root", filepath, project_root)
	return type(cached) == "table"
		and type(cached.commands) == "table"
		and type(cached.commands.run) == "string"
		and cached.commands.run:match("^uv run ") ~= nil
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
		local uses_uv = uses_warmed_uv_python(filepath)
			or package_utils.detect_python_project_tool_fast(filepath, config.options.project) == "uv"
		if uses_uv then
			return "uv run python -u $file"
		end
		return runner
	end

	if filetype == "go" then
		local default_runner = config.defaults.runners.go
		if runner ~= default_runner then
			return runner
		end
		local project = project_utils.detect_project(filepath, config.options.project)
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
		command_cwd = command_utils.substitute_variables_raw(runner.cwd, execution_path)
	end

	return runtime_command.get_normalized_runner_command(filetype, runner), cleanup_command, filetype, command_cwd
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
	ui_windows.show_output(
		string.format(
			"No live/watch command found for %s. Add one of: %s",
			filetype,
			table.concat(LIVE_COMMAND_NAMES, ", ")
		),
		mode
	)
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

	local execution_path = runtime_filetype.build_temp_execution_path(buffer_path, filetype)
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
---@param on_commands fun(build_cmds: table<string, string>): boolean
---@param on_missing fun(build_cmds: table<string, string>, refreshed: boolean): nil
---@return boolean
local function consume_cached_build_commands(filetype, filepath, on_commands, on_missing)
	local settled = false

	---@param build_cmds table<string, string>
	---@return boolean
	local function try_handle(build_cmds)
		if settled then
			return true
		end
		if on_commands(build_cmds) then
			settled = true
			return true
		end
		return false
	end

	local build_cmds, refresh_started = build.get_build_commands_for_cached_lookup(
		filetype,
		filepath,
		function(updated_commands)
			if try_handle(updated_commands) or settled then
				return
			end
			settled = true
			on_missing(updated_commands, true)
		end
	)

	if try_handle(build_cmds) then
		return true
	end
	if refresh_started then
		return false
	end
	if not settled then
		settled = true
		on_missing(build_cmds, false)
	end
	return false
end

---@param filetype string
---@param filepath string
---@param command_name string
---@param command_template string
---@param mode string
---@param provided_args string|nil
---@return nil
local function execute_build_command(filetype, filepath, command_name, command_template, mode, provided_args)
	local resolved_template = runtime_command.resolve_command_arguments(
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
	if runtime_command.is_reserved_argv_command(command) then
		ui_windows.show_output(ERRORS.RESERVED_ARGV, mode)
		return
	end

	local cwd = resolve_project_cwd(filepath)

	if filetype == "zig" and command_name == "run" then
		if not has_build_zig(cwd) then
			local zig_runner = command_utils.normalize_command(config.options.runners.zig)
			if type(zig_runner) ~= "string" or zig_runner:match("zig%s+build") then
				zig_runner = "zig run $file"
			end
			if runtime_command.is_reserved_argv_command(zig_runner) then
				ui_windows.show_output(ERRORS.RESERVED_ARGV, mode)
				return
			end
			local standalone_cmd = command_utils.substitute_variables(zig_runner, filepath)
			local standalone_dir = vim.fn.fnamemodify(filepath, ":h")
			local standalone_argv = runtime_argv.command_to_argv(zig_runner, filepath)
			local standalone_system_command = runtime_backend.build_system_command(standalone_cmd, standalone_argv)
			M.execute_command(standalone_system_command, filepath, 0, mode, "zig: run", nil, {
				cwd = standalone_dir,
			})
			return
		end
	end

	command = command_utils.substitute_variables(command, filepath)
	local argv_command = runtime_argv.command_to_argv(resolved_template, filepath)
	if not cwd then
		argv_command = nil
	end

	local system_command = runtime_backend.build_system_command(command, argv_command)
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
	local legacy_project = project_utils.detect_project(source_path, config.options.project)

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
	local execution_path = resolve_execution_path(range, buffer_path, filetype, mode)
	if not execution_path then
		return
	end

	local runner, source = M.get_command(buffer_path, vim.bo.filetype)
	if not runner then
		ui_windows.show_output(string.format(ERRORS.NO_RUNNER, filetype), mode)
		return
	end

	if range == 0 and filetype == "zig" and vim.fn.fnamemodify(execution_path, ":e") ~= "zig" then
		ui_windows.show_output(string.format(ERRORS.ZIG_EXT, execution_path), mode)
		return
	end

	local command_str, cleanup_command, display_name, command_cwd =
		resolve_runner_execution(source, runner, filetype, buffer_path, execution_path)

	if runtime_command.is_reserved_argv_command(command_str) then
		ui_windows.show_output(ERRORS.RESERVED_ARGV, mode)
		return
	end

	local final_command = command_utils.substitute_variables(command_str, execution_path)
	local argv_command = runtime_argv.command_to_argv(command_str, execution_path)

	if filetype == "zig" and source == "filetype" then
		local uses_zig_build = final_command:match("zig%s+build") ~= nil
		if not has_build_zig(vim.fn.fnamemodify(execution_path, ":h")) and uses_zig_build then
			final_command = command_utils.substitute_variables("zig run $file", execution_path)
			argv_command = runtime_argv.command_to_argv("zig run $file", execution_path)
		end
	end

	if source == "project" and not command_cwd then
		argv_command = nil
	end

	local system_command = runtime_backend.build_system_command(final_command, argv_command)
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
			vim.fn.jobstart(command_utils.substitute_variables(cleanup_command, execution_path), {
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

	---@param build_cmds table<string, string>
	---@return boolean
	local function try_run(build_cmds)
		local command_template = build_cmds[command_name]
		if not command_template then
			return false
		end
		execute_build_command(filetype, filepath, command_name, command_template, mode, provided_args)
		return true
	end

	consume_cached_build_commands(filetype, filepath, try_run, function(build_cmds)
		show_build_command_missing(filetype, command_name, build_cmds, mode)
	end)
end

---@param mode string
---@return nil
function M.run_live(mode)
	ensure_config()

	local filepath, filetype = resolve_current_source_context()

	---@param build_cmds table<string, string>
	---@return boolean
	local function try_run_live(build_cmds)
		if vim.tbl_isempty(build_cmds) then
			return false
		end
		local command_name = build.select_live_command_name_for_filetype(filetype, filepath, build_cmds)
		if not command_name then
			return false
		end
		M.run_build_command(command_name, mode)
		return true
	end

	consume_cached_build_commands(filetype, filepath, try_run_live, function(build_cmds, refreshed)
		if not refreshed and vim.tbl_isempty(build_cmds) then
			show_no_build_commands(filetype, mode)
			return
		end
		show_missing_live_command(filetype, mode)
	end)
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
		command_for_display = runtime_command.command_for_display,
		get_detect_runtime_options = build.get_detect_runtime_options,
		get_build_commands_for_picker = build.get_build_commands_for_picker,
		can_detect_build_commands_for_filetype = build.can_detect_build_commands_for_filetype,
		run_build_command = M.run_build_command,
		get_last_build_command = build.get_last_build_command,
		command_requires_arguments = runtime_command.command_requires_arguments,
		get_command_argument_prompt = runtime_command.get_command_argument_prompt,
	})
end

---@param mode string
---@return nil
function M.run_last_build_command(mode)
	ensure_config()

	local _, filetype = resolve_current_source_context()
	local command_name = build.get_last_build_command(filetype)
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
	ui_windows.close_output(should_stop)
	if not should_stop then
		vim.notify("Runner closed (hide mode). Use :StopCode to terminate active jobs.", vim.log.levels.INFO)
	end
end

---@param opts table|nil
---@return nil
function M.setup(opts)
	runtime_state.reset()
	build_detect.reset()
	build.reset()
	ui_windows.reset()
	config.setup(opts)
	project_utils.clear_project_cache()
end

return M
