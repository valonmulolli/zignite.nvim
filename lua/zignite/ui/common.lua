---@type table
local M = {}

---@return table
function M.get_config()
	local cfg = require("zignite.config")
	cfg.ensure()
	return cfg.options
end

---@param key string
---@return string
function M.format_key_for_display(key)
	local text = tostring(key or "")
	text = text:gsub("^<", ""):gsub(">$", "")
	if text == "" then
		return "Esc"
	end
	return text
end

---@param mode string|nil
---@return string
function M.normalize_mode(mode)
	local resolved = mode or M.get_config().mode or "float"
	-- Valid modes: "float", "tab", "split", "vsplit" (single source: zignite.config)
	if resolved ~= "float" and resolved ~= "tab" and resolved ~= "split" and resolved ~= "vsplit" then
		return "float"
	end
	return resolved
end

---@return string
local function normalize_close_behavior()
	local behavior = tostring(M.get_config().close_behavior or "stop"):lower()
	if behavior ~= "hide" and behavior ~= "stop" then
		return "stop"
	end
	return behavior
end

---@param stop_jobs boolean|nil
---@return boolean
function M.should_stop_on_close(stop_jobs)
	if stop_jobs == nil then
		return normalize_close_behavior() == "stop"
	end
	return stop_jobs == true
end

---@param float_config table
---@param should_focus boolean
---@param detail string|nil
---@return string
function M.build_float_footer(float_config, should_focus, detail)
	local close_key = M.format_key_for_display(float_config.close_key or "<Esc>")
	local input_hint
	if not should_focus then
		input_hint = "focus disabled"
	elseif float_config.startinsert ~= false then
		input_hint = "input ready"
	else
		input_hint = "press i for input"
	end
	local footer = string.format(" %s: close | %s ", close_key, input_hint)
	if type(detail) ~= "string" or detail == "" then
		return footer
	end
	local trimmed_detail = detail
	if #trimmed_detail > 48 then
		trimmed_detail = trimmed_detail:sub(1, 45) .. "..."
	end
	return string.format(" %s: close | %s | %s ", close_key, input_hint, trimmed_detail)
end

---@param path string
---@return string
local function basename(path)
	local text = tostring(path or "")
	local value = text:match("([^/\\]+)$")
	return value or text
end

---@param text string
---@return string
local function capitalize(text)
	local value = tostring(text or "")
	if value == "" then
		return value
	end
	return value:sub(1, 1):upper() .. value:sub(2)
end

---@param command string|string[]
---@return string[]|nil
local function extract_command_argv(command)
	if type(command) ~= "table" or #command == 0 then
		return nil
	end

	local argv = command
	if basename(argv[1]) == "zignite" then
		for index, value in ipairs(argv) do
			if value == "--argv" and index < #argv then
				local inner = {}
				for inner_index = index + 1, #argv do
					inner[#inner + 1] = tostring(argv[inner_index])
				end
				return inner
			end
		end
	end

	local direct = {}
	for _, value in ipairs(argv) do
		direct[#direct + 1] = tostring(value)
	end
	return direct
end

---@param command string|string[]
---@return string|nil
function M.summarize_command(command)
	if type(command) == "string" and command ~= "" then
		return command
	end

	local argv = extract_command_argv(command)
	if not argv or #argv == 0 then
		return nil
	end

	local program = basename(argv[1])
	if program == "zig" and argv[2] == "run" then
		return "zig run " .. basename(argv[3] or "")
	end
	if program == "zig" and argv[2] == "build" and argv[3] == "run" then
		return "zig build run"
	end
	if program == "go" and argv[2] == "run" then
		return "go run " .. basename(argv[#argv] or "")
	end
	if program == "cargo" and argv[2] == "run" then
		return "cargo run"
	end
	if (program == "python" or program == "python3") and argv[#argv] then
		if argv[2] == "-u" then
			return program .. " -u " .. basename(argv[#argv])
		end
		return program .. " " .. basename(argv[#argv])
	end

	local summary = program
	if argv[2] then
		summary = summary .. " " .. argv[2]
	end
	if argv[3] then
		summary = summary .. " " .. basename(argv[3])
	end
	return summary
end

---@param command string|string[]
---@param title_name string|nil
---@return string
function M.describe_command_activity(command, title_name)
	local argv = extract_command_argv(command)
	if argv and #argv > 0 then
		local program = basename(argv[1])
		if program == "zig" and argv[2] == "run" then
			return "Compiling Zig"
		end
		if program == "zig" and argv[2] == "build" and argv[3] == "run" then
			return "Building Zig Project"
		end
		if program == "go" and argv[2] == "run" then
			return "Compiling Go"
		end
		if program == "cargo" and argv[2] == "run" then
			return "Running Cargo"
		end
		return "Running " .. capitalize(program)
	end

	if type(title_name) == "string" and title_name ~= "" then
		return "Running " .. capitalize(title_name)
	end
	return "Running Code"
end

---@param text string
---@return string[]
function M.split_text_lines(text)
	local input = tostring(text or "")
	if input == "" then
		return { "" }
	end

	---@type string[]
	local lines = {}
	for line in (input .. "\n"):gmatch("([^\n]*)\n") do
		lines[#lines + 1] = line
	end
	return lines
end

---@return table
function M.get_float_config()
	local float_config = M.get_config().float or {}
	local max_width = math.max(20, vim.o.columns - 2)
	local max_height = math.max(5, vim.o.lines - 2)
	local float_width = type(float_config.width) == "number" and float_config.width or 0.8
	local float_height = type(float_config.height) == "number" and float_config.height or 0.8
	local float_x = type(float_config.x) == "number" and float_config.x or 0.5
	local float_y = type(float_config.y) == "number" and float_config.y or 0.5
	local width = math.floor(vim.o.columns * float_width)
	local height = math.floor(vim.o.lines * float_height)
	width = math.max(20, math.min(width, max_width))
	height = math.max(5, math.min(height, max_height))
	local col = math.floor((vim.o.columns - width) * float_x)
	local row = math.floor((vim.o.lines - height) * float_y)

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

return M
