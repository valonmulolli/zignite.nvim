local M = {}

-- Keep track of the last window / buffer to close it if a new run is triggered
local last_win_id = nil
local last_buf_id = nil
local spinner_timer = nil

-- Spinner frames
local spinner_frames = {
	dots = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
	line = { "|", "/", "-", "\\" },
	bar = { " ", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" },
	clock = { "🕐", "🕑", "🕒", "🕓", "🕔", "🕕", "🕖", "🕗", "🕘", "🕙", "🕚", "🕛" },
	arrows = { "←", "↖", "↑", "↗", "→", "↘", "↓", "↙" },
	triangle = { "◢", "◣", "◤", "◥" },
	square = { "◰", "◳", "◲", "◱" },
	circle = { "◐", "◓", "◑", "◒" },
}

-- Private: Get window config
local function get_float_config()
	local config = require("zignite.config").options.float
	local width = math.floor(vim.o.columns * config.width)
	local height = math.floor(vim.o.lines * config.height)
	local col = math.floor((vim.o.columns - width) * config.x)
	local row = math.floor((vim.o.lines - height) * config.y)

	return {
		relative = "editor",
		style = "minimal",
		width = width,
		height = height,
		col = col,
		row = row,
		border = config.border,
		title = " Zignite Runner ",
		title_pos = "center",
	}
end

-- Close existing runner output
function M.close_output()
	M.stop_spinner()
	if last_win_id and vim.api.nvim_win_is_valid(last_win_id) then
		vim.api.nvim_win_close(last_win_id, true)
	end
	if last_buf_id and vim.api.nvim_buf_is_valid(last_buf_id) then
		vim.api.nvim_buf_delete(last_buf_id, { force = true })
	end
	last_win_id = nil
	last_buf_id = nil
end

-- Start the spinner animation in the window title
function M.start_title_spinner(win_id, base_title)
	local config = require("zignite.config").options
	if not config.enable_animations then
		pcall(vim.api.nvim_win_set_config, win_id, { title = " " .. base_title .. " " })
		return
	end

	M.stop_spinner() -- Stop any existing

	local frames = spinner_frames[config.spinner] or spinner_frames.dots
	local frame_index = 1

	spinner_timer = vim.loop.new_timer()
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

function M.stop_spinner()
	if spinner_timer then
		spinner_timer:stop()
		spinner_timer:close()
		spinner_timer = nil
	end
end

-- Update title with exit code (Success/Error)
function M.set_exit_status(win_id, exit_code)
	M.stop_spinner()
	if not vim.api.nvim_win_is_valid(win_id) then return end

	-- Exit code 0 is success, anything else is error
	local icon = (exit_code == 0) and "✓" or "✗"
	
	-- Format: " ✓ Finished (Code: 0) "
	local title = string.format(" %s Finished (Code: %d) ", icon, exit_code)
	
	pcall(vim.api.nvim_win_set_config, win_id, { title = title })

	-- Optional: Scroll to bottom one last time
	local buf = vim.api.nvim_win_get_buf(win_id)
	local line_count = vim.api.nvim_buf_line_count(buf)
	pcall(vim.api.nvim_win_set_cursor, win_id, { line_count, 0 })
end

-- Main function to run command in interactive float
function M.run_in_float_terminal(command, on_exit_cb, title_name)
	M.close_output()

	-- Create buffer
	local buf = vim.api.nvim_create_buf(false, true)
	last_buf_id = buf

	-- Create window
	local opts = get_float_config()
	opts.title = " Preparing... "
	local float_config = require("zignite.config").options.float
	
	local win = vim.api.nvim_open_win(buf, true, opts)
	last_win_id = win

	-- Set highlights
	vim.api.nvim_win_set_option(win, "winhl", "Normal:Normal,FloatBorder:" .. float_config.border_hl)

	-- Keymaps to close
	local close_key = float_config.close_key or "<Esc>"
	vim.api.nvim_buf_set_keymap(buf, "n", close_key, ":close<CR>", { noremap = true, silent = true })
	-- Also allow closing from terminal mode
	-- Note: <C-\><C-n> escapes to normal mode
	vim.api.nvim_buf_set_keymap(buf, "t", close_key, "<C-\\><C-n>:close<CR>", { noremap = true, silent = true })

	-- Start Spinner
	M.start_title_spinner(win, "Running " .. (title_name or "Code"))

	-- Run Terminal
	local job_id = vim.fn.termopen(command, {
		on_exit = function(job_id, exit_code, event)
			-- Update title logic on exit
			if last_win_id and vim.api.nvim_win_is_valid(last_win_id) then
				M.set_exit_status(last_win_id, exit_code)
			end
			
			-- Populate Quickfix on Error
			if exit_code ~= 0 and vim.api.nvim_buf_is_valid(buf) then
				local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
				-- Strip ANSI codes for quickfix readability
				local clean_lines = {}
				for _, line in ipairs(lines) do
					table.insert(clean_lines, (line:gsub("\27%[[0-9;]*m", "")))
				end
				
				vim.schedule(function()
					-- We set the list but don't open it automatically to avoid annoyance
					vim.fn.setqflist({}, " ", { 
						title = "Zignite Output", 
						lines = clean_lines,
					})
				end)
			end

			if on_exit_cb then
				on_exit_cb(exit_code)
			end
		end,
	})

	-- Start Insert Mode if configured (crucial for interactivity)
	if float_config.startinsert ~= false then
		vim.cmd("startinsert")
	end

	return job_id, win, buf
end

-- Legacy support for split/tab execution
function M.run_in_split_terminal(mode, command, on_exit_cb)
	M.close_output() 
	
	local config = require("zignite.config").options.term
	local buf = vim.api.nvim_create_buf(false, true)
	last_buf_id = buf
	
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
	
	last_win_id = win

	local job_id = vim.fn.termopen(command, {
		on_exit = function(_, exit_code)
			if on_exit_cb then on_exit_cb(exit_code) end
		end
	})

	if config.startinsert then
		vim.cmd("startinsert")
	end
end

-- Stub for compatibility if needed
function M.show_spinner() end
function M.show_output() end
function M.update_output() end
function M.append_output() end
function M.update_output_with_exit_animation() end

return M
