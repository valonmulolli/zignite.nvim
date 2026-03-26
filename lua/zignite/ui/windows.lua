local quickfix = require("zignite.ui.quickfix")
local registry = require("zignite.ui.registry")
local frame = require("zignite.ui.frame")
local spinner = require("zignite.ui.spinner")

---@type table
local M = {}

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
	registry.close_all(frame.should_stop_on_close(stop_jobs))
end

---@param command string
---@param on_exit_cb fun(exit_code: integer):nil
---@param title_name string
---@param job_opts table|nil
---@return integer|nil, integer|nil, integer|nil
function M.run_in_float_terminal(command, on_exit_cb, title_name, job_opts)
	local config = frame.get_config()

	if config.singleton then
		M.close_output(true)
	else
		registry.clean_invalid()
	end

	local buf = vim.api.nvim_create_buf(false, true)
	local opts = frame.get_float_config()
	local float_config = config.float
	local should_focus = float_config.focus ~= false
	opts.title = " Preparing... "
	opts.footer = frame.build_float_footer(float_config, should_focus)

	local win = vim.api.nvim_open_win(buf, should_focus, opts)
	local tracked_runner = registry.track(win, buf)

	vim.api.nvim_set_option_value("winhl", "Normal:Normal,FloatBorder:" .. float_config.border_hl, { win = win })

	local close_key = float_config.close_key or "<Esc>"
	---@return nil
	local function close_float_runner()
		registry.close_by_win_id(win, frame.should_stop_on_close(nil))
	end

	vim.keymap.set("n", close_key, close_float_runner, { buffer = buf, silent = true, nowait = true })
	vim.keymap.set("t", close_key, function()
		pcall(vim.cmd, "stopinsert")
		close_float_runner()
	end, { buffer = buf, silent = true, nowait = true })

	spinner.start_title_spinner(win, "Running " .. (title_name or "Code"))

	local job_id = vim.fn.jobstart(command, {
		term = true,
		cwd = job_opts and job_opts.cwd or nil,
		on_exit = function(_, exit_code)
			tracked_runner.job_id = nil
			if vim.api.nvim_win_is_valid(win) then
				spinner.set_exit_status(win, exit_code)
			end
			if exit_code ~= 0 and vim.api.nvim_buf_is_valid(buf) then
				local qf = config.quickfix or {}
				quickfix.populate_from_buffer(buf, qf)
			end
			if on_exit_cb then
				on_exit_cb(exit_code)
			end
		end,
	})
	tracked_runner.job_id = job_id

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
	local config_opts = frame.get_config()
	if config_opts.singleton then
		M.close_output(true)
	end

	local term_config = config_opts.term
	local resolved_mode = frame.normalize_mode(mode)
	local buf = vim.api.nvim_create_buf(false, true)
	local win, previous_win, previous_tab = open_mode_window(resolved_mode, buf, term_config)
	if not win then
		return
	end

	local tracked_runner = registry.track(win, buf)
	restore_focus_if_disabled(resolved_mode, term_config, previous_win, previous_tab)

	local job_id = vim.fn.jobstart(command, {
		term = true,
		cwd = job_opts and job_opts.cwd or nil,
		on_exit = function(_, exit_code)
			tracked_runner.job_id = nil
			if exit_code ~= 0 and vim.api.nvim_buf_is_valid(buf) then
				local qf = config_opts.quickfix or {}
				quickfix.populate_from_buffer(buf, qf)
			end
			if on_exit_cb then
				on_exit_cb(exit_code)
			end
		end,
	})
	tracked_runner.job_id = job_id

	if term_config.startinsert and term_config.focus ~= false then
		vim.cmd("startinsert")
	end
end

---@param message string
---@param mode string|nil
---@return nil
function M.show_output(message, mode)
	local text = type(message) == "string" and message or tostring(message)
	local level = text:match("^Error:") and vim.log.levels.ERROR or vim.log.levels.WARN
	local config = frame.get_config()
	local resolved_mode = frame.normalize_mode(mode)
	local lines = frame.split_text_lines(text)

	---@param buf integer
	---@return nil
	local function set_message_buffer(buf)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
		vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
		vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	end

	---@param win_id integer
	---@return nil
	local function close_message_runner(win_id)
		registry.close_by_win_id(win_id, false)
	end

	if resolved_mode == "float" then
		local buf = vim.api.nvim_create_buf(false, true)
		set_message_buffer(buf)

		local opts = frame.get_float_config()
		local float_config = config.float
		local should_focus = float_config.focus ~= false
		opts.title = level == vim.log.levels.ERROR and " Zignite Error " or " Zignite Message "
		opts.footer = string.format(" %s: close ", frame.format_key_for_display(float_config.close_key or "<Esc>"))
		local win = vim.api.nvim_open_win(buf, should_focus, opts)
		local border_hl = level == vim.log.levels.ERROR and (float_config.border_hl_error or "DiagnosticError")
			or (float_config.border_hl or "FloatBorder")
		vim.api.nvim_set_option_value("winhl", "Normal:Normal,FloatBorder:" .. border_hl, { win = win })
		registry.track(win, buf)

		local close_key = float_config.close_key or "<Esc>"
		vim.keymap.set("n", close_key, function()
			close_message_runner(win)
		end, { buffer = buf, silent = true, nowait = true })
		vim.keymap.set("n", "q", function()
			close_message_runner(win)
		end, { buffer = buf, silent = true, nowait = true })
		return
	end

	local term_config = config.term
	local buf = vim.api.nvim_create_buf(false, true)
	set_message_buffer(buf)
	local win, previous_win, previous_tab = open_mode_window(resolved_mode, buf, term_config)
	if not win then
		vim.notify(text, level, { title = "Zignite" })
		return
	end

	registry.track(win, buf)
	restore_focus_if_disabled(resolved_mode, term_config, previous_win, previous_tab)
	vim.keymap.set("n", "<Esc>", function()
		close_message_runner(win)
	end, { buffer = buf, silent = true, nowait = true })
	vim.keymap.set("n", "q", function()
		close_message_runner(win)
	end, { buffer = buf, silent = true, nowait = true })
end

---@return nil
function M.reset()
	quickfix.reset()
end

return M
