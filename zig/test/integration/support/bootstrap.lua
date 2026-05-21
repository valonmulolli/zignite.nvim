---@type table
local M = {}

---@return string
function M.setup()
	local project_root = arg[1] or "."
	local json = nil
	pcall(function()
		json = require("dkjson")
	end)

	_G.vim = _G.vim or {}
	vim.fn = vim.fn or {
		expand = function(path)
			return path
		end,
		fnamemodify = function(path, modifier)
			if modifier == ":h" then
				return path:gsub("/[^/]+$", "")
			elseif modifier == ":e" then
				return path:match("%.([^%.]+)$") or ""
			elseif modifier == ":t" then
				return path:match("([^/]+)$") or path
			elseif modifier == ":t:r" then
				local name = path:match("([^/]+)$") or path
				return name:gsub("%.([^%.]+)$", "")
			elseif modifier == ":." then
				return path
			end
			return path
		end,
		executable = function()
			return 1
		end,
		shellescape = function(str)
			return str
		end,
		filereadable = function()
			return 0
		end,
		strdisplaywidth = function(str)
			return #tostring(str)
		end,
		systemlist = function()
			return {}
		end,
		tempname = function()
			return os.tmpname()
		end,
		getpos = function()
			return { 0, 1, 1, 0 }
		end,
	}
	vim.v = vim.v or { shell_error = 0 }
	vim.bo = vim.bo or { filetype = "python" }
	vim.o = vim.o or { columns = 120, lines = 40 }
	vim.tbl_isempty = vim.tbl_isempty or function(tbl)
		return next(tbl) == nil
	end
	vim.tbl_contains = vim.tbl_contains or function(tbl, value)
		for _, existing in ipairs(tbl) do
			if existing == value then
				return true
			end
		end
		return false
	end
	vim.tbl_extend = vim.tbl_extend or function(behavior, ...)
		local result = {}
		for index = 1, select("#", ...) do
			local tbl = select(index, ...)
			for key, value in pairs(tbl) do
				if type(value) == "table" and type(result[key]) == "table" then
					result[key] = vim.tbl_extend(behavior, result[key], value)
				else
					result[key] = value
				end
			end
		end
		return result
	end
	vim.tbl_deep_extend = vim.tbl_deep_extend or function(behavior, ...)
		return vim.tbl_extend(behavior, ...)
	end
	vim.deepcopy = vim.deepcopy or function(value)
		if type(value) ~= "table" then
			return value
		end
		local copied = {}
		for key, item in pairs(value) do
			copied[key] = vim.deepcopy(item)
		end
		return copied
	end
	vim.keymap = vim.keymap or { set = function() end }
	vim.fs = vim.fs or {
		normalize = function(path)
			return path
		end,
		joinpath = function(a, b)
			return a .. "/" .. b
		end,
		basename = function(path)
			return (path:match("([^/]+)$") or path)
		end,
	}
	vim.loop = vim.loop or {
		new_timer = function()
			return {
				start = function() end,
				stop = function() end,
				close = function() end,
			}
		end,
	}
	vim.schedule_wrap = vim.schedule_wrap or function(func)
		return func
	end
	if type(vim.json) ~= "table" and json then
		vim.json = {
			encode = function(value)
				return json.encode(value)
			end,
			decode = function(value)
				return json.decode(value)
			end,
		}
	end
	if type(vim.fn.json_decode) ~= "function" and json then
		vim.fn.json_decode = function(value)
			return json.decode(value)
		end
	end

	local next_buf_id = 1
	local next_win_id = 1
	local win_to_buf = {}

	vim.api = vim.api or {
		nvim_create_buf = function()
			local id = next_buf_id
			next_buf_id = next_buf_id + 1
			return id
		end,
		nvim_buf_set_lines = function() end,
		nvim_buf_set_option = function() end,
		nvim_open_win = function(buf)
			local id = next_win_id
			next_win_id = next_win_id + 1
			win_to_buf[id] = buf
			return id
		end,
		nvim_win_set_option = function() end,
		nvim_win_close = function() end,
		nvim_buf_is_valid = function()
			return true
		end,
		nvim_win_is_valid = function()
			return true
		end,
		nvim_win_get_buf = function(win)
			return win_to_buf[win] or 1
		end,
		nvim_buf_get_lines = function()
			return {}
		end,
		nvim_get_current_win = function()
			return 1
		end,
		nvim_get_current_buf = function()
			return 1
		end,
		nvim_win_set_buf = function(win, buf)
			win_to_buf[win] = buf
		end,
		nvim_win_set_height = function() end,
		nvim_win_set_width = function() end,
		nvim_buf_set_keymap = function() end,
		nvim_set_option_value = function() end,
		nvim_win_set_cursor = function() end,
		nvim_win_set_config = function() end,
		nvim_buf_line_count = function()
			return 0
		end,
		nvim_create_namespace = function()
			return 1
		end,
		nvim_buf_clear_namespace = function() end,
		nvim_win_get_cursor = function()
			return { 1, 0 }
		end,
		nvim_buf_set_extmark = function() end,
		nvim_buf_delete = function() end,
		nvim_create_user_command = function() end,
		nvim_buf_get_text = function()
			return { "test" }
		end,
		nvim_getpos = function()
			return { 0, 1, 1, 0 }
		end,
	}

	vim.split = function(str, _sep)
		return { str }
	end
	vim.defer_fn = function(func, _delay)
		func()
	end
	vim.wait = vim.wait or function(timeout, condition, _interval)
		local deadline = os.clock() + ((tonumber(timeout) or 0) / 1000)
		repeat
			if condition() then
				return true
			end
		until os.clock() >= deadline
		return condition()
	end

	return project_root
end

return M
