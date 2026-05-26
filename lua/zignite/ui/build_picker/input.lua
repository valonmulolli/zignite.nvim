---@type table
local M = {}

local BUILD_ARG_DISPLAY_PLACEHOLDER = "<args>"

---@param display_command string
---@param value string|nil
---@return string
function M.command_for_argument_display(display_command, value)
	local replacement = value ~= nil and value ~= "" and value or BUILD_ARG_DISPLAY_PLACEHOLDER
	return tostring(display_command or ""):gsub("<args>", function()
		return replacement
	end)
end

---@param opts table
---@return string|nil
local function read_inline_input(opts)
	if type(vim.fn.getcharstr) ~= "function" then
		return nil
	end

	local value = opts.initial or ""
	while true do
		if type(opts.on_change) == "function" and not opts.on_change(value) then
			break
		end

		local ok, key = pcall(vim.fn.getcharstr)
		if not ok or key == nil then
			break
		end
		if key == "\r" or key == "\n" then
			return value
		end
		if key == "\027" then
			return nil
		end

		local key_byte = string.byte(key, 1)
		if key == "\127" or key == "\008" then
			value = value:sub(1, math.max(0, #value - 1))
		elseif key == "\021" then
			value = ""
		elseif key_byte and key_byte >= 32 and key_byte ~= 128 then
			value = value .. key
		end
	end
	return value
end

---@param opts table
---@return nil
function M.open_filter_prompt(opts)
	local function apply_input(input)
		if input == nil then
			return
		end
		opts.set_filter_query(input)
		opts.apply_filter()
		opts.render_picker()
	end

	local function run_inline_filter()
		local original_query = opts.get_filter_query()
		local result = read_inline_input({
			initial = original_query,
			on_change = function(value)
				opts.set_filter_query(value)
				opts.apply_filter()
				return opts.render_picker()
			end,
		})
		if result == nil then
			opts.set_filter_query(original_query)
			opts.apply_filter()
			opts.render_picker()
			return true
		end
		opts.set_filter_query(result)
		opts.apply_filter()
		opts.render_picker()
		return result ~= nil
	end

	local function run_ui_filter()
		if not (vim.ui and type(vim.ui.input) == "function") then
			return false
		end
		vim.ui.input({ prompt = "Build filter: ", default = opts.get_filter_query() }, apply_input)
		return true
	end

	local function run_cmdline_filter()
		if type(vim.fn.input) ~= "function" then
			return false
		end
		local entered = vim.fn.input("Build filter: ", opts.get_filter_query())
		apply_input(entered)
		return true
	end

	local filter_input_mode = opts.filter_input_mode or "inline"
	if filter_input_mode == "inline" then
		if run_inline_filter() or run_ui_filter() or run_cmdline_filter() then
			return
		end
	elseif filter_input_mode == "ui" then
		if run_ui_filter() or run_cmdline_filter() then
			return
		end
	else
		if run_cmdline_filter() then
			return
		end
	end

	vim.notify("Build filter prompt is unavailable in this environment", vim.log.levels.WARN)
end

---@param opts table
---@return boolean
function M.open_prompt_buffer_argument_entry(opts)
	if type(vim.fn.prompt_setprompt) ~= "function" or type(vim.fn.prompt_setcallback) ~= "function" then
		return false
	end
	if not opts.win or not vim.api.nvim_win_is_valid(opts.win) then
		return false
	end

	local prompt_buf = vim.api.nvim_create_buf(false, true)
	local prompt_label = tostring(opts.selected.argument_prompt or (opts.selected.name .. " args"))
	local help_line = get_prompt_buffer_help_line(opts.selected)
	local preview_line = " cmd: " .. tostring(opts.selected.display_command or opts.selected.command or "")

	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = prompt_buf })
	vim.api.nvim_set_option_value("buftype", "prompt", { buf = prompt_buf })
	vim.api.nvim_set_option_value("modifiable", true, { buf = prompt_buf })
	vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, {
		" " .. prompt_label .. " ",
		help_line,
		preview_line,
		"",
	})
	vim.fn.prompt_setprompt(prompt_buf, "> ")

	local restored = false
	local function restore_picker_view()
		if restored then
			return
		end
		restored = true
		if opts.win and vim.api.nvim_win_is_valid(opts.win) and vim.api.nvim_buf_is_valid(opts.buf) then
			vim.api.nvim_win_set_buf(opts.win, opts.buf)
			opts.render_picker()
		end
	end

	local close_picker = opts.close_picker
	local run_build = opts.run_build_command
	local selected_name = opts.selected.name
	local build_mode = opts.mode
	vim.fn.prompt_setcallback(prompt_buf, function(text)
		local entered = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if entered == "" then
			restore_picker_view()
			return
		end
		close_picker()
		run_build(selected_name, build_mode, entered)
	end)

	vim.api.nvim_win_set_buf(opts.win, prompt_buf)
	vim.api.nvim_set_option_value("wrap", false, { win = opts.win })
	vim.api.nvim_set_option_value("cursorline", true, { win = opts.win })
	vim.keymap.set({ "i", "n" }, "<Esc>", function()
		restore_picker_view()
	end, { buffer = prompt_buf, nowait = true })
	vim.api.nvim_win_set_cursor(opts.win, { 4, 0 })
	vim.cmd("startinsert")
	return true
end

---@param opts table
---@return boolean
function M.run_inline_argument_entry(opts)
	if type(vim.fn.getcharstr) ~= "function" then
		return false
	end

	local current_value = ""
	opts.set_argument_state({
		prompt = tostring(opts.selected.argument_prompt or (opts.selected.name .. " args")),
		value = current_value,
		display_command = tostring(opts.selected.display_command or opts.selected.command or ""),
		name = opts.selected.name,
		help_text = opts.selected.argument_help,
	})

	local result = read_inline_input({
		initial = current_value,
		on_change = function(value)
			current_value = value
			local state = opts.get_argument_state()
			if state then
				state.value = value
				opts.set_argument_state(state)
			end
			opts.render_picker()
			return true
		end,
	})

	if result == nil then
		opts.set_argument_state(nil)
		opts.render_picker()
		return true
	end

	if result:match("^%s*$") then
		return true
	end

	opts.set_argument_state(nil)
	opts.close_picker()
	opts.run_build_command(opts.selected.name, opts.mode, result)
	return true
end

return M
