local ui = require("zignite.ui")
local config = require("zignite.config")

local M = {}

-- Get the path to the algorithms directory
local function get_algorithms_path()
	local source = debug.getinfo(1, "S").source:sub(2)
	local plugin_root = vim.fn.fnamemodify(source, ":p:h:h:h")
	return plugin_root .. "/algorithms/typst"
end

-- Show a picker to select an algorithm
function M.show_algorithm_picker()
	local algo_path = get_algorithms_path()
	local files = vim.fn.globpath(algo_path, "*.typ", false, true)
	
	if #files == 0 then
		vim.notify("No algorithm files found in " .. algo_path, vim.log.levels.ERROR)
		return
	end

	local items = {}
	for _, file in ipairs(files) do
		local name = vim.fn.fnamemodify(file, ":t:r"):gsub("_", " "):gsub("^%l", string.upper)
		table.insert(items, {
			name = name,
			path = file,
		})
	end

	-- Create custom picker (similar to build picker but for algorithms)
	local buf = vim.api.nvim_create_buf(false, true)
	local lines = {}
	for _, item in ipairs(items) do
		table.insert(lines, string.format("  %-20s", item.name))
	end
	table.insert(lines, "j/k: navigate | Enter: select | q: cancel")

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	local width = 40
	local height = #lines + 1
	local win_opts = {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = config.options.float.border or "rounded",
		title = " Select Algorithm ",
		title_pos = "center",
		footer = " Visualization: Typst ",
	}

	local win = vim.api.nvim_open_win(buf, true, win_opts)
	vim.api.nvim_win_set_option(win, "cursorline", true)
	vim.api.nvim_win_set_option(win, "winhl", "Normal:Normal,FloatBorder:FloatBorder,CursorLine:Visual")

	local function close_picker()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	local function select_algo(index)
		close_picker()
		local item = items[index]
		if item then
			M.render_algorithm(item.path)
		end
	end

	-- Bindings
	vim.keymap.set("n", "j", "j", { buffer = buf })
	vim.keymap.set("n", "k", "k", { buffer = buf })
	vim.keymap.set("n", "<CR>", function()
		local line = vim.api.nvim_win_get_cursor(win)[1]
		if line <= #items then
			select_algo(line)
		end
	end, { buffer = buf })
	vim.keymap.set("n", "q", close_picker, { buffer = buf })
	vim.keymap.set("n", "<Esc>", close_picker, { buffer = buf })

	-- Quick select
	for i = 1, math.min(#items, 9) do
		vim.keymap.set("n", tostring(i), function() select_algo(i) end, { buffer = buf })
	end
end

-- "Render" or show the algorithm
function M.render_algorithm(path)
	-- Option 1: Just open the file in a beautiful float
	-- Option 2: If typst is installed, compile to PDF and open?
	
	local has_typst = vim.fn.executable("typst") == 1
	
	if has_typst then
		local out_path = "/tmp/" .. vim.fn.fnamemodify(path, ":t:r") .. ".pdf"
		vim.fn.jobstart({"typst", "compile", path, out_path}, {
			on_exit = function(_, code)
				if code == 0 then
					vim.notify("Rendered algorithm to " .. out_path, vim.log.levels.INFO)
					-- Try to open it with system default
					if vim.fn.has("unix") == 1 then
						vim.fn.jobstart({"xdg-open", out_path})
					elseif vim.fn.has("mac") == 1 then
						vim.fn.jobstart({"open", out_path})
					end
				else
					vim.notify("Typst compile failed", vim.log.levels.ERROR)
				end
			end
		})
	end

	-- Always show the source in a float for quick reference
	local content = {}
	local f = io.open(path, "r")
	if f then
		for line in f:lines() do
			table.insert(content, line)
		end
		f:close()
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
	vim.api.nvim_buf_set_option(buf, "filetype", "typst")
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	local width = math.floor(vim.o.columns * 0.7)
	local height = math.floor(vim.o.lines * 0.7)
	local win_opts = {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = " " .. vim.fn.fnamemodify(path, ":t") .. " ",
		title_pos = "center",
		footer = has_typst and " [Rendered to PDF] " or " [Typst Source] ",
	}

	local win = vim.api.nvim_open_win(buf, true, win_opts)
	vim.keymap.set("n", "q", ":close<CR>", { buffer = buf, silent = true })
end

return M
