local command_helpers = require("zignite.build.picker.commands")
local filter_helpers = require("zignite.build.picker.filter")
local input = require("zignite.build.picker.input")
local keymaps = require("zignite.build.picker.keymaps")
local layout = require("zignite.build.picker.layout")

---@type table
local M = {}

---@class ZigniteBuildPickerOpts
---@field filetype string
---@field filepath string
---@field mode string
---@field config_options table
---@field detect_runtime_opts table
---@field get_build_commands_for_picker fun(
--- filetype: string,
--- filepath: string,
--- on_refresh: fun(result: table):nil
---): table
---@field run_build_command fun(command_name: string, mode: string, provided_args?: string): nil
---@field get_last_build_command fun(filetype: string): string|nil

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

	local is_c_family = filetype == "c" or filetype == "cpp"
	local last_selected_name = opts.get_last_build_command(filetype)
	local common_command_order = {
		build = 1,
		run = 2,
		clean = 3,
		test = 4,
		install = 5,
		check = 6,
		dev = 7,
		start = 8,
		watch = 9,
		serve = 10,
		preview = 11,
		mod = 12,
		fetch = 13,
	}
	local profile_command_order = {
		config = 1,
		setup = 2,
		debug = 3,
		release = 4,
	}
	local section_order = {
		common = 1,
		targets = 2,
		profiles = 3,
		other = 4,
	}
	local section_labels = {
		common = "common",
		targets = "targets",
		profiles = "profiles",
		other = "other",
	}

	---@param cmd table
	---@return string
	local function command_section(cmd)
		return command_helpers.command_section(cmd, common_command_order, profile_command_order)
	end

	---@param command_map table<string, string>|nil
	---@param command_meta table<string, table>|nil
	---@return table[]
	local function build_command_list(command_map, command_meta)
		return command_helpers.build_command_list(
			command_map,
			command_meta,
			is_c_family,
			last_selected_name,
			common_command_order,
			profile_command_order,
			section_order
		)
	end

	---@type table[]
	local all_commands = {}
	---@type table[]
	local filtered_commands = {}
	local selected_index = 1
	local filter_query = ""
	local picker_ready = false
	---@type table|nil
	local pending_refresh_commands = nil
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

	---@param command_map table<string, string>
	---@param command_meta table<string, table>|nil
	---@param preferred_name string|nil
	---@return nil
	local function replace_command_map(command_map, command_meta, preferred_name)
		all_commands = build_command_list(command_map, command_meta)
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
		if type(updated) ~= "table" then
			return
		end
		if not picker_ready then
			pending_refresh_commands = {
				commands = vim.tbl_extend("force", {}, updated.commands or {}),
				command_meta = vim.tbl_extend("force", {}, updated.command_meta or {}),
			}
			return
		end

		local preferred_name = nil
		if #filtered_commands > 0 and selected_index >= 1 then
			local selected = filtered_commands[selected_index]
			preferred_name = selected and selected.name or nil
		end
		replace_command_map(updated.commands or {}, updated.command_meta or {}, preferred_name)
		if type(render_picker) == "function" and win and vim.api.nvim_win_is_valid(win) then
			render_picker()
		end
	end

	local resolved = opts.get_build_commands_for_picker(filetype, filepath, on_picker_refresh)
	local build_cmds = type(resolved) == "table" and resolved.commands or {}
	local command_meta = type(resolved) == "table" and resolved.command_meta or {}
	local can_refresh_from_detection = detect_runtime_opts.async_picker ~= false

	if vim.tbl_isempty(build_cmds) and not can_refresh_from_detection then
		vim.notify(string.format("No build commands available for filetype: %s", filetype), vim.log.levels.WARN)
		return
	end

	replace_command_map(build_cmds, command_meta, last_selected_name)
	if pending_refresh_commands then
		replace_command_map(
			pending_refresh_commands.commands or {},
			pending_refresh_commands.command_meta or {},
			last_selected_name
		)
		pending_refresh_commands = nil
	end

	if #all_commands == 0 and not can_refresh_from_detection then
		vim.notify(
			string.format("No build commands available for %s in this project context", filetype),
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
		command_section = command_section,
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
		if not vim.api.nvim_win_is_valid(win) then
			return
		end

		local updated_lines, updated_win_opts, updated_command_lines = layout.build_render_state({
			filetype = filetype,
			float_config = float_config,
			picker_config = picker_config,
			filter_query = filter_query,
			filtered_commands = filtered_commands,
			selected_index = selected_index,
			command_section = command_section,
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
		if vim.api.nvim_win_set_config then
			vim.api.nvim_win_set_config(win, updated_win_opts)
		end
		vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, updated_lines)
		vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

		vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
		if argument_state ~= nil then
			vim.api.nvim_win_set_cursor(win, { 2, 0 })
			return
		end
		if #filtered_commands == 0 or selected_index < 1 then
			return
		end

		local cursor_line = command_lines[selected_index] or 2
		vim.api.nvim_win_set_cursor(win, { cursor_line, 0 })
		vim.api.nvim_buf_set_extmark(buf, ns_id, cursor_line - 1, 0, {
			virt_text = { { "▶ ", "Special" } },
			virt_text_pos = "overlay",
		})
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
		opts.run_build_command(selected.name, mode)
	end

	---@return nil
	local function run_last_selected()
		local command_name = opts.get_last_build_command(filetype)
		if not command_name then
			vim.notify(string.format("No previous build command for filetype: %s", filetype), vim.log.levels.WARN)
			return
		end
		close_picker()
		opts.run_build_command(command_name, mode)
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

	picker_ready = true
	if pending_refresh_commands then
		on_picker_refresh(pending_refresh_commands)
	else
		render_picker()
	end
end

return M
