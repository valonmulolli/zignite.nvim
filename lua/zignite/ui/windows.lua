local quickfix = require("zignite.ui.quickfix")
local registry = require("zignite.ui.registry")
local ui_common = require("zignite.ui.common")
local spinner = require("zignite.ui.spinner")

---@type table
local M = {}

---@param value string
---@return string
local function trim_text(value)
	if type(value) ~= "string" then
		return ""
	end
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param buf integer
---@param lines string[]
---@return nil
local function set_message_buffer(buf, lines)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
	pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = buf })
	pcall(vim.api.nvim_set_option_value, "bufhidden", "wipe", { buf = buf })
	pcall(vim.api.nvim_set_option_value, "buftype", "nofile", { buf = buf })
end

---@param win_id integer
---@return nil
local function close_message_window(win_id)
	registry.close_by_win_id(win_id, false)
end

---@param buf integer
---@param win integer
---@param close_key string
---@return nil
local function bind_message_close_keys(buf, win, close_key)
	vim.keymap.set("n", close_key, function()
		close_message_window(win)
	end, { buffer = buf, silent = true, nowait = true })
	vim.keymap.set("n", "q", function()
		close_message_window(win)
	end, { buffer = buf, silent = true, nowait = true })
end

---@param buf integer
---@param quickfix_opts table
---@param exit_code integer
---@return nil
local function populate_quickfix_on_error(buf, quickfix_opts, exit_code)
	if exit_code ~= 0 and vim.api.nvim_buf_is_valid(buf) then
		quickfix.populate_from_buffer(buf, quickfix_opts or {})
	end
end

---@param job_id any
---@return boolean
local function is_valid_job_id(job_id)
	return type(job_id) == "number" and job_id > 0
end

---@param buf integer
---@param command string|string[]
---@return nil
local function show_jobstart_failure(buf, command)
	set_message_buffer(buf, {
		"Error: Failed to start runner.",
		"Command: " .. ui_common.summarize_command(command),
	})
end

---@param tracked_runner table
---@param buf integer
---@param on_exit_cb fun(exit_code: integer):nil
---@param quickfix_opts table
---@param opts table|nil
---@return fun(_: any, exit_code: integer):nil
local function build_terminal_exit_handler(tracked_runner, buf, on_exit_cb, quickfix_opts, opts)
	return function(_, exit_code)
		tracked_runner.job_id = nil
		if opts and type(opts.after_exit) == "function" then
			opts.after_exit(exit_code)
		end
		populate_quickfix_on_error(buf, quickfix_opts, exit_code)
		if on_exit_cb then
			on_exit_cb(exit_code)
		end
	end
end

---@param win integer
---@param tracked_runner table
---@param float_config table
---@param exit_code integer
---@return nil
local function schedule_float_auto_close(win, tracked_runner, float_config, exit_code)
	if exit_code ~= 0 then
		return
	end

	local delay = tonumber(float_config.auto_close_success_ms)
	if not delay or delay <= 0 then
		return
	end

	vim.defer_fn(function()
		if tracked_runner.job_id ~= nil then
			return
		end
		if vim.api.nvim_win_is_valid(win) then
			registry.close_by_win_id(win, false)
		end
	end, delay)
end

---@param mode string
---@param buf integer
---@param term_config table
---@return integer|nil, integer, integer|nil
local function open_mode_window(mode, buf, term_config)
	local previous_win = vim.api.nvim_get_current_win()
	local previous_tab = nil
	if vim.api.nvim_get_current_tabpage then
		previous_tab = vim.api.nvim_get_current_tabpage()
	end

	local win = nil
	if mode == "tab" then
		vim.cmd("tabnew")
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
	elseif mode == "vsplit" then
		local side = term_config.position == "left" and "topleft" or "botright"
		vim.cmd(side .. " vsplit")
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
		vim.api.nvim_win_set_width(win, term_config.size)
	elseif mode == "split" then
		local row_side = term_config.position == "top" and "topleft" or "botright"
		vim.cmd(row_side .. " split")
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
		vim.api.nvim_win_set_height(win, term_config.size)
	end

	return win, previous_win, previous_tab
end

---@param mode string
---@param term_config table
---@param previous_win integer|nil
---@param previous_tab integer|nil
---@return nil
local function restore_focus_if_disabled(mode, term_config, previous_win, previous_tab)
	if term_config.focus ~= false then
		return
	end

	if mode == "tab" then
		local restored = false
		if previous_tab and vim.api.nvim_set_current_tabpage then
			restored = pcall(vim.api.nvim_set_current_tabpage, previous_tab)
		end
		if not restored then
			pcall(vim.cmd, "tabprevious")
		end
		return
	end

	if previous_win and vim.api.nvim_win_is_valid(previous_win) then
		pcall(vim.api.nvim_set_current_win, previous_win)
	end
end

---@param stop_jobs boolean|nil
---@return nil
function M.close_output(stop_jobs)
	spinner.stop_spinner()
	registry.close_all(ui_common.should_stop_on_close(stop_jobs))
end

---@param command_name string
---@param argument_prompt string|nil
---@param mode string|nil
---@param provided_args string|nil
---@param argument_help string|nil
---@return string|false|nil
function M.prompt_required_argument(command_name, argument_prompt, mode, provided_args, argument_help)
	local prompt = tostring(argument_prompt or (command_name .. " args"))
	if prompt == "" then
		return false
	end

	local entered = provided_args
	if entered == nil and type(vim.fn.input) ~= "function" then
		M.show_output(
			string.format(
				"Command '%s' requires extra arguments%s, but input prompt is unavailable.",
				command_name,
				type(argument_help) == "string" and argument_help ~= "" and (" (" .. argument_help .. ")") or ""
			),
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
		M.show_output(string.format("Command '%s' requires an argument.", command_name), mode)
		return false
	end

	return trimmed
end

---@param command string
---@param on_exit_cb fun(exit_code: integer):nil
---@param title_name string
---@param job_opts table|nil
---@return integer|nil, integer|nil, integer|nil
function M.run_in_float_terminal(command, on_exit_cb, title_name, job_opts)
	local config = ui_common.get_config()

	if config.singleton then
		M.close_output(nil)
	else
		registry.clean_invalid()
	end

	local buf = vim.api.nvim_create_buf(false, true)
	local opts = ui_common.get_float_config()
	local float_config = config.float
	local should_focus = float_config.focus ~= false
	local activity_title = ui_common.describe_command_activity(command, title_name)
	opts.title = " " .. activity_title .. " "
	opts.footer = ui_common.build_float_footer(float_config, should_focus, ui_common.summarize_command(command))

	local ok_win, win = pcall(vim.api.nvim_open_win, buf, should_focus, opts)
	if not ok_win then
		vim.api.nvim_buf_delete(buf, { force = true })
		return nil, nil, nil
	end
	local tracked_runner = registry.track(win, buf)

	vim.api.nvim_set_option_value("winhl", "Normal:Normal,FloatBorder:" .. float_config.border_hl, { win = win })

	local close_key = float_config.close_key or "<Esc>"
	---@return nil
	local function close_float_runner()
		registry.close_by_win_id(win, ui_common.should_stop_on_close(nil))
	end

	vim.keymap.set("n", close_key, close_float_runner, { buffer = buf, silent = true, nowait = true })
	vim.keymap.set("t", close_key, function()
		pcall(vim.cmd, "stopinsert")
		close_float_runner()
	end, { buffer = buf, silent = true, nowait = true })

	spinner.start_title_spinner(win, activity_title)

	local job_id = vim.fn.jobstart(command, {
		term = true,
		cwd = job_opts and job_opts.cwd or nil,
		on_exit = build_terminal_exit_handler(tracked_runner, buf, on_exit_cb, config.quickfix, {
			after_exit = function(exit_code)
				if vim.api.nvim_win_is_valid(win) then
					spinner.set_exit_status(win, exit_code)
					schedule_float_auto_close(win, tracked_runner, float_config, exit_code)
				end
			end,
		}),
	})
	tracked_runner.job_id = job_id
	if not is_valid_job_id(job_id) then
		tracked_runner.job_id = nil
		show_jobstart_failure(buf, command)
		if vim.api.nvim_win_is_valid(win) then
			spinner.set_exit_status(win, 127)
		else
			spinner.stop_spinner()
		end
		return nil, win, buf
	end

	if should_focus and float_config.startinsert ~= false then
		vim.cmd("startinsert")
	end

	return job_id, win, buf
end

---@param mode string
---@param command string
---@param on_exit_cb fun(exit_code: integer):nil
---@param job_opts table|nil
---@return nil
function M.run_in_split_terminal(mode, command, on_exit_cb, job_opts)
	local config_opts = ui_common.get_config()
	if config_opts.singleton then
		M.close_output(nil)
	end

	local term_config = config_opts.term
	local resolved_mode = ui_common.normalize_mode(mode)
	local buf = vim.api.nvim_create_buf(false, true)
	local win, previous_win, previous_tab = open_mode_window(resolved_mode, buf, term_config)
	if not win then
		vim.api.nvim_buf_delete(buf, { force = true })
		return
	end

	local tracked_runner = registry.track(win, buf)
	restore_focus_if_disabled(resolved_mode, term_config, previous_win, previous_tab)

	local job_id = vim.fn.jobstart(command, {
		term = true,
		cwd = job_opts and job_opts.cwd or nil,
		on_exit = build_terminal_exit_handler(tracked_runner, buf, on_exit_cb, config_opts.quickfix),
	})
	tracked_runner.job_id = job_id
	if not is_valid_job_id(job_id) then
		tracked_runner.job_id = nil
		show_jobstart_failure(buf, command)
		return
	end

	if term_config.startinsert and term_config.focus ~= false then
		vim.cmd("startinsert")
	end
end

---@param message string
---@param mode string|nil
---@return nil
function M.show_output(message, mode)
	local config = ui_common.get_config()
	if config.singleton then
		M.close_output(nil)
	end

	local text = type(message) == "string" and message or tostring(message)
	local level = text:match("^Error:") and vim.log.levels.ERROR or vim.log.levels.WARN
	local resolved_mode = ui_common.normalize_mode(mode)
	local lines = ui_common.split_text_lines(text)

	if resolved_mode == "float" then
		local buf = vim.api.nvim_create_buf(false, true)
		set_message_buffer(buf, lines)

		local opts = ui_common.get_float_config()
		local float_config = config.float
		local should_focus = float_config.focus ~= false
		opts.title = level == vim.log.levels.ERROR and " Zignite Error " or " Zignite Message "
		opts.footer = string.format(" %s: close ", ui_common.format_key_for_display(float_config.close_key or "<Esc>"))
		local ok_win, win = pcall(vim.api.nvim_open_win, buf, should_focus, opts)
		if not ok_win then
			vim.api.nvim_buf_delete(buf, { force = true })
			return
		end
		local border_hl = level == vim.log.levels.ERROR and (float_config.border_hl_error or "DiagnosticError")
			or (float_config.border_hl or "FloatBorder")
		vim.api.nvim_set_option_value("winhl", "Normal:Normal,FloatBorder:" .. border_hl, { win = win })
		registry.track(win, buf)

		local close_key = float_config.close_key or "<Esc>"
		bind_message_close_keys(buf, win, close_key)
		return
	end

	local term_config = config.term
	if level == vim.log.levels.ERROR and lines[1] and not lines[1]:match("^Error:") then
		table.insert(lines, 1, "Error: " .. lines[1])
	end
	local buf = vim.api.nvim_create_buf(false, true)
	set_message_buffer(buf, lines)
	local win, previous_win, previous_tab = open_mode_window(resolved_mode, buf, term_config)
	if not win then
		vim.api.nvim_buf_delete(buf, { force = true })
		vim.notify(text, level, { title = "Zignite" })
		return
	end

	registry.track(win, buf)
	restore_focus_if_disabled(resolved_mode, term_config, previous_win, previous_tab)
	bind_message_close_keys(buf, win, "<Esc>")
end

---@return nil
function M.reset()
	quickfix.reset()
end

return M
