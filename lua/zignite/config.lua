---@type table
local M = {}

-- Default configuration
---@type table
M.defaults = {
	keymaps = {
		{ "n", "<leader>r",  ":RunFile<CR>",        { desc = "Run file" } },
		{ "n", "<leader>rq", ":RunClose<CR>",       { desc = "Close runner" } },
		{ "n", "<leader>rt", ":RunFile tab<CR>",    { desc = "Run file in new tab" } },
		{ "n", "<leader>rv", ":RunFile vsplit<CR>", { desc = "Run file in vertical split" } },
		{ "n", "<leader>rh", ":RunFile split<CR>",  { desc = "Run file in horizontal split" } },
		{ "n", "<leader>rb", ":RunBuildSelect<CR>", { desc = "Select build command" } },
		{ "n", "<leader>rl", ":RunLive<CR>",        { desc = "Run live/watch command" } },
	},

	-- Default output mode: "float", "tab", "split", "vsplit"
	mode = "float",

	-- Filetype runner overrides. Builtin defaults now live in the Zig backend;
	-- use this table only when you want to override them locally.
	-- Available variables:
	--   $file              - Full absolute path
	--   $fileName          - Just the filename with extension
	--   $fileNameWithoutExt - Filename without extension
	--   $dir               - Full directory path
	--   $fileExt           - File extension
	--   $dirName           - Just the directory name (not full path)
	runners = {},

	-- Project-level command overrides. Builtin defaults now live in the Zig backend;
	-- use this table only when you want to override or extend them locally.
	build_commands = {},

	-- Auto-detection toggles for build command picker/RunBuild.
	-- Keep defaults enabled for "smart by default" behavior.
	detect = {
		zig = true, -- Detect Zig subcommands via the Zig backend
		go = true, -- Detect Go subcommands via the Zig backend
		rust = true, -- Detect Cargo subcommands via the Zig backend
		odin = true, -- Detect Odin subcommands via the Zig backend
		c_cpp_make = true, -- Parse Makefile targets for c/cpp
		js_package_scripts = true, -- Parse package.json scripts for javascript/typescript
		java_kotlin_project = true, -- Infer Maven/Gradle tasks for java/kotlin projects
		bazel_project = true, -- Add Bazel workspace commands when workspace markers exist
	},

	-- Detection runtime behavior for picker responsiveness.
	detect_runtime = {
		async_picker = true, -- Open picker from cache/defaults, refresh detected commands asynchronously
		cache_ttl_ms = 15000, -- Detection cache freshness window
		live_merge = true, -- Merge refreshed commands into open picker without reopening
	},

	-- Spinner configuration
	spinner = "dots",      -- Spinner type: "dots", "line", "bar", "arrows", "dots2", "triangle", "square", "circle", "arrow", "box"
	spinner_speed = 80,    -- Speed in milliseconds
	enable_animations = true, -- Enable/disable animations and spinners

	-- Execution configuration
	timeout = nil, -- Timeout in milliseconds (e.g., 10000 for 10s). nil = no timeout. Only works with Zig backend.

	-- Quickfix behavior on command errors
	quickfix = {
		enabled = true,              -- Populate quickfix when command exits with non-zero status
		processor = "auto",          -- "auto", "lua", or "zig"; auto prefers zig when the backend is available
		zig_min_lines = 300,         -- Legacy threshold kept for compatibility; auto now prefers zig backend directly
		max_lines = 1000,            -- Tail limit for large outputs (performance guard)
		max_bytes = 262144,          -- Byte cap for quickfix payload
		strip_ansi = true,           -- Remove ANSI escape codes from quickfix lines
		strip_ansi_max_lines = 400,  -- Strip ANSI only on the most recent N lines
		parse_diagnostics = true,    -- Canonicalize parseable diagnostics in zig processor mode
		zig_worker = true,           -- Reuse a persistent zig quickfix worker to reduce process spawn overhead
		async_strip = true,          -- Strip ANSI in scheduled chunks to reduce UI stutter
		strip_chunk_size = 200,      -- Lines processed per chunk when async_strip=true
	},

	-- Project configuration
	-- Pattern matching for project root detection
	project = {},

	-- UI configuration for the floating window
	float = {
		border = "rounded",            -- Border style: "none", "single", "double", "rounded", "solid", "shadow"
		height = 0.8,                  -- Window height (0.0 to 1.0 = percentage of editor height)
		width = 0.8,                   -- Window width (0.0 to 1.0 = percentage of editor width)
		x = 0.5,                       -- Horizontal position (0.0 = left, 0.5 = center, 1.0 = right)
		y = 0.5,                       -- Vertical position (0.0 = top, 0.5 = center, 1.0 = bottom)
		border_hl = "FloatBorder",     -- Highlight group for the border
		close_key = "<Esc>",           -- Key to close the window
		auto_close_success_ms = nil,   -- Auto-close successful float runs after N ms. nil = stay open.
		focus = true,                  -- Auto-focus the window on open
		startinsert = false,           -- Enter insert mode when the window opens
		border_hl_success = "DiagnosticOk", -- Highlight group for success border (e.g., "DiagnosticOk", "String", "DiffAdd")
		border_hl_error = "DiagnosticError", -- Highlight group for error border (e.g., "DiagnosticError", "Error", "DiffDelete")
	},

	-- Terminal configuration for split/vsplit/tab modes
	term = {
		position = "bot", -- Position: "bot", "top", "left", "right"
		size = 15,    -- Size in lines (for horizontal) or columns (for vertical)
		focus = true, -- Focus on terminal after opening
		startinsert = true, -- Start in insert mode
	},

	-- Build picker configuration
	picker = {
		focus = true, -- Focus the interactive build picker window when opening
		filter_input = "inline", -- Filter prompt mode: "inline", "ui", or "cmdline"
		layout = "auto", -- Picker layout: "auto", "detailed", or "compact"
		compact_breakpoint = 96, -- In auto mode, switch to compact layout at or below this editor width
	},

	-- Execution behavior
	singleton = true, -- If true, only one runner window can be open at a time (previous one is closed)
	close_behavior = "stop", -- Behavior for :RunClose and float close key: "stop" or "hide"
}

-- This will hold the merged user and default configuration
---@type table
M.options = {}
M.revision = 0

local VALID_MODES = { "float", "tab", "split", "vsplit" }
local VALID_FLOAT_BORDERS = { "none", "single", "double", "rounded", "solid", "shadow" }
local VALID_TERM_POSITIONS = { "bot", "top", "left", "right" }
local VALID_PICKER_FILTER_INPUTS = { "inline", "ui", "cmdline" }
local VALID_PICKER_LAYOUTS = { "auto", "detailed", "compact" }
local VALID_CLOSE_BEHAVIORS = { "stop", "hide" }

---@param message string
---@return nil
local function warn_config(message)
	vim.notify(message, vim.log.levels.WARN)
end

---@param path string
---@param value any
---@param allowed string[]
---@return nil
local function warn_invalid_choice(path, value, allowed)
	warn_config(string.format("Invalid %s: %s. Valid values: %s", path, tostring(value), table.concat(allowed, ", ")))
end

---@param path string
---@param value any
---@return nil
local function warn_expected_boolean(path, value)
	warn_config(string.format("Invalid %s: expected boolean, got %s", path, type(value)))
end

-- Validate configuration options
---@param opts table
---@return nil
local function validate_config(opts)
	if opts.mode and not vim.tbl_contains(VALID_MODES, opts.mode) then
		warn_invalid_choice("mode", opts.mode, VALID_MODES)
	end

	if opts.float then
		local float = opts.float
		if float.border and not vim.tbl_contains(VALID_FLOAT_BORDERS, float.border) then
			warn_invalid_choice("float.border", float.border, VALID_FLOAT_BORDERS)
		end
		if float.height then
			local h = tonumber(float.height)
			if not h then
				warn_config("float.height must be a number, got " .. type(float.height))
			elseif h <= 0 or h > 1 then
				warn_config("Float height should be > 0 and <= 1")
			end
		end
		if float.width then
			local w = tonumber(float.width)
			if not w then
				warn_config("float.width must be a number, got " .. type(float.width))
			elseif w <= 0 or w > 1 then
				warn_config("Float width should be > 0 and <= 1")
			end
		end
	end

	if opts.term then
		local term = opts.term
		if term.position and not vim.tbl_contains(VALID_TERM_POSITIONS, term.position) then
			warn_invalid_choice("term.position", term.position, VALID_TERM_POSITIONS)
		end
	end

	if opts.picker then
		local picker = opts.picker
		if picker.filter_input and not vim.tbl_contains(VALID_PICKER_FILTER_INPUTS, picker.filter_input) then
			warn_invalid_choice("picker.filter_input", picker.filter_input, VALID_PICKER_FILTER_INPUTS)
		end
		if picker.layout and not vim.tbl_contains(VALID_PICKER_LAYOUTS, picker.layout) then
			warn_invalid_choice("picker.layout", picker.layout, VALID_PICKER_LAYOUTS)
		end
		if picker.compact_breakpoint ~= nil then
			local breakpoint = tonumber(picker.compact_breakpoint)
			if not breakpoint or breakpoint < 40 then
				warn_config(
					"Invalid picker.compact_breakpoint: expected number >= 40, got "
						.. tostring(picker.compact_breakpoint)
				)
			end
		end
	end

	if opts.detect_runtime then
		local runtime = opts.detect_runtime
		if runtime.async_picker ~= nil and type(runtime.async_picker) ~= "boolean" then
			warn_expected_boolean("detect_runtime.async_picker", runtime.async_picker)
		end
		if runtime.live_merge ~= nil and type(runtime.live_merge) ~= "boolean" then
			warn_expected_boolean("detect_runtime.live_merge", runtime.live_merge)
		end
		if runtime.cache_ttl_ms ~= nil then
			local ttl = tonumber(runtime.cache_ttl_ms)
			if not ttl or ttl <= 0 then
				warn_config(
					"Invalid detect_runtime.cache_ttl_ms: expected positive number, got "
						.. tostring(runtime.cache_ttl_ms)
				)
			end
		end
	end

	if opts.close_behavior and not vim.tbl_contains(VALID_CLOSE_BEHAVIORS, opts.close_behavior) then
		warn_invalid_choice("close_behavior", opts.close_behavior, VALID_CLOSE_BEHAVIORS)
	end
end

---@return nil
local function sync_config_async()
	if type(vim.fn) ~= "table" or type(vim.fn.fnamemodify) ~= "function" then
		return
	end

	local sync_ok, config_sync = pcall(require, "zignite.rpc.config_sync")
	if sync_ok and type(config_sync.sync_current_async) == "function" then
		pcall(config_sync.sync_current_async)
	end
end

-- A setup function for users to call.
-- It will merge their provided options with the defaults.
---@param opts table|nil
---@return nil
function M.setup(opts)
	opts = opts or {}
	validate_config(opts)
	M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts)
	M.revision = (tonumber(M.revision) or 0) + 1

	M.setup_keymaps()
	sync_config_async()
end

-- Ensure defaults are available without applying side effects (e.g. keymaps).
---@return table
function M.ensure()
	if vim.tbl_isempty(M.options) then
		M.options = vim.tbl_deep_extend("force", {}, M.defaults, {})
	end
	return M.options
end

---@return nil
function M.setup_keymaps()
	if not M.options.keymaps then
		return
	end
	for _, keymap in ipairs(M.options.keymaps) do
		vim.keymap.set(keymap[1], keymap[2], keymap[3], keymap[4])
	end
end

return M
