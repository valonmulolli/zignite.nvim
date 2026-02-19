local config = require("zignite.config")
local ui = require("zignite.ui")
local utils = require("zignite.utils")

local M = {}

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
	RESERVED_ARGV = "Error: '--argv' is reserved for Zignite internals. Remove it from your runner/build command.",
}

local LIVE_COMMAND_PRIORITY = { "live", "dev", "watch", "serve", "start", "preview" }

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
local ZIG_EXECUTABLE = PLUGIN_PATH .. "/zig/zig-out/bin/zignite"

local zig_backend_available = nil
local zig_missing_notified = false
local argv_cache = {}
local argv_cache_order = {}
local ARGV_CACHE_MAX = 256
local normalized_runner_cache = {}
local normalized_runner_order = {}
local NORMALIZED_RUNNER_CACHE_MAX = 128
local last_build_command_by_filetype = {}

local function ensure_config()
	config.ensure()
end

local function has_zig_backend()
	if zig_backend_available == nil then
		zig_backend_available = vim.fn.executable(ZIG_EXECUTABLE) == 1
	end
	return zig_backend_available
end

local function notify_backend_missing_once()
	if zig_missing_notified then
		return
	end

	zig_missing_notified = true
	vim.notify(
		"Zignite executable not found at " .. ZIG_EXECUTABLE .. ", falling back to direct shell execution",
		vim.log.levels.INFO
	)
end

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

local function tokenize_command(command)
	local tokens = {}
	local current = {}
	local quote = nil
	local i = 1

	local function push_current()
		if #current > 0 then
			table.insert(tokens, table.concat(current))
			current = {}
		end
	end

	while i <= #command do
		local ch = command:sub(i, i)
		if quote then
			if ch == quote then
				quote = nil
			elseif ch == "\\" and quote == '"' and i < #command then
				i = i + 1
				table.insert(current, command:sub(i, i))
			else
				table.insert(current, ch)
			end
		else
			if ch == "'" or ch == '"' then
				quote = ch
			elseif ch:match("%s") then
				push_current()
			elseif ch == "\\" and i < #command then
				i = i + 1
				table.insert(current, command:sub(i, i))
			else
				table.insert(current, ch)
			end
		end

		i = i + 1
	end

	if quote then
		return nil
	end

	push_current()
	return tokens
end

local function argv_cache_key(command_template, filepath)
	return tostring(command_template) .. "\0" .. tostring(filepath)
end

local function cache_argv_result(key, value)
	if argv_cache[key] == nil then
		table.insert(argv_cache_order, key)
		if #argv_cache_order > ARGV_CACHE_MAX then
			local oldest = table.remove(argv_cache_order, 1)
			argv_cache[oldest] = nil
		end
	end

	argv_cache[key] = value
end

local function normalized_runner_cache_key(filetype, runner)
	return tostring(filetype) .. "\0" .. tostring(runner)
end

local function cache_normalized_runner(key, value)
	if normalized_runner_cache[key] == nil then
		table.insert(normalized_runner_order, key)
		if #normalized_runner_order > NORMALIZED_RUNNER_CACHE_MAX then
			local oldest = table.remove(normalized_runner_order, 1)
			normalized_runner_cache[oldest] = nil
		end
	end

	normalized_runner_cache[key] = value
end

local function get_normalized_runner_command(filetype, runner)
	local key = normalized_runner_cache_key(filetype, runner)
	local cached = normalized_runner_cache[key]
	if cached ~= nil then
		return cached
	end

	local normalized = utils.normalize_command(runner)
	cache_normalized_runner(key, normalized)
	return normalized
end

local function copy_list(list)
	local out = {}
	for i = 1, #list do
		out[i] = list[i]
	end
	return out
end

local function command_to_argv(command_template, filepath)
	local key = argv_cache_key(command_template, filepath)
	local cached = argv_cache[key]
	if cached ~= nil then
		if cached.ok then
			return copy_list(cached.argv)
		end
		return nil
	end

	if not is_simple_command(command_template) then
		cache_argv_result(key, { ok = false })
		return nil
	end

	local tokens = tokenize_command(command_template)
	if not tokens or #tokens == 0 then
		cache_argv_result(key, { ok = false })
		return nil
	end

	for idx, token in ipairs(tokens) do
		local expanded = utils.substitute_variables_raw(token, filepath)
		if expanded:find("%$[%w_]+") then
			cache_argv_result(key, { ok = false })
			return nil
		end
		tokens[idx] = expanded
	end

	cache_argv_result(key, { ok = true, argv = copy_list(tokens) })
	return tokens
end

local function build_system_command(final_command, argv_command)
	if has_zig_backend() then
		local system_command = { ZIG_EXECUTABLE }
		if config.options.timeout and type(config.options.timeout) == "number" then
			table.insert(system_command, "--timeout=" .. config.options.timeout)
		end
		if argv_command and #argv_command > 0 then
			table.insert(system_command, "--argv")
			for _, arg in ipairs(argv_command) do
				table.insert(system_command, arg)
			end
		else
			table.insert(system_command, final_command)
		end
		return system_command
	end

	notify_backend_missing_once()
	if argv_command and #argv_command > 0 then
		return argv_command
	end
	return final_command
end

local function is_reserved_argv_command(command)
	if type(command) ~= "string" then
		return false
	end

	local trimmed = command:match("^%s*(.-)%s*$") or ""
	return trimmed == "--argv" or trimmed:match("^%-%-argv%s+") ~= nil
end

local function select_live_command_name(build_cmds)
	for _, candidate in ipairs(LIVE_COMMAND_PRIORITY) do
		if build_cmds[candidate] then
			return candidate
		end
	end
	return nil
end

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
	ensure_config()

	local filepath = vim.fn.expand("%:p")
	local filetype = vim.bo.filetype

	-- 1. Detect project
	local project, _ = utils.detect_project(filepath, config.options.project)

	-- 2. Filetype runner
	local ft_runner = config.options.runners[filetype]

	-- 3. Priority Logic:
	-- Zig build-system projects should run through `zig build ...` even when
	-- editing files in subdirectories (src/, lib/, etc.).
	if filetype == "zig" and project and project.command then
		return project, "project"
	end

	-- A. RunFile should prioritize the filetype runner when available.
	-- Users can still run project commands explicitly via :RunProject.
	if ft_runner then
		return ft_runner, "filetype"
	end

	-- B. Fallback to project when no filetype runner exists.
	if project and project.command then
		return project, "project"
	end

	return nil, nil
end

-- Run code with specified mode
-- @param range: 0 for file execution, >0 for visual selection
-- @param mode: output mode ("float", "split", etc.)
function M.run_code(range, mode)
	ensure_config()

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
	local argv_command
	local command_cwd

	if source == "project" then
		command_str = runner.command
		display_name = runner.name
		command_cwd = utils.get_project_root(execution_path, config.options.project)
	else
		command_str = get_normalized_runner_command(filetype, runner)
		if type(runner) == "table" and runner.cleanup_command then
			cleanup_command = runner.cleanup_command
		end
		display_name = filetype
		command_cwd = nil
	end

	if is_reserved_argv_command(command_str) then
		ui.show_output(ERRORS.RESERVED_ARGV, mode)
		return
	end

	-- Substitute variables in command
	local final_command = utils.substitute_variables(command_str, execution_path)
	if source == "filetype" then
		argv_command = command_to_argv(command_str, execution_path)
	elseif source == "project" then
		argv_command = command_to_argv(command_str, execution_path)
	end

	-- Standalone Zig safeguard: if user configured a build-based runner but no
	-- build.zig exists, force single-file execution.
	if filetype == "zig" and source == "filetype" then
		local has_build_zig = vim.fn.filereadable(vim.fs.joinpath(vim.fn.fnamemodify(execution_path, ":h"), "build.zig")) == 1
		local uses_zig_build = final_command:match("zig%s+build") ~= nil
		if not has_build_zig and uses_zig_build then
			final_command = utils.substitute_variables("zig run $file", execution_path)
			argv_command = command_to_argv("zig run $file", execution_path)
		end
	end

	-- If it's a project command, navigate to project root
	if source == "project" then
		if not command_cwd then
			argv_command = nil
		end
	end

	local system_command = build_system_command(final_command, argv_command)

	M.execute_command(system_command, execution_path, range, mode, display_name, cleanup_command, {
		cwd = command_cwd,
	})
end

-- Execute command asynchronously using new UI
function M.execute_command(system_command, execution_path, range, mode, display_name, cleanup_command, exec_opts)
	ensure_config()

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
				cwd = exec_opts and exec_opts.cwd or nil,
				on_exit = function() end,
			})
		end
	end

	if mode == "float" then
		ui.run_in_float_terminal(system_command, on_exit, display_name, exec_opts)
	else
		ui.run_in_split_terminal(mode, system_command, on_exit, exec_opts)
	end
end

-- Run current project
function M.run_project(mode)
	ensure_config()

	local filepath = vim.fn.expand("%:p")
	local runner = utils.detect_project(filepath, config.options.project)
	if not runner then
		ui.show_output(ERRORS.PROJECT_NOT_FOUND, mode)
		return
	end

	if not runner.command then
		ui.show_output(string.format(ERRORS.PROJECT_NO_COMMAND, runner.name or "Unknown"), mode)
		return
	end

	local cwd = utils.get_project_root(filepath, config.options.project)
	local command = runner.command
	if is_reserved_argv_command(command) then
		ui.show_output(ERRORS.RESERVED_ARGV, mode)
		return
	end

	-- Substitute variables
	command = utils.substitute_variables(command, filepath)
	local argv_command = command_to_argv(runner.command, filepath)
	if not cwd then
		argv_command = nil
	end

	local system_command = build_system_command(command, argv_command)
	M.execute_command(system_command, filepath, 0, mode, runner.name or "Project", nil, { cwd = cwd })
end

function M.stop_code()
	-- Since UI handles process via terminal buffers, we delegate closing to UI
	ui.close_output(true)
	vim.notify("Runner stopped.", vim.log.levels.INFO)
end

-- Run a specific build command for the current filetype
-- @param command_name: Name of the command (e.g., "build", "run", "test")
-- @param mode: Output mode
function M.run_build_command(command_name, mode)
	ensure_config()

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

	if is_reserved_argv_command(command) then
		ui.show_output(ERRORS.RESERVED_ARGV, mode)
		return
	end

	-- Get project root (if in a project)
	local cwd = utils.get_project_root(filepath, config.options.project)
	if not cwd then
		cwd = vim.fn.fnamemodify(filepath, ":h")
	end

	-- Zig standalone support:
	-- `zig build run` requires a build.zig, so for plain single-file scripts
	-- we fallback to the file runner command (defaults to `zig run $file`).
	if filetype == "zig" and command_name == "run" then
		local has_build_zig = vim.fn.filereadable(vim.fs.joinpath(cwd, "build.zig")) == 1
		if not has_build_zig then
			local zig_runner = utils.normalize_command(config.options.runners.zig)
			if type(zig_runner) ~= "string" or zig_runner:match("zig%s+build") then
				zig_runner = "zig run $file"
			end
			if is_reserved_argv_command(zig_runner) then
				ui.show_output(ERRORS.RESERVED_ARGV, mode)
				return
			end
			local standalone_cmd = utils.substitute_variables(zig_runner, filepath)
			local standalone_dir = vim.fn.fnamemodify(filepath, ":h")
			local standalone_argv = command_to_argv(zig_runner, filepath)
			local system_command = build_system_command(standalone_cmd, standalone_argv)

			local display_name = "zig: run"
			M.execute_command(system_command, filepath, 0, mode, display_name, nil, {
				cwd = standalone_dir,
			})
			return
		end
	end

	-- Substitute variables using the current file path.
	command = utils.substitute_variables(command, filepath)
	local argv_command = command_to_argv(build_cmds[command_name], filepath)
	if not cwd then
		argv_command = nil
	end

	local system_command = build_system_command(command, argv_command)

	local display_name = string.format("%s: %s", filetype, command_name)
	last_build_command_by_filetype[filetype] = command_name
	M.execute_command(system_command, filepath, 0, mode, display_name, nil, { cwd = cwd })
end

-- Run a long-lived live/watch/dev command for the current filetype.
function M.run_live(mode)
	ensure_config()

	local filetype = vim.bo.filetype
	local build_cmds = config.options.build_commands[filetype]
	if not build_cmds then
		ui.show_output(string.format("No build commands configured for filetype: %s", filetype), mode)
		return
	end

	local command_name = select_live_command_name(build_cmds)
	if not command_name then
		ui.show_output(
			string.format(
				"No live/watch command found for %s. Add one of: %s",
				filetype,
				table.concat(LIVE_COMMAND_PRIORITY, ", ")
			),
			mode
		)
		return
	end

	M.run_build_command(command_name, mode)
end

-- Show a picker to select and run a build command
-- @param mode: Output mode
function M.select_build_command(mode)
	ensure_config()

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
	local all_commands = {}
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
			table.insert(all_commands, {
				name = cmd_name,
				command = cmd_string,
			})
		end
	end

	if #all_commands == 0 then
		vim.notify(
			string.format("No build commands available for %s in this project context", filetype),
			vim.log.levels.WARN
		)
		return
	end

	-- Sort by name
	table.sort(all_commands, function(a, b)
		return a.name < b.name
	end)

	-- Create custom bottom-aligned picker with visual selection
	local buf = vim.api.nvim_create_buf(false, true)
	local ns_id = vim.api.nvim_create_namespace("zignite_picker")
	local filter_query = ""
	local filtered_commands = {}
	local selected_index = 1
	local command_line_start = 2

	local function find_command_index(commands, command_name)
		for idx, cmd in ipairs(commands) do
			if cmd.name == command_name then
				return idx
			end
		end
		return nil
	end

	local function apply_filter()
		local query = filter_query:lower()
		filtered_commands = {}

		for _, cmd in ipairs(all_commands) do
			local name_match = cmd.name:lower():find(query, 1, true) ~= nil
			local command_match = cmd.command:lower():find(query, 1, true) ~= nil
			if query == "" or name_match or command_match then
				filtered_commands[#filtered_commands + 1] = cmd
			end
		end

		if #filtered_commands == 0 then
			selected_index = 0
		elseif selected_index < 1 then
			selected_index = 1
		elseif selected_index > #filtered_commands then
			selected_index = #filtered_commands
		end
	end

	local function format_command_preview(text)
		if #text <= 52 then
			return text
		end
		return string.sub(text, 1, 49) .. "..."
	end

	local function build_lines()
		local lines = {
			string.format(" Filter: %s ", filter_query ~= "" and filter_query or "(none)"),
		}

		if #filtered_commands == 0 then
			lines[#lines + 1] = "  (no commands match current filter)"
		else
			for _, cmd in ipairs(filtered_commands) do
				lines[#lines + 1] = string.format("  %-18s → %s", cmd.name, format_command_preview(cmd.command))
			end
		end

		lines[#lines + 1] = "j/k: navigate | Enter: select | /: filter | c: clear | r: repeat | Esc: cancel"
		local preview_text = "(none)"
		if #filtered_commands > 0 and selected_index >= 1 then
			preview_text = filtered_commands[selected_index].command
		end
		lines[#lines + 1] = " cmd: " .. preview_text
		return lines
	end

	apply_filter()

	local last_selected_name = last_build_command_by_filetype[filetype]
	if last_selected_name then
		local default_idx = find_command_index(filtered_commands, last_selected_name)
		if default_idx then
			selected_index = default_idx
		end
	end

	local lines = build_lines()

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })

	-- Calculate window size based on content and clamp to viewport
	local max_width = 0
	for _, line in ipairs(lines) do
		max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
	end
	local width_cap = math.max(40, math.floor(vim.o.columns * 0.75))
	local width = math.min(max_width + 4, width_cap)
	local height_cap = math.max(8, math.floor(vim.o.lines * 0.65))
	local height = math.min(#lines + 1, height_cap)

	-- Use user's float config style (bottom-aligned, right side)
	local float_config = config.options.float or {}
	local picker_config = config.options.picker or {}
	local preferred_row = math.floor(vim.o.lines * (float_config.y or 0.90)) - height
	local preferred_col = vim.o.columns - width - 2 -- Right side with 2 char padding
	local max_row = math.max(0, vim.o.lines - height)
	local max_col = math.max(0, vim.o.columns - width)
	local picker_focus = picker_config.focus ~= false
	local win_opts = {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(0, math.min(preferred_row, max_row)),
		col = math.max(0, math.min(preferred_col, max_col)),
		style = "minimal",
		border = float_config.border or "rounded",
		title = " " .. filetype .. " ",
		title_pos = "center",
	}

	local win = vim.api.nvim_open_win(buf, picker_focus, win_opts)

	-- Enable cursor line highlighting
	vim.api.nvim_set_option_value("cursorline", true, { win = win })
	vim.api.nvim_set_option_value("winhl", "Normal:Normal,FloatBorder:FloatBorder,CursorLine:Visual", { win = win })

	-- Function to update selection indicator
	local function render_picker()
		if not vim.api.nvim_win_is_valid(win) then
			return
		end

		local updated_lines = build_lines()
		vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, updated_lines)
		vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

		vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
		if #filtered_commands == 0 or selected_index < 1 then
			return
		end

		local cursor_line = command_line_start + selected_index - 1
		vim.api.nvim_win_set_cursor(win, { cursor_line, 0 })
		vim.api.nvim_buf_set_extmark(buf, ns_id, cursor_line - 1, 0, {
			virt_text = { { "▶ ", "Special" } },
			virt_text_pos = "overlay",
		})
	end

	local function move_selection(delta)
		if #filtered_commands == 0 then
			return
		end

		local new_index = selected_index + delta
		if new_index < 1 then
			new_index = 1
		elseif new_index > #filtered_commands then
			new_index = #filtered_commands
		end
		if new_index ~= selected_index then
			selected_index = new_index
		end
		render_picker()
	end

	local function open_filter_prompt()
		local function apply_input(input)
			if input == nil then
				return
			end
			filter_query = input
			apply_filter()
			render_picker()
		end

		if vim.ui and type(vim.ui.input) == "function" then
			vim.ui.input({
				prompt = "Build filter: ",
				default = filter_query,
			}, apply_input)
			return
		end

		if type(vim.fn.input) ~= "function" then
			vim.notify("Build filter prompt is unavailable in this environment", vim.log.levels.WARN)
			return
		end
		local entered = vim.fn.input("Build filter: ", filter_query)
		apply_input(entered)
	end

	-- Key mappings
	local function close_picker()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	local function select_command(index)
		local selected = filtered_commands[index]
		if not selected then
			return
		end
		close_picker()
		M.run_build_command(selected.name, mode)
	end

	local function run_last_selected()
		local command_name = last_build_command_by_filetype[filetype]
		if not command_name then
			vim.notify(string.format("No previous build command for filetype: %s", filetype), vim.log.levels.WARN)
			return
		end
		close_picker()
		M.run_build_command(command_name, mode)
	end

	-- Enhanced j/k navigation with boundary checking
	vim.keymap.set("n", "j", function()
		move_selection(1)
	end, { buffer = buf, nowait = true })

	vim.keymap.set("n", "k", function()
		move_selection(-1)
	end, { buffer = buf, nowait = true })

	-- Arrow keys support
	vim.keymap.set("n", "<Down>", function()
		move_selection(1)
	end, { buffer = buf, nowait = true })

	vim.keymap.set("n", "<Up>", function()
		move_selection(-1)
	end, { buffer = buf, nowait = true })

	-- Enter to select
	vim.keymap.set("n", "<CR>", function()
		if selected_index >= 1 and selected_index <= #filtered_commands then
			select_command(selected_index)
		end
	end, { buffer = buf, nowait = true })

	-- Map number keys (still works!)
	for i = 1, 9 do
		vim.keymap.set("n", tostring(i), function()
			select_command(i)
		end, { buffer = buf, nowait = true })
	end

	vim.keymap.set("n", "/", open_filter_prompt, { buffer = buf, nowait = true })
	vim.keymap.set("n", "c", function()
		filter_query = ""
		apply_filter()
		render_picker()
	end, { buffer = buf, nowait = true })
	vim.keymap.set("n", "r", run_last_selected, { buffer = buf, nowait = true })

	-- Map escape and q to close
	vim.keymap.set("n", "<Esc>", close_picker, { buffer = buf, nowait = true })
	vim.keymap.set("n", "q", close_picker, { buffer = buf, nowait = true })

	-- Show initial selection and preview
	render_picker()
end

function M.run_last_build_command(mode)
	ensure_config()

	local filetype = vim.bo.filetype
	local command_name = last_build_command_by_filetype[filetype]
	if not command_name then
		ui.show_output(string.format("No previous build command for filetype: %s", filetype), mode)
		return
	end

	M.run_build_command(command_name, mode)
end

function M.close_runner()
	ensure_config()
	local close_behavior = tostring(config.options.close_behavior or "stop"):lower()
	local should_stop = close_behavior ~= "hide"
	ui.close_output(should_stop)
	if not should_stop then
		vim.notify("Runner closed (hide mode). Use :StopCode to terminate active jobs.", vim.log.levels.INFO)
	end
end

function M.setup(opts)
	zig_backend_available = nil
	zig_missing_notified = false
	argv_cache = {}
	argv_cache_order = {}
	last_build_command_by_filetype = {}
	config.setup(opts)
	utils.clear_project_cache()
end

return M
