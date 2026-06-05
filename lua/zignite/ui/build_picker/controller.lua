local command_helpers = require("zignite.ui.build_picker.commands")
local filter_helpers = require("zignite.ui.build_picker.filter")
local input = require("zignite.ui.build_picker.input")
local keymaps = require("zignite.ui.build_picker.keymaps")
local layout = require("zignite.ui.build_picker.layout")

---@type table
local M = {}

---@class ZigniteBuildPickerOpts
---@field filetype string
---@field filepath string
---@field mode string
---@field config_options table
---@field detect_runtime_opts table
---@field get_build_commands_for_picker fun(
--- filepath: string,
--- filetype: string,
--- on_refresh: fun(result: table):nil
---): table
---@field run_build_command fun(command_name: string, mode: string, provided_args?: string): nil
---@field run_last_build_command fun(mode: string): nil

---@param opts ZigniteBuildPickerOpts
---@return nil
function M.open(opts)
	local filepath = opts.filepath
	local filetype = opts.filetype
	local mode = opts.mode
	local config_options = opts.config_options
	local detect_runtime_opts = opts.detect_runtime_opts or {}
	local float_config = config_options.float or {}
	local picker_config = config_options.picker or {}

	local last_selected_name = nil
	local section_labels = {
		common = "common",
		targets = "targets",
		profiles = "profiles",
		other = "other",
	}

	---@type table[]
	local all_commands = {}
	---@type table[]
	local filtered_commands = {}
	local selected_index = 1
	local filter_query = ""
	---@type table<integer, integer>
	local command_lines
	---@type { prompt: string, value: string, display_command: string, name: string, help_text: string|nil }|nil
	local argument_state = nil

	---@param cmd table
	---@return string
	local function command_for_display(cmd)
		return tostring(cmd and (cmd.display_command or cmd.command) or "")
	end

	---@return nil
	local function apply_filter()
		filtered_commands, selected_index = filter_helpers.apply_filter(
			all_commands,
			filter_query,
			selected_index,
			command_for_display
		)
	end

	---@param command_entries table[]|nil
	---@param preferred_name string|nil
	---@return nil
	local function replace_command_entries(command_entries, preferred_name)
		all_commands = command_helpers.normalize_command_entries(command_entries)
		apply_filter()
		if preferred_name and #filtered_commands > 0 then
			local preferred_idx = filter_helpers.find_command_index(filtered_commands, preferred_name)
			if preferred_idx then
				selected_index = preferred_idx
			end
		end
	end

	local win = nil
	---@type fun():nil|nil
	local render_picker = nil

	---@param updated table
	---@return nil
	local function on_picker_refresh(updated)
		if detect_runtime_opts.live_merge == false then
			return
		end
		last_selected_name = type(updated.last_command_name) == "string" and updated.last_command_name or last_selected_name

		local preferred_name = nil
		if #filtered_commands > 0 and selected_index >= 1 then
			local selected = filtered_commands[selected_index]
			preferred_name = selected and selected.name or nil
		end
		replace_command_entries(updated.command_entries, preferred_name)
		if type(render_picker) == "function" and win and vim.api.nvim_win_is_valid(win) then
			render_picker()
		end
	end

	local resolved = opts.get_build_commands_for_picker(filepath, filetype, on_picker_refresh)
	local command_entries = resolved.command_entries
	last_selected_name = type(resolved.last_command_name) == "string" and resolved.last_command_name or nil
	local can_refresh_from_detection = detect_runtime_opts.async_picker ~= false

	if resolved.ok == false and not can_refresh_from_detection then
		vim.notify(
			tostring(resolved.message or string.format("No build commands available for filetype: %s", filetype)),
			vim.log.levels.WARN
		)
		return
	end

	if (type(command_entries) ~= "table" or vim.tbl_isempty(command_entries)) and not can_refresh_from_detection then
		vim.notify(
			tostring(resolved.message or string.format("No build commands available for filetype: %s", filetype)),
			vim.log.levels.WARN
		)
		return
	end

	replace_command_entries(command_entries, last_selected_name)

	if #all_commands == 0 and not can_refresh_from_detection then
		vim.notify(
			tostring(resolved.message or string.format("No build commands available for %s in this project context", filetype)),
			vim.log.levels.WARN
		)
		return
	end

	local buf = vim.api.nvim_create_buf(false, true)
	local ns_id = vim.api.nvim_create_namespace("zignite_picker")
	local lines, initial_win_opts, initial_command_lines = layout.build_render_state({
		filetype = filetype,
		float_config = float_config,
		picker_config = picker_config,
		filter_query = filter_query,
		filtered_commands = filtered_commands,
		selected_index = selected_index,
		command_section = command_helpers.command_section,
		section_labels = section_labels,
		command_for_display = command_for_display,
		header_label = argument_state and argument_state.prompt or nil,
		header_value = argument_state and (argument_state.value ~= "" and argument_state.value or "(required)") or nil,
		argument_mode = argument_state ~= nil,
		help_text = argument_state and argument_state.help_text or nil,
		preview_text = argument_state and input.command_for_argument_display(
			argument_state.display_command,
			argument_state.value
		) or nil,
	})
	command_lines = initial_command_lines
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	local picker_focus = picker_config.focus ~= false
	local resize_group_id = nil

	win = vim.api.nvim_open_win(buf, picker_focus, initial_win_opts)
	vim.api.nvim_set_option_value("cursorline", true, { win = win })
	vim.api.nvim_set_option_value("wrap", false, { win = win })
	vim.api.nvim_set_option_value("winhl", "Normal:Normal,FloatBorder:FloatBorder,CursorLine:Visual", { win = win })

	render_picker = function()
		if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
			return
		end

		local updated_lines, updated_win_opts, updated_command_lines = layout.build_render_state({
			filetype = filetype,
			float_config = float_config,
			picker_config = picker_config,
			filter_query = filter_query,
			filtered_commands = filtered_commands,
			selected_index = selected_index,
			command_section = command_helpers.command_section,
			section_labels = section_labels,
			command_for_display = command_for_display,
			header_label = argument_state and argument_state.prompt or nil,
			header_value = argument_state and (argument_state.value ~= "" and argument_state.value or "(required)") or nil,
			argument_mode = argument_state ~= nil,
			help_text = argument_state and argument_state.help_text or nil,
			preview_text = argument_state and input.command_for_argument_display(
				argument_state.display_command,
				argument_state.value
			) or nil,
		})
		command_lines = updated_command_lines
		if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		if vim.api.nvim_win_set_config then
			vim.api.nvim_win_set_config(win, updated_win_opts)
		end
		pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf })
		pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, updated_lines)
		pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = buf })

		pcall(vim.api.nvim_buf_clear_namespace, buf, ns_id, 0, -1)
		if argument_state ~= nil then
			pcall(vim.api.nvim_win_set_cursor, win, { 2, 0 })
			return
		end
		if #filtered_commands == 0 or selected_index < 1 then
			return true
		end

		local cursor_line = command_lines[selected_index] or 2
		pcall(vim.api.nvim_win_set_cursor, win, { cursor_line, 0 })
		pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, cursor_line - 1, 0, {
			virt_text = { { "▶ ", "Special" } },
			virt_text_pos = "overlay",
		})
		return true
	end

	if vim.api.nvim_create_augroup and vim.api.nvim_create_autocmd then
		resize_group_id = vim.api.nvim_create_augroup("ZigniteBuildPicker" .. tostring(buf), { clear = true })
		vim.api.nvim_create_autocmd("VimResized", {
			group = resize_group_id,
			callback = function()
				if type(render_picker) == "function" then
					render_picker()
				end
			end,
		})
	end

	---@param delta integer
	---@return nil
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
		input.open_filter_prompt({
			filter_input_mode = picker_config.filter_input or "inline",
			get_filter_query = function()
				return filter_query
			end,
			set_filter_query = function(value)
				filter_query = value
			end,
			apply_filter = apply_filter,
			render_picker = render_picker,
		})
	end

	---@return nil
	local function close_picker()
		if resize_group_id and vim.api.nvim_del_augroup_by_id then
			pcall(vim.api.nvim_del_augroup_by_id, resize_group_id)
			resize_group_id = nil
		end
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	---@param index integer
	---@return nil
	local function select_command(index)
		local selected = filtered_commands[index]
		if not selected then
			return
		end
		if selected.requires_arguments and input.open_prompt_buffer_argument_entry({
			selected = selected,
			filetype = filetype,
			win = win,
			buf = buf,
			mode = mode,
			render_picker = render_picker,
			close_picker = close_picker,
			run_build_command = opts.run_build_command,
		}) then
			return
		end
		if selected.requires_arguments and input.run_inline_argument_entry({
			selected = selected,
			filetype = filetype,
			mode = mode,
			render_picker = render_picker,
			close_picker = close_picker,
			run_build_command = opts.run_build_command,
			get_argument_state = function()
				return argument_state
			end,
			set_argument_state = function(value)
				argument_state = value
			end,
		}) then
			return
		end
		close_picker()
		opts.run_build_command(selected.name, mode, nil)
	end

	---@return nil
	local function run_last_selected()
		close_picker()
		opts.run_last_build_command(mode)
	end

	keymaps.bind({
		buf = buf,
		move_selection = move_selection,
		selected_index = function()
			return selected_index
		end,
		filtered_commands = function()
			return filtered_commands
		end,
		select_command = select_command,
		open_filter_prompt = open_filter_prompt,
		clear_filter = function()
			filter_query = ""
			apply_filter()
			render_picker()
		end,
		run_last_selected = run_last_selected,
		close_picker = close_picker,
	})

	render_picker()
end

return M
