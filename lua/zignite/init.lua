local config = require("zignite.config")
local ui = require("zignite.ui")
local utils = require("zignite.utils")

local M = {}

local current_job_id = nil

-- Constants for error messages
local ERRORS = {
	NO_FILE = "Error: No file path. Please save the buffer.",
	NO_RUNNER = "Error: No runner configured for filetype: %s",
	ZIG_MISSING = "Error: Zig executable not found at: %s\n\nPlease run: cd %s && zig build",
	INVALID_MODE = "Invalid mode: %s. Valid modes: float, tab, split, vsplit",
	VISUAL_EMPTY = "Error: Visual selection is empty.",
	TEMP_WRITE_FAIL = "Error: Could not write to temporary file.",
	PROJECT_NOT_FOUND = "Error: Current file is not part of any configured project.",
	PROJECT_NO_COMMAND = "Error: No command configured for project: %s",
	ZIG_EXT = "Error: Zig files must have .zig extension. Current file: %s",
}

-- Get the plugin directory path
local function get_plugin_path()
	local source = debug.getinfo(1, "S").source
	if source:sub(1, 1) == "@" then
		source = source:sub(2)
	end
	-- Ensure absolute path
	return vim.fn.fnamemodify(source, ":p:h:h:h")
end

local PLUGIN_PATH = get_plugin_path()

-- Helper function to get visual selection
local function get_visual_selection()
	local _, start_line, start_col, _ = table.unpack(vim.fn.getpos("'<"))
	local _, end_line, end_col, _ = table.unpack(vim.fn.getpos("'>"))
	if start_line == 0 or end_line == 0 then
		return ""
	end
	return table.concat(vim.api.nvim_buf_get_text(0, start_line - 1, start_col, end_line - 1, end_col, {}), "\n")
end

-- Get the command to run (from project or filetype)
-- Returns the runner config and source ("project" or "filetype")
function M.get_command()
	local filepath = vim.fn.expand("%:p")
	local filetype = vim.bo.filetype

	-- First check filetype runner (for single-file execution)
	local runner = config.options.runners[filetype]
	if runner then
		return runner, "filetype"
	end

	-- Fall back to project detection if no filetype runner
	local project = utils.detect_project(filepath, config.options.project)
	if project and project.command then
		return project, "project"
	end

	return nil, nil
end

-- Run code with specified mode
-- @param range: 0 for file execution, >0 for visual selection
-- @param mode: output mode ("float", "split", etc.)
function M.run_code(range, mode)
	local filetype = vim.bo.filetype
	local execution_path
	local code_to_run

	if range > 0 then -- Visual mode execution
		code_to_run = get_visual_selection()
		if code_to_run == "" then
			ui.show_output(ERRORS.VISUAL_EMPTY, mode)
			return
		end
		execution_path = vim.fn.tempname()
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
	else -- Normal file execution
		execution_path = vim.fn.expand("%:p")
		if execution_path == "" then
			ui.show_output(ERRORS.NO_FILE, mode)
			return
		end
	end

	-- Get command (project or filetype)
	local runner, source = M.get_command()

	if not runner then
		ui.show_output(string.format(ERRORS.NO_RUNNER, filetype), mode)
		return
	end

	-- Validate file extension for Zig
	if filetype == "zig" and vim.fn.fnamemodify(execution_path, ":e") ~= "zig" then
		ui.show_output(string.format(ERRORS.ZIG_EXT, execution_path), mode)
		return
	end

	local command_str
	local cleanup_command
	local display_name

	if source == "project" then
		command_str = runner.command
		display_name = runner.name
	else
		command_str = utils.normalize_command(runner)
		if type(runner) == "table" and runner.cleanup_command then
			cleanup_command = runner.cleanup_command
		end
		display_name = filetype
	end

	-- Substitute variables in command
	local final_command = utils.substitute_variables(command_str, execution_path)

	-- If it's a project command, navigate to project root
	if source == "project" then
		local cwd = utils.get_project_root(execution_path, config.options.project)
		if cwd then
			final_command = "cd " .. vim.fn.shellescape(cwd) .. " && " .. final_command
		end
	end

	-- Use the plugin's Zig executable wrapper, or fallback to direct shell
	local zig_executable = PLUGIN_PATH .. "/zig/zig-out/bin/zignite"
	local use_zig = vim.fn.executable(zig_executable) == 1

	if not use_zig then
		vim.notify(
			"Zignite executable not found at " .. zig_executable .. ", falling back to direct shell execution",
			vim.log.levels.INFO
		)
	end

	local system_command
	if use_zig then
		-- Use a list to avoid double shell escaping issues
		system_command = { zig_executable }

		-- Add timeout if configured
		if config.options.timeout and type(config.options.timeout) == "number" then
			table.insert(system_command, "--timeout=" .. config.options.timeout)
		end

		table.insert(system_command, final_command)
	else
		system_command = final_command
	end

	M.execute_command(system_command, execution_path, range, mode, display_name, cleanup_command)
end

-- Execute command asynchronously using new UI
function M.execute_command(system_command, execution_path, range, mode, display_name, cleanup_command)
	mode = mode or config.options.mode or "float"

	-- Callback to run cleanup tasks
	local function on_exit(exit_code)
		-- Clean up temporary file if created for visual selection
		if range > 0 and execution_path then
			os.remove(execution_path)
		end

		if cleanup_command then
			-- Run cleanup in background quietly
			vim.fn.jobstart(utils.substitute_variables(cleanup_command, execution_path), {
				on_exit = function() end,
			})
		end
	end

	if mode == "float" then
		ui.run_in_float_terminal(system_command, on_exit, display_name)
	else
		ui.run_in_split_terminal(mode, system_command, on_exit)
	end
end

-- Run current project
function M.run_project(mode)
	local runner, source = M.get_command()

	if not runner or source ~= "project" then
		ui.show_output(ERRORS.PROJECT_NOT_FOUND, mode)
		return
	end

	if not runner.command then
		ui.show_output(string.format(ERRORS.PROJECT_NO_COMMAND, runner.name or "Unknown"), mode)
		return
	end

	local filepath = vim.fn.expand("%:p")
	local cwd = utils.get_project_root(filepath, config.options.project)
	local command = runner.command

	if cwd then
		command = "cd " .. vim.fn.shellescape(cwd) .. " && " .. command
	end

	-- Substitute variables
	command = utils.substitute_variables(command, filepath)

	local zig_executable = PLUGIN_PATH .. "/zig/zig-out/bin/zignite"
	if vim.fn.executable(zig_executable) == 1 then
		command = zig_executable .. " " .. vim.fn.shellescape(command)
	end

	M.execute_command(command, filepath, 0, mode, runner.name or "Project")
end

function M.stop_code()
	-- Since UI handles process via terminal buffers, we delegate closing to UI
	ui.close_output()
	vim.notify("Runner stopped.", vim.log.levels.INFO)
end

-- Run a specific build command for the current filetype
-- @param command_name: Name of the command (e.g., "build", "run", "test")
-- @param mode: Output mode
function M.run_build_command(command_name, mode)
	local filetype = vim.bo.filetype
	local filepath = vim.fn.expand("%:p")

	-- Get build commands for this filetype
	local build_cmds = config.options.build_commands[filetype]
	if not build_cmds then
		ui.show_output(string.format("No build commands configured for filetype: %s", filetype), mode)
		return
	end

	-- Get the specific command
	local command = build_cmds[command_name]
	if not command then
		-- Show available commands
		local available = {}
		for cmd_name, _ in pairs(build_cmds) do
			table.insert(available, cmd_name)
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
		return
	end

	-- Get project root (if in a project)
	local cwd = utils.get_project_root(filepath, config.options.project)
	if not cwd then
		cwd = vim.fn.fnamemodify(filepath, ":h")
	end

	-- Substitute variables using project root for correct $projectName
	-- We create a dummy filepath pointing to the project root
	local project_filepath = cwd .. "/dummy.c"
	command = utils.substitute_variables(command, project_filepath)

	-- Prepend cd to project root
	local final_command = "cd " .. vim.fn.shellescape(cwd) .. " && " .. command

	-- Use Zig executable wrapper
	local zig_executable = PLUGIN_PATH .. "/zig/zig-out/bin/zignite"
	local system_command
	if vim.fn.executable(zig_executable) == 1 then
		system_command = { zig_executable }
		if config.options.timeout and type(config.options.timeout) == "number" then
			table.insert(system_command, "--timeout=" .. config.options.timeout)
		end
		table.insert(system_command, final_command)
	else
		system_command = final_command
	end

	local display_name = string.format("%s: %s", filetype, command_name)
	M.execute_command(system_command, filepath, 0, mode, display_name)
end

-- Show a picker to select and run a build command
-- @param mode: Output mode
function M.select_build_command(mode)
	local filetype = vim.bo.filetype

	-- Get build commands for this filetype
	local build_cmds = config.options.build_commands[filetype]
	if not build_cmds then
		vim.notify(string.format("No build commands configured for filetype: %s", filetype), vim.log.levels.WARN)
		return
	end

	-- Get project root to detect build system
	local filepath = vim.fn.expand("%:p")
	local root = utils.get_project_root(filepath, config.options.project)
	if not root then
		root = vim.fn.fnamemodify(filepath, ":h")
	end

	-- Detect build systems
	local has_cmake = vim.fn.filereadable(vim.fs.joinpath(root, "CMakeLists.txt")) == 1
	local has_meson = vim.fn.filereadable(vim.fs.joinpath(root, "meson.build")) == 1
	local has_makefile = vim.fn.filereadable(vim.fs.joinpath(root, "Makefile")) == 1

	-- Determine strict filtering mode
	local filtering = has_cmake or has_meson or has_makefile

	-- Create list of commands
	local commands = {}
	for cmd_name, cmd_string in pairs(build_cmds) do
		local include = true

		if filtering then
			if string.match(cmd_name, "^cmake%-") then
				include = has_cmake
			elseif string.match(cmd_name, "^meson%-") then
				include = has_meson
			else
				-- Assume standard commands (run, build, test) belong to Makefile / Generic
				include = has_makefile
			end
		end

		if include then
			table.insert(commands, {
				name = cmd_name,
				command = cmd_string,
			})
		end
	end

	-- Sort by name
	table.sort(commands, function(a, b)
		return a.name < b.name
	end)

	-- Create custom bottom-aligned picker with visual selection
	local buf = vim.api.nvim_create_buf(false, true)

	-- Prepare lines for display (compact, no empty lines)
	local lines = {}
	for _, cmd in ipairs(commands) do
		local display_cmd = cmd.command
		if #display_cmd > 50 then
			display_cmd = string.sub(display_cmd, 1, 47) .. "..."
		end
		table.insert(lines, string.format("  %-18s → %s", cmd.name, display_cmd))
	end
	table.insert(lines, "j/k: navigate | Enter: select | Esc: cancel")

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })

	-- Calculate window size based on content (more compact)
	local max_width = 0
	for _, line in ipairs(lines) do
		max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
	end
	local width = math.min(max_width + 4, math.floor(vim.o.columns * 0.5))
	local height = #lines + 1 -- Reduced padding

	-- Use user's float config style (bottom-aligned, right side)
	local float_config = config.options.float or {}
	local win_opts = {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor(vim.o.lines * (float_config.y or 0.90)) - height,
		col = vim.o.columns - width - 2, -- Right side with 2 char padding
		style = "minimal",
		border = float_config.border or "rounded",
		title = " " .. filetype .. " ",
		title_pos = "center",
	}

	local win = vim.api.nvim_open_win(buf, true, win_opts)

	-- Enable cursor line highlighting
	vim.api.nvim_set_option_value("cursorline", true, { win = win })
	vim.api.nvim_set_option_value("winhl", "Normal:Normal,FloatBorder:FloatBorder,CursorLine:Visual", { win = win })

	-- Namespace for virtual text
	local ns_id = vim.api.nvim_create_namespace("zignite_picker")

	-- Function to update selection indicator
	local function update_selection()
		-- Clear previous virtual text
		vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

		local cursor_line = vim.api.nvim_win_get_cursor(win)[1]

		-- Commands start at line 1 now (no header)
		if cursor_line >= 1 and cursor_line <= #commands then
			-- Add arrow indicator to current line
			vim.api.nvim_buf_set_extmark(buf, ns_id, cursor_line - 1, 0, {
				virt_text = { { "▶ ", "Special" } },
				virt_text_pos = "overlay",
			})
		end
	end

	-- Key mappings
	local function close_picker()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	local function select_command(index)
		close_picker()
		if commands[index] then
			M.run_build_command(commands[index].name, mode)
		end
	end

	-- Enhanced j/k navigation with boundary checking
	vim.keymap.set("n", "j", function()
		local cursor = vim.api.nvim_win_get_cursor(win)
		local line = cursor[1]
		local max_line = #commands -- Last command line
		if line < max_line then
			vim.api.nvim_win_set_cursor(win, { line + 1, 0 })
			update_selection()
		end
	end, { buffer = buf, nowait = true })

	vim.keymap.set("n", "k", function()
		local cursor = vim.api.nvim_win_get_cursor(win)
		local line = cursor[1]
		local min_line = 1 -- First command line
		if line > min_line then
			vim.api.nvim_win_set_cursor(win, { line - 1, 0 })
			update_selection()
		end
	end, { buffer = buf, nowait = true })

	-- Arrow keys support
	vim.keymap.set("n", "<Down>", function()
		local cursor = vim.api.nvim_win_get_cursor(win)
		local line = cursor[1]
		local max_line = #commands
		if line < max_line then
			vim.api.nvim_win_set_cursor(win, { line + 1, 0 })
			update_selection()
		end
	end, { buffer = buf, nowait = true })

	vim.keymap.set("n", "<Up>", function()
		local cursor = vim.api.nvim_win_get_cursor(win)
		local line = cursor[1]
		local min_line = 1
		if line > min_line then
			vim.api.nvim_win_set_cursor(win, { line - 1, 0 })
			update_selection()
		end
	end, { buffer = buf, nowait = true })

	-- Enter to select
	vim.keymap.set("n", "<CR>", function()
		local line = vim.api.nvim_win_get_cursor(win)[1]
		-- Line number is now the command index directly
		if line >= 1 and line <= #commands then
			select_command(line)
		end
	end, { buffer = buf, nowait = true })

	-- Map number keys (still works!)
	for i = 1, math.min(#commands, 9) do
		vim.keymap.set("n", tostring(i), function()
			select_command(i)
		end, { buffer = buf, nowait = true })
	end

	-- Map escape and q to close
	vim.keymap.set("n", "<Esc>", close_picker, { buffer = buf, nowait = true })
	vim.keymap.set("n", "q", close_picker, { buffer = buf, nowait = true })

	-- Start on first command and show initial selection
	vim.api.nvim_win_set_cursor(win, { 1, 0 })
	update_selection()
end

function M.close_runner()
	ui.close_output()
end

function M.setup(opts)
	config.setup(opts)
end

-- Initialize with defaults if not already set up
if vim.tbl_isempty(config.options) then
	config.setup()
end

return M
