local frame = require("zignite.ui.common")

---@type table
local M = {}

---@type table|nil
local spinner_timer = nil

---@type table<string, string[]>
local spinner_frames = {
	dots = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
	line = { "|", "/", "-", "\\" },
	bar = { " ", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" },
	arrows = { "←", "↖", "↑", "↗", "→", "↘", "↓", "↙" },
	triangle = { "◢", "◣", "◤", "◥" },
	square = { "◰", "◳", "◲", "◱" },
	circle = { "◐", "◓", "◑", "◒" },
}

---@param win_id integer
---@param base_title string
---@return nil
function M.start_title_spinner(win_id, base_title)
	local config = frame.get_config()
	if not config.enable_animations then
		pcall(vim.api.nvim_win_set_config, win_id, { title = " " .. base_title .. " " })
		return
	end

	M.stop_spinner()

	local frames = spinner_frames[config.spinner] or spinner_frames.dots
	local frame_index = 1
	local uv = vim.uv or vim.loop

	if not uv or type(uv.new_timer) ~= "function" then
		return
	end

	spinner_timer = uv.new_timer()
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

---@return nil
function M.stop_spinner()
	if spinner_timer then
		spinner_timer:stop()
		spinner_timer:close()
		spinner_timer = nil
	end
end

---@param win_id integer
---@param exit_code integer
---@return nil
function M.set_exit_status(win_id, exit_code)
	M.stop_spinner()
	if not vim.api.nvim_win_is_valid(win_id) then
		return
	end

	local success = exit_code == 0
	local icon = success and "✓" or "✗"
	local status_text = success and "Success" or "Error"
	local title = string.format(" %s %s (Code: %d) ", icon, status_text, exit_code)
	pcall(vim.api.nvim_win_set_config, win_id, { title = title })

	local float_config = frame.get_config().float
	local close_key = frame.format_key_for_display(float_config.close_key or "<Esc>")
	local footer = string.format(" %s: close ", close_key)
	pcall(vim.api.nvim_win_set_config, win_id, { footer = footer })

	local new_border_hl = success and (float_config.border_hl_success or "DiagnosticOk")
		or (float_config.border_hl_error or "DiagnosticError")
	pcall(vim.api.nvim_set_option_value, "winhl", "Normal:Normal,FloatBorder:" .. new_border_hl, { win = win_id })

	local buf = vim.api.nvim_win_get_buf(win_id)
	local line_count = vim.api.nvim_buf_line_count(buf)
	if line_count > 0 then
		pcall(vim.api.nvim_win_set_cursor, win_id, { line_count, 0 })
	end
end

return M
