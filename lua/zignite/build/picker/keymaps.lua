---@type table
local M = {}

---@param opts table
---@return nil
function M.bind(opts)
	vim.keymap.set("n", "j", function()
		opts.move_selection(1)
	end, { buffer = opts.buf, nowait = true })
	vim.keymap.set("n", "k", function()
		opts.move_selection(-1)
	end, { buffer = opts.buf, nowait = true })
	vim.keymap.set("n", "<Down>", function()
		opts.move_selection(1)
	end, { buffer = opts.buf, nowait = true })
	vim.keymap.set("n", "<Up>", function()
		opts.move_selection(-1)
	end, { buffer = opts.buf, nowait = true })
	vim.keymap.set("n", "<CR>", function()
		if opts.selected_index() >= 1 and opts.selected_index() <= #opts.filtered_commands() then
			opts.select_command(opts.selected_index())
		end
	end, { buffer = opts.buf, nowait = true })

	for index = 1, 9 do
		vim.keymap.set("n", tostring(index), function()
			opts.select_command(index)
		end, { buffer = opts.buf, nowait = true })
	end

	vim.keymap.set("n", "/", opts.open_filter_prompt, { buffer = opts.buf, nowait = true })
	vim.keymap.set("n", "c", function()
		opts.clear_filter()
	end, { buffer = opts.buf, nowait = true })
	vim.keymap.set("n", "r", opts.run_last_selected, { buffer = opts.buf, nowait = true })
	vim.keymap.set("n", "<Esc>", opts.close_picker, { buffer = opts.buf, nowait = true })
	vim.keymap.set("n", "q", opts.close_picker, { buffer = opts.buf, nowait = true })
end

return M
