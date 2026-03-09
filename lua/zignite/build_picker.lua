local utils = require("zignite.utils")

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

	local root = utils.get_project_root(filepath, config_options.project)
	if not root then
		root = vim.fn.fnamemodify(filepath, ":h")
	end

	local has_cmake = vim.fn.filereadable(vim.fs.joinpath(root, "CMakeLists.txt")) == 1
	local has_meson = vim.fn.filereadable(vim.fs.joinpath(root, "meson.build")) == 1
	local has_makefile = vim.fn.filereadable(vim.fs.joinpath(root, "Makefile")) == 1
	local is_c_family = filetype == "c" or filetype == "cpp"
	local filtering = has_cmake or has_meson or has_makefile
	local make_like_defaults = {
		build = true,
		run = true,
		clean = true,
		test = true,
		install = true,
		debug = true,
	}

	---@param cmd_name string
	---@param cmd_string string
	---@return string
	local function classify_build_command(cmd_name, cmd_string)
		local name = tostring(cmd_name or "")
		local command = tostring(cmd_string or "")
		if name:match("^cmake%-") or command:match("^%s*cmake%s") then
			return "cmake"
		end
		if name:match("^meson%-") or command:match("^%s*meson%s") then
			return "meson"
		end
		if make_like_defaults[name] or command:match("^%s*make%s") then
			return "make"
		end
		return "generic"
	end

	---@param command_map table<string, string>|nil
	---@return table[]
	local function build_command_list(command_map)
		local entries = {}
		for cmd_name, cmd_string in pairs(command_map or {}) do
			local include = true

			if is_c_family then
				local command_type = classify_build_command(cmd_name, cmd_string)
				if command_type == "cmake" then
					include = has_cmake
				elseif command_type == "meson" then
					include = has_meson
				elseif command_type == "make" then
					include = has_makefile
				end
			elseif filtering then
				if cmd_name:match("^cmake%-") then
					include = has_cmake
				elseif cmd_name:match("^meson%-") then
					include = has_meson
				elseif tostring(cmd_string or ""):match("^%s*make%s") then
					include = has_makefile
				else
					include = true
				end
			end

			if include then
				entries[#entries + 1] = { name = cmd_name, command = cmd_string }
			end
		end

		table.sort(entries, function(a, b)
			return a.name < b.name
		end)
		return entries
	end

	---@type table[]
	local all_commands = {}
	---@type table[]
	local filtered_commands = {}
	local selected_index = 1
	local command_line_start = 2
	local filter_query = ""
	local picker_ready = false
	---@type table<string, string>|nil
	local pending_refresh_commands = nil

	---@param commands table[]
	---@param command_name string
	---@return integer|nil
	local function find_command_index(commands, command_name)
		for idx, cmd in ipairs(commands) do
			if cmd.name == command_name then
				return idx
			end
		end
		return nil
	end

	---@return nil
	local function apply_filter()
		local query = filter_query:lower()
		filtered_commands = {}
		for _, cmd in ipairs(all_commands) do
			local display_command = opts.command_for_display(cmd.command)
			local name_match = cmd.name:lower():find(query, 1, true) ~= nil
			local command_match = display_command:lower():find(query, 1, true) ~= nil
			if query == "" or name_match or command_match then
				filtered_commands[#filtered_commands + 1] = cmd
			end
		end

		if #filtered_commands == 0 then
			selected_index = 0
		elseif selected_index < 1 then
			selected_index = 1
		elseif selected_index > #filtered_commands then
			selected_index = #filtered_commands
		end
	end

	---@param command_map table<string, string>
	---@param preferred_name string|nil
	---@return nil
	local function replace_command_map(command_map, preferred_name)
		all_commands = build_command_list(command_map)
		apply_filter()
		if preferred_name and #filtered_commands > 0 then
			local preferred_idx = find_command_index(filtered_commands, preferred_name)
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

	local last_selected_name = opts.get_last_build_command(filetype)
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

	---@param text string
	---@return string
	local function format_command_preview(text)
		if #text <= 52 then
			return text
		end
		return text:sub(1, 49) .. "..."
	end

	---@return string[]
	local function build_lines()
		local lines = {
			string.format(" Filter: %s ", filter_query ~= "" and filter_query or "(none)"),
		}

		if #filtered_commands == 0 then
			lines[#lines + 1] = "  (no commands match current filter)"
		else
			for _, cmd in ipairs(filtered_commands) do
				local display_command = opts.command_for_display(cmd.command)
				lines[#lines + 1] = string.format("  %-18s → %s", cmd.name, format_command_preview(display_command))
			end
		end

		lines[#lines + 1] = "j/k: navigate | Enter: select | /: filter | c: clear | r: repeat | Esc: cancel"
		local preview_text = "(none)"
		if #filtered_commands > 0 and selected_index >= 1 then
			preview_text = opts.command_for_display(filtered_commands[selected_index].command)
		end
		lines[#lines + 1] = " cmd: " .. preview_text
		return lines
	end

	local lines = build_lines()
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })

	local max_width = 0
	for _, line in ipairs(lines) do
		max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
	end
	local width_cap = math.max(40, math.floor(vim.o.columns * 0.75))
	local width = math.min(max_width + 4, width_cap)
	local height_cap = math.max(8, math.floor(vim.o.lines * 0.65))
	local height = math.min(#lines + 1, height_cap)

	local float_config = config_options.float or {}
	local picker_config = config_options.picker or {}
	local preferred_row = math.floor(vim.o.lines * (float_config.y or 0.90)) - height
	local preferred_col = vim.o.columns - width - 2
	local max_row = math.max(0, vim.o.lines - height)
	local max_col = math.max(0, vim.o.columns - width)
	local picker_focus = picker_config.focus ~= false
	local win_opts = {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(0, math.min(preferred_row, max_row)),
		col = math.max(0, math.min(preferred_col, max_col)),
		style = "minimal",
		border = float_config.border or "rounded",
		title = " " .. filetype .. " ",
		title_pos = "center",
	}

	win = vim.api.nvim_open_win(buf, picker_focus, win_opts)
	vim.api.nvim_set_option_value("cursorline", true, { win = win })
	vim.api.nvim_set_option_value("winhl", "Normal:Normal,FloatBorder:FloatBorder,CursorLine:Visual", { win = win })

	render_picker = function()
		if not vim.api.nvim_win_is_valid(win) then
			return
		end

		local updated_lines = build_lines()
		vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, updated_lines)
		vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

		vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
		if #filtered_commands == 0 or selected_index < 1 then
			return
		end

		local cursor_line = command_line_start + selected_index - 1
		vim.api.nvim_win_set_cursor(win, { cursor_line, 0 })
		vim.api.nvim_buf_set_extmark(buf, ns_id, cursor_line - 1, 0, {
			virt_text = { { "▶ ", "Special" } },
			virt_text_pos = "overlay",
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

	for i = 1, 9 do
		vim.keymap.set("n", tostring(i), function()
			select_command(i)
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
