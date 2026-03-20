local command_helpers = require("zignite.build.picker.commands")
local filter_helpers = require("zignite.build.picker.filter")
local layout = require("zignite.build.picker.layout")

---@type table
local M = {}

---@class ZigniteBuildPickerOpts
---@field filetype string
---@field filepath string
---@field mode string
---@field config_options table
---@field command_for_display fun(command: string): string
---@field get_detect_runtime_options fun(): table
---@field get_build_commands_for_picker fun(
--- filetype: string,
--- filepath: string,
--- on_refresh: fun(commands: table<string, string>):nil
---): table<string, string>
---@field can_detect_build_commands_for_filetype fun(filetype: string): boolean
---@field run_build_command fun(command_name: string, mode: string): nil
---@field get_last_build_command fun(filetype: string): string|nil

---@param opts ZigniteBuildPickerOpts
---@return nil
function M.open(opts)
	local filepath = opts.filepath
	local filetype = opts.filetype
	local mode = opts.mode
	local config_options = opts.config_options
	local detect_runtime_opts = opts.get_detect_runtime_options()
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
	---@return table[]
	local function build_command_list(command_map)
		return command_helpers.build_command_list(
			command_map,
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
	---@type table<string, string>|nil
	local pending_refresh_commands = nil
	---@type table<integer, integer>
	local command_lines

	---@return nil
	local function apply_filter()
		filtered_commands, selected_index = filter_helpers.apply_filter(
			all_commands,
			filter_query,
			selected_index,
			opts.command_for_display
		)
	end

	---@param command_map table<string, string>
	---@param preferred_name string|nil
	---@return nil
	local function replace_command_map(command_map, preferred_name)
		all_commands = build_command_list(command_map)
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

	---@param updated_commands table<string, string>
	---@return nil
	local function on_picker_refresh(updated_commands)
		if detect_runtime_opts.live_merge == false then
			return
		end
		if type(updated_commands) ~= "table" then
			return
		end
		if not picker_ready then
			pending_refresh_commands = vim.tbl_extend("force", {}, updated_commands)
			return
		end

		local preferred_name = nil
		if #filtered_commands > 0 and selected_index >= 1 then
			local selected = filtered_commands[selected_index]
			preferred_name = selected and selected.name or nil
		end
		replace_command_map(updated_commands, preferred_name)
		if type(render_picker) == "function" and win and vim.api.nvim_win_is_valid(win) then
			render_picker()
		end
	end

	local build_cmds = opts.get_build_commands_for_picker(filetype, filepath, on_picker_refresh)
	local can_refresh_from_detection = detect_runtime_opts.async_picker ~= false
		and opts.can_detect_build_commands_for_filetype(filetype)

	if vim.tbl_isempty(build_cmds) and not can_refresh_from_detection then
		vim.notify(string.format("No build commands available for filetype: %s", filetype), vim.log.levels.WARN)
		return
	end

	replace_command_map(build_cmds, last_selected_name)
	if pending_refresh_commands then
		replace_command_map(pending_refresh_commands, last_selected_name)
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
		command_for_display = opts.command_for_display,
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
			command_for_display = opts.command_for_display,
		})
		command_lines = updated_command_lines
		if vim.api.nvim_win_set_config then
			vim.api.nvim_win_set_config(win, updated_win_opts)
		end
		vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, updated_lines)
		vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

		vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
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

	---@return nil
	local function open_filter_prompt()
		---@param input string
		---@return nil
		local function apply_input(input)
			if input == nil then
				return
			end
			filter_query = input
			apply_filter()
			render_picker()
		end

		---@return boolean
		local function run_inline_filter()
			if type(vim.fn.getcharstr) ~= "function" then
				return false
			end

			local original_query = filter_query
			local current_query = filter_query
			while true do
				filter_query = current_query
				apply_filter()
				render_picker()

				local ok, key = pcall(vim.fn.getcharstr)
				if not ok or key == nil then
					break
				end
				if key == "\r" or key == "\n" then
					break
				end
				if key == "\027" then
					filter_query = original_query
					apply_filter()
					render_picker()
					return true
				end

				local key_byte = string.byte(key, 1)
				if key == "\127" or key == "\008" then
					current_query = current_query:sub(1, math.max(0, #current_query - 1))
				elseif key == "\021" then
					current_query = ""
				elseif key_byte and key_byte >= 32 and key_byte ~= 128 then
					current_query = current_query .. key
				end
			end

			filter_query = current_query
			apply_filter()
			render_picker()
			return true
		end

		---@return boolean
		local function run_ui_filter()
			if not (vim.ui and type(vim.ui.input) == "function") then
				return false
			end
			vim.ui.input({ prompt = "Build filter: ", default = filter_query }, apply_input)
			return true
		end

		---@return boolean
		local function run_cmdline_filter()
			if type(vim.fn.input) ~= "function" then
				return false
			end
			local entered = vim.fn.input("Build filter: ", filter_query)
			apply_input(entered)
			return true
		end

		local filter_input_mode = picker_config.filter_input or "inline"
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

	vim.keymap.set("n", "j", function()
		move_selection(1)
	end, { buffer = buf, nowait = true })
	vim.keymap.set("n", "k", function()
		move_selection(-1)
	end, { buffer = buf, nowait = true })
	vim.keymap.set("n", "<Down>", function()
		move_selection(1)
	end, { buffer = buf, nowait = true })
	vim.keymap.set("n", "<Up>", function()
		move_selection(-1)
	end, { buffer = buf, nowait = true })
	vim.keymap.set("n", "<CR>", function()
		if selected_index >= 1 and selected_index <= #filtered_commands then
			select_command(selected_index)
		end
	end, { buffer = buf, nowait = true })

	for index = 1, 9 do
		vim.keymap.set("n", tostring(index), function()
			select_command(index)
		end, { buffer = buf, nowait = true })
	end

	vim.keymap.set("n", "/", open_filter_prompt, { buffer = buf, nowait = true })
	vim.keymap.set("n", "c", function()
		filter_query = ""
		apply_filter()
		render_picker()
	end, { buffer = buf, nowait = true })
	vim.keymap.set("n", "r", run_last_selected, { buffer = buf, nowait = true })
	vim.keymap.set("n", "<Esc>", close_picker, { buffer = buf, nowait = true })
	vim.keymap.set("n", "q", close_picker, { buffer = buf, nowait = true })

	picker_ready = true
	if pending_refresh_commands then
		on_picker_refresh(pending_refresh_commands)
	else
		render_picker()
	end
end

return M
