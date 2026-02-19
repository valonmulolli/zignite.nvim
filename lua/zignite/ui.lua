local M = {}

-- Keep track of runner windows
-- If singleton = true, this will only ever have 1 item
local runners = {}
local spinner_timer = nil

local function get_config()
	local cfg = require("zignite.config")
	cfg.ensure()
	return cfg.options
end

local function format_key_for_display(key)
	local text = tostring(key or "")
	text = text:gsub("^<", ""):gsub(">$", "")
	if text == "" then
		return "Esc"
	end
	return text
end

local function build_float_footer(float_config, should_focus)
	local close_key = format_key_for_display(float_config.close_key or "<Esc>")
	local input_hint
	if not should_focus then
		input_hint = "focus disabled"
	elseif float_config.startinsert ~= false then
		input_hint = "input ready"
	else
		input_hint = "press i for input"
	end
	return string.format(" %s: close | %s ", close_key, input_hint)
end

local function set_quickfix_lines(lines)
	vim.schedule(function()
		vim.fn.setqflist({}, " ", {
			title = "Zignite Output",
			lines = lines,
		})
	end)
end

local function populate_quickfix_from_buffer(buf, quickfix_opts)
	if quickfix_opts.enabled == false or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local max_lines = tonumber(quickfix_opts.max_lines) or 1000
	if max_lines < 1 then
		max_lines = 1
	end

	local total_lines = vim.api.nvim_buf_line_count(buf)
	local start_line = math.max(0, total_lines - max_lines)
	local lines = vim.api.nvim_buf_get_lines(buf, start_line, -1, false)
	if quickfix_opts.strip_ansi == false then
		set_quickfix_lines(lines)
		return
	end

	local chunk_size = tonumber(quickfix_opts.strip_chunk_size) or 200
	if chunk_size < 1 then
		chunk_size = 1
	end

	local idx = 1
	local function strip_next_chunk()
		local upper = math.min(#lines, idx + chunk_size - 1)
		for i = idx, upper do
			if lines[i]:find("\27", 1, true) then
				lines[i] = lines[i]:gsub("\27%[[0-9;]*m", "")
			end
		end
		idx = upper + 1

		if idx <= #lines and quickfix_opts.async_strip ~= false then
			vim.schedule(strip_next_chunk)
			return
		end

		if idx <= #lines then
			strip_next_chunk()
			return
		end

		set_quickfix_lines(lines)
	end

	strip_next_chunk()
end

-- Helper to track a new runner
local function track_runner(win_id, buf_id)
	local runner = { win_id = win_id, buf_id = buf_id, job_id = nil }
	table.insert(runners, runner)
	return runner
end

-- Helper to remove invalid runners from tracking
local function clean_tracked_runners()
	local valid = {}
	for _, runner in ipairs(runners) do
		if vim.api.nvim_win_is_valid(runner.win_id) then
			table.insert(valid, runner)
		end
	end
	runners = valid
end

local function stop_tracked_jobs()
	if type(vim.fn.jobstop) ~= "function" then
		return
	end

	for _, runner in ipairs(runners) do
		local job_id = runner.job_id
		if type(job_id) == "number" and job_id > 0 then
			pcall(vim.fn.jobstop, job_id)
		end
	end
end

-- Spinner frames
local spinner_frames = {
	dots = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
	line = { "|", "/", "-", "\\" },
	bar = { " ", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" },
	arrows = { "←", "↖", "↑", "↗", "→", "↘", "↓", "↙" },
	triangle = { "◢", "◣", "◤", "◥" },
	square = { "◰", "◳", "◲", "◱" },
	circle = { "◐", "◓", "◑", "◒" },
}

-- Private: Get window config
local function get_float_config()
	local float_config = get_config().float
	local width = math.floor(vim.o.columns * float_config.width)
	local height = math.floor(vim.o.lines * float_config.height)
	local col = math.floor((vim.o.columns - width) * float_config.x)
	local row = math.floor((vim.o.lines - height) * float_config.y)

	return {
		relative = "editor",
		style = "minimal",
		width = width,
		height = height,
		col = col,
		row = row,
		border = float_config.border,
		title = " Zignite Runner ",
		title_pos = "center",
		footer = "",
		footer_pos = "right",
	}
end

-- Close existing runner output(s)
function M.close_output(stop_jobs)
	M.stop_spinner()

	if stop_jobs then
		stop_tracked_jobs()
	end

	-- Close all tracked runners
	for _, runner in ipairs(runners) do
		if vim.api.nvim_win_is_valid(runner.win_id) then
			vim.api.nvim_win_close(runner.win_id, true)
		end
		if vim.api.nvim_buf_is_valid(runner.buf_id) then
			vim.api.nvim_buf_delete(runner.buf_id, { force = true })
		end
	end
	runners = {}
end

-- Start the spinner animation in the window title
function M.start_title_spinner(win_id, base_title)
	local config = get_config()
	if not config.enable_animations then
		pcall(vim.api.nvim_win_set_config, win_id, { title = " " .. base_title .. " " })
		return
	end

	M.stop_spinner() -- Stop any existing (LIMITATION: only 1 spinner at a time for now)

	local frames = spinner_frames[config.spinner] or spinner_frames.dots
	local frame_index = 1

	spinner_timer = vim.loop.new_timer()
	if spinner_timer then
		spinner_timer:start(
			0,
			config.spinner_speed or 80,
			vim.schedule_wrap(function()
				if not vim.api.nvim_win_is_valid(win_id) then
					M.stop_spinner()
					return
				end

				frame_index = frame_index + 1
				if frame_index > #frames then
					frame_index = 1
				end

				local icon = frames[frame_index]
				local new_title = string.format(" %s %s ", icon, base_title)

				pcall(vim.api.nvim_win_set_config, win_id, { title = new_title })
			end)
		)
	end
end

function M.stop_spinner()
	if spinner_timer then
		spinner_timer:stop()
		spinner_timer:close()
		spinner_timer = nil
	end
end

function M.set_exit_status(win_id, exit_code)
	-- Only stop spinner if it belongs to this window (heuristic)
	-- For now, stopping global spinner is safe enough
	M.stop_spinner()

	if not vim.api.nvim_win_is_valid(win_id) then return end

	local success = (exit_code == 0)
	local icon = success and "✓" or "✗"
	local status_text = success and "Success" or "Error"

	-- Update title
	local title = string.format(" %s %s (Code: %d) ", icon, status_text, exit_code)
	pcall(vim.api.nvim_win_set_config, win_id, { title = title })

	-- Update footer to show we are done
	local footer = string.format(" Process exited with %d ", exit_code)
	pcall(vim.api.nvim_win_set_config, win_id, { footer = footer })

	-- Update border highlight based on status
	local float_config = get_config().float
	local new_border_hl = success and (float_config.border_hl_success or "DiagnosticOk") or
		(float_config.border_hl_error or "DiagnosticError")

	-- We need to preserve the Normal highlight and only update FloatBorder
	pcall(vim.api.nvim_set_option_value, "winhl", "Normal:Normal,FloatBorder:" .. new_border_hl, { win = win_id })

	-- Optional: Scroll to bottom
	local buf = vim.api.nvim_win_get_buf(win_id)
	local line_count = vim.api.nvim_buf_line_count(buf)
	if line_count > 0 then
		pcall(vim.api.nvim_win_set_cursor, win_id, { line_count, 0 })
	end
end

-- Main function to run command in interactive float
function M.run_in_float_terminal(command, on_exit_cb, title_name, job_opts)
	local config = get_config()

	if config.singleton then
		M.close_output(true)
	else
		-- Clean up invalid runner handles
		clean_tracked_runners()
	end

	-- Create buffer
	local buf = vim.api.nvim_create_buf(false, true)

	-- Create window
	local opts = get_float_config()
	opts.title = " Preparing... "
	local float_config = config.float
	local should_focus = float_config.focus ~= false
	opts.footer = build_float_footer(float_config, should_focus)

	local win = vim.api.nvim_open_win(buf, should_focus, opts)

	-- Track this new runner
	local runner = track_runner(win, buf)

	-- Set highlights
	vim.api.nvim_set_option_value("winhl", "Normal:Normal,FloatBorder:" .. float_config.border_hl, { win = win })

	-- Keymaps to close
	local close_key = float_config.close_key or "<Esc>"
	vim.api.nvim_buf_set_keymap(buf, "n", close_key, ":close<CR>", { noremap = true, silent = true })
	-- Also allow closing from terminal mode
	-- Note: <C-\><C-n> escapes to normal mode
	vim.api.nvim_buf_set_keymap(buf, "t", close_key, "<C-\\><C-n>:close<CR>", { noremap = true, silent = true })

	-- Start Spinner (only animates the focused/latest one)
	M.start_title_spinner(win, "Running " .. (title_name or "Code"))

	-- Run Terminal
	local job_id = vim.fn.jobstart(command, {
		term = true,
		cwd = job_opts and job_opts.cwd or nil,
			on_exit = function(job_id, exit_code, event)
				-- Update title logic on exit for THIS specific window
				if vim.api.nvim_win_is_valid(win) then
					M.set_exit_status(win, exit_code)
				end

				-- Populate Quickfix on Error
				if exit_code ~= 0 and vim.api.nvim_buf_is_valid(buf) then
					local qf = config.quickfix or {}
					populate_quickfix_from_buffer(buf, qf)
				end

				if on_exit_cb then
					on_exit_cb(exit_code)
				end
		end,
	})
	runner.job_id = job_id

	-- Start Insert Mode if configured (crucial for interactivity)
	if should_focus and float_config.startinsert ~= false then
		vim.cmd("startinsert")
	end

	return job_id, win, buf
end

-- Legacy support for split/tab execution
function M.run_in_split_terminal(mode, command, on_exit_cb, job_opts)
	local config_opts = get_config()
	if config_opts.singleton then
		M.close_output(true)
	end

	local config = config_opts.term
	local buf = vim.api.nvim_create_buf(false, true)
	local previous_win = vim.api.nvim_get_current_win()
	local previous_tab = nil
	if vim.api.nvim_get_current_tabpage then
		previous_tab = vim.api.nvim_get_current_tabpage()
	end

	local win
	if mode == "tab" then
		vim.cmd("tabnew")
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
	elseif mode == "vsplit" then
		vim.cmd("vsplit")
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
	elseif mode == "split" then
		local position_cmd = config.position == "top" and "topleft" or "botright"
		vim.cmd(position_cmd .. " split")
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
		vim.api.nvim_win_set_height(win, config.size)
	end

	local runner = track_runner(win, buf)

	if config.focus == false then
		if mode == "tab" then
			local restored = false
			if previous_tab and vim.api.nvim_set_current_tabpage then
				restored = pcall(vim.api.nvim_set_current_tabpage, previous_tab)
			end
			if not restored then
				pcall(vim.cmd, "tabprevious")
			end
		elseif previous_win and vim.api.nvim_win_is_valid(previous_win) then
			pcall(vim.api.nvim_set_current_win, previous_win)
		end
	end

	local job_id = vim.fn.jobstart(command, {
		term = true,
		cwd = job_opts and job_opts.cwd or nil,
		on_exit = function(_, exit_code)
			if exit_code ~= 0 and vim.api.nvim_buf_is_valid(buf) then
				local qf = config_opts.quickfix or {}
				populate_quickfix_from_buffer(buf, qf)
			end
			if on_exit_cb then on_exit_cb(exit_code) end
		end
	})
	runner.job_id = job_id

	if config.startinsert and config.focus ~= false then
		vim.cmd("startinsert")
	end
end

-- Stub for compatibility if needed
function M.show_spinner() end

function M.show_output(message)
	local text = type(message) == "string" and message or tostring(message)
	local level = text:match("^Error:") and vim.log.levels.ERROR or vim.log.levels.WARN
	vim.notify(text, level, { title = "Zignite" })
end

function M.update_output() end

function M.append_output() end

function M.update_output_with_exit_animation() end

return M
