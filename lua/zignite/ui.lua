local M = {}

-- Keep track of runner windows
-- If singleton = true, this will only ever have 1 item
local runners = {}
local spinner_timer = nil
local quickfix_backend_available = nil
local quickfix_worker = nil

local function get_config()
	local cfg = require("zignite.config")
	cfg.ensure()
	return cfg.options
end

local function get_plugin_path()
	local source = debug.getinfo(1, "S").source
	if source:sub(1, 1) == "@" then
		source = source:sub(2)
	end
	return vim.fn.fnamemodify(source, ":p:h:h:h")
end

local QUICKFIX_BACKEND = get_plugin_path() .. "/zig/zig-out/bin/zignite"

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

local function has_quickfix_backend()
	if quickfix_backend_available == nil then
		quickfix_backend_available = vim.fn.executable(QUICKFIX_BACKEND) == 1
	end
	return quickfix_backend_available
end

local function copy_lines(lines)
	local out = {}
	for i = 1, #lines do
		out[i] = lines[i]
	end
	return out
end

local function append_truncation_notice(lines)
	local out = { "[zignite] quickfix output truncated" }
	for i = 1, #lines do
		out[#out + 1] = lines[i]
	end
	return out
end

local function tail_lines_by_bytes(lines, max_bytes)
	if max_bytes == nil or max_bytes <= 0 or #lines == 0 then
		return lines, false
	end

	local used = 0
	local start_idx = #lines + 1
	for i = #lines, 1, -1 do
		used = used + #lines[i] + 1
		if used > max_bytes then
			break
		end
		start_idx = i
	end

	if start_idx <= 1 then
		return lines, false
	end

	if start_idx > #lines then
		return { lines[#lines] }, true
	end

	local out = {}
	for i = start_idx, #lines do
		out[#out + 1] = lines[i]
	end

	return out, true
end

local function collect_lua_quickfix_lines(buf, quickfix_opts)
	local max_lines = tonumber(quickfix_opts.max_lines) or 1000
	if max_lines < 1 then
		max_lines = 1
	end

	local total_lines = vim.api.nvim_buf_line_count(buf)
	local start_line = math.max(0, total_lines - max_lines)
	local lines = vim.api.nvim_buf_get_lines(buf, start_line, -1, false)
	local truncated = start_line > 0

	local max_bytes = tonumber(quickfix_opts.max_bytes) or 262144
	local byte_truncated = false
	lines, byte_truncated = tail_lines_by_bytes(lines, max_bytes)
	truncated = truncated or byte_truncated

	return lines, truncated, total_lines
end

local function choose_quickfix_processor(quickfix_opts, total_lines)
	local processor = tostring(quickfix_opts.processor or "auto"):lower()
	if processor == "lua" or processor == "zig" then
		return processor
	end

	local zig_min_lines = tonumber(quickfix_opts.zig_min_lines) or 300
	if zig_min_lines < 1 then
		zig_min_lines = 1
	end

	if total_lines >= zig_min_lines then
		return "zig"
	end

	return "lua"
end

local function populate_quickfix_lua(lines, quickfix_opts, truncated)
	local processed = copy_lines(lines)
	if truncated then
		processed = append_truncation_notice(processed)
	end

	if quickfix_opts.strip_ansi == false then
		set_quickfix_lines(processed)
		return
	end

	local chunk_size = tonumber(quickfix_opts.strip_chunk_size) or 200
	if chunk_size < 1 then
		chunk_size = 1
	end

	local strip_max_lines = tonumber(quickfix_opts.strip_ansi_max_lines) or #processed
	if strip_max_lines < 1 then
		strip_max_lines = #processed
	end
	local strip_start = math.max(1, #processed - strip_max_lines + 1)

	local idx = strip_start
	local function strip_next_chunk()
		local upper = math.min(#processed, idx + chunk_size - 1)
		for i = idx, upper do
			if processed[i]:find("\27", 1, true) then
				processed[i] = processed[i]:gsub("\27%[[0-9;]*m", "")
			end
		end
		idx = upper + 1

		if idx <= #processed and quickfix_opts.async_strip ~= false then
			vim.schedule(strip_next_chunk)
			return
		end

		if idx <= #processed then
			strip_next_chunk()
			return
		end

		set_quickfix_lines(processed)
	end

	strip_next_chunk()
end

local function bool_to_flag(value, default)
	local resolved = value
	if resolved == nil then
		resolved = default
	end
	if type(resolved) == "string" then
		local lowered = resolved:lower()
		if lowered == "0" or lowered == "false" or lowered == "no" then
			resolved = false
		else
			resolved = true
		end
	elseif type(resolved) == "number" then
		resolved = resolved ~= 0
	end
	return resolved and "1" or "0"
end

local function quickfix_flag_values(quickfix_opts)
	local max_lines = tonumber(quickfix_opts.max_lines) or 1000
	local max_bytes = tonumber(quickfix_opts.max_bytes) or 262144
	local strip_max_lines = tonumber(quickfix_opts.strip_ansi_max_lines) or 400
	if max_lines < 1 then
		max_lines = 1
	end
	if max_bytes < 1 then
		max_bytes = 1
	end
	if strip_max_lines < 1 then
		strip_max_lines = 1
	end

	return {
		max_lines = max_lines,
		max_bytes = max_bytes,
		strip_ansi = bool_to_flag(quickfix_opts.strip_ansi, true),
		strip_max_lines = strip_max_lines,
		parse_diagnostics = bool_to_flag(quickfix_opts.parse_diagnostics, true),
	}
end

local function run_quickfix_with_zig_once(raw_lines, quickfix_opts, force_truncated, on_success, on_fallback)
	if not has_quickfix_backend() then
		on_fallback()
		return
	end

	if type(vim.fn.jobstart) ~= "function" or type(vim.fn.chansend) ~= "function" or type(vim.fn.chanclose) ~= "function" then
		on_fallback()
		return
	end

	local flags = quickfix_flag_values(quickfix_opts)

	local cmd = {
		QUICKFIX_BACKEND,
		"--quickfix",
		"--max-lines=" .. flags.max_lines,
		"--max-bytes=" .. flags.max_bytes,
		"--strip-ansi=" .. flags.strip_ansi,
		"--strip-max-lines=" .. flags.strip_max_lines,
		"--parse-diagnostics=" .. flags.parse_diagnostics,
	}

	local output_lines = {}
	local failed = false
	local job_id = vim.fn.jobstart(cmd, {
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data)
			if type(data) ~= "table" then
				return
			end
			for _, line in ipairs(data) do
				if line ~= nil and line ~= "" then
					output_lines[#output_lines + 1] = line
				end
			end
		end,
		on_exit = function(_, exit_code)
			if failed then
				return
			end
			if exit_code == 0 then
				if force_truncated and output_lines[1] ~= "[zignite] quickfix output truncated" then
					table.insert(output_lines, 1, "[zignite] quickfix output truncated")
				end
				on_success(output_lines)
				return
			end
			failed = true
			on_fallback()
		end,
	})

	if type(job_id) ~= "number" or job_id <= 0 then
		on_fallback()
		return
	end

	local payload = table.concat(raw_lines, "\n")
	if #payload > 0 then
		local ok_send = pcall(vim.fn.chansend, job_id, payload .. "\n")
		if not ok_send then
			failed = true
			on_fallback()
			return
		end
	end
	local ok_close = pcall(vim.fn.chanclose, job_id, "stdin")
	if not ok_close then
		failed = true
		on_fallback()
	end
end

local function flush_quickfix_worker_fallbacks(worker)
	if not worker or not worker.pending then
		return
	end

	for _, request in pairs(worker.pending) do
		if request and request.on_fallback then
			request.on_fallback()
		end
	end

	worker.pending = {}
	worker.active_id = nil
	worker.active_lines = {}
end

local function handle_quickfix_worker_stdout(worker, data)
	if type(data) ~= "table" then
		return
	end

	for _, line in ipairs(data) do
		if type(line) ~= "string" or line == "" then
			goto continue
		end

		local begin_id = line:match("^@@ZQF_RES_BEGIN%s+(%d+)$")
		if begin_id then
			worker.active_id = tonumber(begin_id)
			worker.active_lines = {}
			goto continue
		end

		if worker.active_id then
			local end_id = line:match("^@@ZQF_RES_END%s+(%d+)$")
			if end_id and tonumber(end_id) == worker.active_id then
				local request = worker.pending[worker.active_id]
				worker.pending[worker.active_id] = nil
				local completed_lines = worker.active_lines
				worker.active_id = nil
				worker.active_lines = {}
				if request and request.on_success then
					if request.force_truncated and completed_lines[1] ~= "[zignite] quickfix output truncated" then
						table.insert(completed_lines, 1, "[zignite] quickfix output truncated")
					end
					request.on_success(completed_lines)
				end
				goto continue
			end

			if line:sub(1, 1) == "\t" then
				worker.active_lines[#worker.active_lines + 1] = line:sub(2)
			else
				worker.active_lines[#worker.active_lines + 1] = line
			end
		end

		::continue::
	end
end

local function ensure_quickfix_worker()
	if not has_quickfix_backend() then
		return nil
	end

	if type(vim.fn.jobstart) ~= "function" or type(vim.fn.chansend) ~= "function" then
		return nil
	end

	if quickfix_worker and type(quickfix_worker.job_id) == "number" and quickfix_worker.job_id > 0 then
		return quickfix_worker
	end

	local worker = {
		job_id = nil,
		next_request_id = 0,
		pending = {},
		active_id = nil,
		active_lines = {},
	}

	local job_id = vim.fn.jobstart({ QUICKFIX_BACKEND, "--quickfix-daemon" }, {
		stdout_buffered = false,
		stderr_buffered = true,
		on_stdout = function(_, data)
			handle_quickfix_worker_stdout(worker, data)
		end,
		on_exit = function()
			if quickfix_worker == worker then
				quickfix_worker = nil
			end
			flush_quickfix_worker_fallbacks(worker)
		end,
	})

	if type(job_id) ~= "number" or job_id <= 0 then
		return nil
	end

	worker.job_id = job_id
	quickfix_worker = worker
	return worker
end

local function run_quickfix_with_zig_worker(raw_lines, quickfix_opts, force_truncated, on_success, on_fallback)
	local worker = ensure_quickfix_worker()
	if not worker then
		return false
	end

	local flags = quickfix_flag_values(quickfix_opts)
	worker.next_request_id = worker.next_request_id + 1
	local request_id = worker.next_request_id

	worker.pending[request_id] = {
		on_success = on_success,
		on_fallback = on_fallback,
		force_truncated = force_truncated,
	}

	local payload = {
		string.format(
			"@@ZQF_BEGIN %d %d %d %s %d %s",
			request_id,
			flags.max_lines,
			flags.max_bytes,
			flags.strip_ansi,
			flags.strip_max_lines,
			flags.parse_diagnostics
		),
	}
	for _, line in ipairs(raw_lines) do
		payload[#payload + 1] = "\t" .. line
	end
	payload[#payload + 1] = string.format("@@ZQF_END %d", request_id)

	local ok_send = pcall(vim.fn.chansend, worker.job_id, table.concat(payload, "\n") .. "\n")
	if not ok_send then
		worker.pending[request_id] = nil
		if type(vim.fn.jobstop) == "function" then
			pcall(vim.fn.jobstop, worker.job_id)
		end
		if quickfix_worker == worker then
			quickfix_worker = nil
		end
		return false
	end

	return true
end

local function run_quickfix_with_zig(raw_lines, quickfix_opts, force_truncated, on_success, on_fallback)
	if quickfix_opts.zig_worker ~= false then
		local ok = run_quickfix_with_zig_worker(raw_lines, quickfix_opts, force_truncated, on_success, on_fallback)
		if ok then
			return
		end
	end

	run_quickfix_with_zig_once(raw_lines, quickfix_opts, force_truncated, on_success, on_fallback)
end

local function populate_quickfix_from_buffer(buf, quickfix_opts)
	if quickfix_opts.enabled == false or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local total_lines = vim.api.nvim_buf_line_count(buf)
	local processor = choose_quickfix_processor(quickfix_opts, total_lines)

	if processor == "zig" then
		local max_lines = tonumber(quickfix_opts.max_lines) or 1000
		if max_lines < 1 then
			max_lines = 1
		end
		local start_line = math.max(0, total_lines - max_lines)
		local raw_lines = vim.api.nvim_buf_get_lines(buf, start_line, -1, false)
		local force_truncated = start_line > 0
		run_quickfix_with_zig(raw_lines, quickfix_opts, force_truncated, set_quickfix_lines, function()
			local lua_lines, truncated = collect_lua_quickfix_lines(buf, quickfix_opts)
			populate_quickfix_lua(lua_lines, quickfix_opts, truncated)
		end)
		return
	end

	local lua_lines, truncated = collect_lua_quickfix_lines(buf, quickfix_opts)
	populate_quickfix_lua(lua_lines, quickfix_opts, truncated)
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
