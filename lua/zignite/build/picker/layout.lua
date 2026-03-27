---@param text string
---@param max_width integer
---@return string
local function truncate_text(text, max_width)
	local value = tostring(text or "")
	if max_width <= 0 then
		return ""
	end
	if vim.fn.strdisplaywidth(value) <= max_width then
		return value
	end
	if max_width <= 3 then
		return value:sub(1, max_width)
	end

	local truncated = value
	while #truncated > 0 and vim.fn.strdisplaywidth(truncated) > (max_width - 3) do
		truncated = truncated:sub(1, #truncated - 1)
	end
	return truncated .. "..."
end

---@param picker_config table
---@return "compact"|"detailed"
local function resolve_picker_layout(picker_config)
	local requested_layout = picker_config.layout or "auto"
	if requested_layout == "compact" or requested_layout == "detailed" then
		return requested_layout
	end

	local compact_breakpoint = tonumber(picker_config.compact_breakpoint) or 96
	if vim.o.columns <= compact_breakpoint then
		return "compact"
	end
	return "detailed"
end

---@param layout_mode "compact"|"detailed"
---@return integer, integer
local function resolve_picker_caps(layout_mode)
	local min_width = layout_mode == "compact" and 24 or 34
	local width_ratio = layout_mode == "compact" and 0.50 or 0.68
	local min_height = layout_mode == "compact" and 7 or 8
	local height_ratio = layout_mode == "compact" and 0.50 or 0.60
	local width_cap = math.max(min_width, math.floor(vim.o.columns * width_ratio))
	local height_cap = math.max(min_height, math.floor(vim.o.lines * height_ratio))
	return width_cap, height_cap
end

---@param layout_mode "compact"|"detailed"
---@param width_cap integer
---@return string
local function picker_help_line(layout_mode, width_cap)
	if layout_mode == "compact" then
		if width_cap < 42 then
			return "Enter | / filter | r repeat | q close"
		end
		return "Enter: select | /: filter | r: repeat | q: close"
	end
	if width_cap < 58 then
		return "j/k | Enter | / filter | r repeat | Esc"
	end
	return "j/k: navigate | Enter: select | /: filter | c: clear | r: repeat | Esc: cancel"
end

---@param cmd table
---@param layout_mode "compact"|"detailed"
---@param width_cap integer
---@param command_for_display fun(cmd: table): string
---@return string
local function format_command_line(cmd, layout_mode, width_cap, command_for_display)
	if layout_mode == "compact" then
		local name_limit = math.max(10, width_cap - 5)
		return "  " .. truncate_text(cmd.name, name_limit)
	end

	local display_command = command_for_display(cmd)
	local name_width = math.max(12, math.min(18, math.floor(width_cap * 0.28)))
	local preview_limit = math.max(14, width_cap - name_width - 8)
	return string.format(
		"  %-" .. tostring(name_width) .. "s → %s",
		truncate_text(cmd.name, name_width),
		truncate_text(display_command, preview_limit)
	)
end

---@param args table
---@return string[], table<integer, integer>
local function build_lines(args)
	---@type table<integer, integer>
	local command_lines = {}
	if args.argument_mode then
		local prompt = tostring(args.header_label or "Command arguments")
		local value = tostring(args.header_value or "")
		local shown_value = value ~= "" and value or "(required)"
		local lines = {
			" " .. prompt .. " ",
			" > " .. truncate_text(shown_value, math.max(12, args.width_cap - 4)),
		}
		local help_text = args.help_text or "Type arguments, then press Enter to run"
		lines[#lines + 1] = ""
		lines[#lines + 1] = truncate_text(help_text, math.max(20, args.width_cap - 2))
		local preview_text = truncate_text(args.preview_text or "(none)", math.max(12, args.width_cap - 8))
		lines[#lines + 1] = " cmd: " .. preview_text
		return lines, command_lines
	end

	local header_label = tostring(args.header_label or "Filter")
	local header_value = tostring(
		args.header_value or (args.filter_query ~= "" and args.filter_query or "(none)")
	)
	local lines = {
		string.format(" %s: %s ", header_label, header_value),
	}

	if #args.filtered_commands == 0 then
		lines[#lines + 1] = "  (no commands match current filter)"
	else
		local last_section = nil
		for index, cmd in ipairs(args.filtered_commands) do
			local section = args.command_section(cmd)
			if section ~= last_section then
				lines[#lines + 1] = " " .. (args.section_labels[section] or args.section_labels.other)
				last_section = section
			end
			lines[#lines + 1] = format_command_line(
				cmd,
				args.layout_mode,
				args.width_cap,
				args.command_for_display
			)
			command_lines[index] = #lines
		end
	end

	local help_text = args.help_text or picker_help_line(args.layout_mode, args.width_cap)
	lines[#lines + 1] = truncate_text(help_text, math.max(20, args.width_cap - 2))

	local preview_text = args.preview_text
	if preview_text == nil and #args.filtered_commands > 0 and args.selected_index >= 1 then
		preview_text = args.command_for_display(args.filtered_commands[args.selected_index])
	end
	preview_text = truncate_text(preview_text or "(none)", math.max(12, args.width_cap - 8))
	lines[#lines + 1] = " cmd: " .. preview_text
	return lines, command_lines
end

---@param lines string[]
---@param args table
---@return table
local function build_window_opts(lines, args)
	local max_width = 0
	for _, line in ipairs(lines) do
		max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
	end
	local width = math.min(max_width + 4, args.width_cap)
	local height = math.min(#lines + 1, args.height_cap)

	local preferred_row = math.floor(vim.o.lines * (args.float_config.y or 0.90)) - height
	local preferred_col = vim.o.columns - width - 2

	local max_row = math.max(0, vim.o.lines - height)
	local max_col = math.max(0, vim.o.columns - width)
	return {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(0, math.min(preferred_row, max_row)),
		col = math.max(0, math.min(preferred_col, max_col)),
		style = "minimal",
		border = args.float_config.border or "rounded",
		title = args.layout_mode == "compact" and (" " .. args.filetype .. " build ") or (" " .. args.filetype .. " "),
		title_pos = "center",
	}
end

---@type table
local M = {}

---@param args table
---@return string[], table, table<integer, integer>
function M.build_render_state(args)
	local layout_mode = resolve_picker_layout(args.picker_config)
	local width_cap, height_cap = resolve_picker_caps(layout_mode)
	local lines, command_lines = build_lines({
		layout_mode = layout_mode,
		width_cap = width_cap,
			filter_query = args.filter_query,
			filtered_commands = args.filtered_commands,
			selected_index = args.selected_index,
			command_section = args.command_section,
			section_labels = args.section_labels,
			command_for_display = args.command_for_display,
			header_label = args.header_label,
			header_value = args.header_value,
			argument_mode = args.argument_mode,
			help_text = args.help_text,
			preview_text = args.preview_text,
		})
	local win_opts = build_window_opts(lines, {
		layout_mode = layout_mode,
		width_cap = width_cap,
		height_cap = height_cap,
		float_config = args.float_config,
		filetype = args.filetype,
	})
	return lines, win_opts, command_lines
end

return M
