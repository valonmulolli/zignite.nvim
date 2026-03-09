---@type table
local M = {}

---@return table
function M.get_config()
	local cfg = require("zignite.config")
	cfg.ensure()
	return cfg.options
end

---@return string
function M.get_plugin_path()
	local source = debug.getinfo(1, "S").source
	if source:sub(1, 1) == "@" then
		source = source:sub(2)
	end
	return vim.fn.fnamemodify(source, ":p:h:h:h:h")
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
	if not vim.tbl_contains({ "float", "tab", "split", "vsplit" }, resolved) then
		return "float"
	end
	return resolved
end

---@return string
function M.normalize_close_behavior()
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
		return M.normalize_close_behavior() == "stop"
	end
	return stop_jobs == true
end

---@param float_config table
---@param should_focus boolean
---@return string
function M.build_float_footer(float_config, should_focus)
	local close_key = M.format_key_for_display(float_config.close_key or "<Esc>")
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
	local float_config = M.get_config().float
	local max_width = math.max(20, vim.o.columns - 2)
	local max_height = math.max(5, vim.o.lines - 2)
	local width = math.floor(vim.o.columns * float_config.width)
	local height = math.floor(vim.o.lines * float_config.height)
	width = math.max(20, math.min(width, max_width))
	height = math.max(5, math.min(height, max_height))
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

return M
