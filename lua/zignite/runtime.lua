local config = require("zignite.config")
local ui = require("zignite.ui")
local utils = require("zignite.utils")

---@type table
local M = {}

local BUILD_ARG_PLACEHOLDER = "$zignite_args"
local BUILD_ARG_DISPLAY_PLACEHOLDER = "<args>"

---@type table<string, { ok: boolean, argv?: string[] }>
local argv_cache = {}
---@type string[]
local argv_cache_order = {}
local ARGV_CACHE_MAX = 256
---@type table<string, string|nil>
local normalized_runner_cache = {}
---@type string[]
local normalized_runner_order = {}
local NORMALIZED_RUNNER_CACHE_MAX = 128
---@type table<string, string|false>
local shebang_filetype_cache = {}
---@type string[]
local shebang_filetype_cache_order = {}
local SHEBANG_FILETYPE_CACHE_MAX = 256
---@type boolean|nil
local zig_backend_available = nil
local zig_missing_notified = false

local FILETYPE_ALIAS_MAP = {
	["c++"] = "cpp",
	bash = "sh",
	cxx = "cpp",
	javascriptreact = "javascript",
	jsx = "javascript",
	typescriptreact = "typescript",
	tsx = "typescript",
}

local EXTENSION_FILETYPE_MAP = {
	bash = "sh",
	c = "c",
	cc = "cpp",
	cjs = "javascript",
	cpp = "cpp",
	cts = "typescript",
	cxx = "cpp",
	dart = "dart",
	ex = "elixir",
	exs = "elixir",
	f = "fortran",
	f03 = "fortran",
	f08 = "fortran",
	f90 = "fortran",
	f95 = "fortran",
	["for"] = "fortran",
	go = "go",
	hs = "haskell",
	htm = "html",
	html = "html",
	java = "java",
	jl = "julia",
	js = "javascript",
	json = "json",
	kt = "kotlin",
	kts = "kotlin",
	lua = "lua",
	mjs = "javascript",
	mts = "typescript",
	odin = "odin",
	perl = "perl",
	php = "php",
	pl = "perl",
	pm = "perl",
	py = "python",
	pyw = "python",
	r = "r",
	rb = "ruby",
	rs = "rust",
	sh = "sh",
	swift = "swift",
	ts = "typescript",
	tsx = "typescript",
	zig = "zig",
	zsh = "zsh",
}

local TEMP_FILE_EXTENSION_MAP = {
	c = "c",
	cpp = "cpp",
	dart = "dart",
	elixir = "exs",
	fortran = "f90",
	go = "go",
	haskell = "hs",
	html = "html",
	java = "java",
	javascript = "js",
	json = "json",
	julia = "jl",
	kotlin = "kt",
	lua = "lua",
	odin = "odin",
	perl = "pl",
	php = "php",
	python = "py",
	r = "r",
	ruby = "rb",
	rust = "rs",
	sh = "sh",
	swift = "swift",
	typescript = "ts",
	zig = "zig",
	zsh = "zsh",
}

local SHEBANG_FILETYPE_MAP = {
	bash = "sh",
	bun = "javascript",
	deno = "javascript",
	elixir = "elixir",
	julia = "julia",
	lua = "lua",
	node = "javascript",
	nodejs = "javascript",
	perl = "perl",
	php = "php",
	python = "python",
	python3 = "python",
	r = "r",
	rscript = "r",
	ruby = "ruby",
	sh = "sh",
	zsh = "zsh",
}

---@return string
local function get_plugin_path()
	local source = debug.getinfo(1, "S").source
	if source:sub(1, 1) == "@" then
		source = source:sub(2)
	end
	return vim.fn.fnamemodify(source, ":p:h:h:h")
end

local ZIG_EXECUTABLE = get_plugin_path() .. "/zig/zig-out/bin/zignite"

---@param value string
---@return string
local function trim_text(value)
	if type(value) ~= "string" then
		return ""
	end
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param value string
---@return string
local function shellescape_text(value)
	if vim.fn and type(vim.fn.shellescape) == "function" then
		return vim.fn.shellescape(value)
	end
	return value
end

---@param order string[]
---@param key string
---@return nil
local function touch_cache_key(order, key)
	for index, existing in ipairs(order) do
		if existing == key then
			table.remove(order, index)
			break
		end
	end
	order[#order + 1] = key
end

---@param cache table<string, any>
---@param order string[]
---@param max_entries integer
---@param key string
---@param value any
---@return nil
local function set_bounded_cache_entry(cache, order, max_entries, key, value)
	if type(key) ~= "string" or key == "" then
		return
	end
	cache[key] = value
	touch_cache_key(order, key)
	while #order > max_entries do
		local oldest = table.remove(order, 1)
		if oldest ~= nil then
			cache[oldest] = nil
		end
	end
end

---@param cache table<string, any>
---@param order string[]
---@param key string
---@return any
local function get_bounded_cache_entry(cache, order, key)
	local value = cache[key]
	if value ~= nil and type(key) == "string" and key ~= "" then
		touch_cache_key(order, key)
	end
	return value
end

---@param filepath string
---@return string
local function get_file_extension(filepath)
	if not filepath or filepath == "" then
		return ""
	end
	local ext = vim.fn.fnamemodify(filepath, ":e")
	if type(ext) ~= "string" then
		return ""
	end
	return ext:lower()
end

---@param filepath string
---@return string|nil
local function get_filetype_from_shebang(filepath)
	if not filepath or filepath == "" then
		return nil
	end

	local cached = get_bounded_cache_entry(shebang_filetype_cache, shebang_filetype_cache_order, filepath)
	if cached ~= nil then
		if cached == false then
			return nil
		end
		return cached
	end

	if type(vim.fn.filereadable) ~= "function" or vim.fn.filereadable(filepath) ~= 1 then
		set_bounded_cache_entry(
			shebang_filetype_cache,
			shebang_filetype_cache_order,
			SHEBANG_FILETYPE_CACHE_MAX,
			filepath,
			false
		)
		return nil
	end
	if type(vim.fn.readfile) ~= "function" then
		set_bounded_cache_entry(
			shebang_filetype_cache,
			shebang_filetype_cache_order,
			SHEBANG_FILETYPE_CACHE_MAX,
			filepath,
			false
		)
		return nil
	end

	local lines = vim.fn.readfile(filepath, "", 1)
	if type(lines) ~= "table" or type(lines[1]) ~= "string" then
		set_bounded_cache_entry(
			shebang_filetype_cache,
			shebang_filetype_cache_order,
			SHEBANG_FILETYPE_CACHE_MAX,
			filepath,
			false
		)
		return nil
	end

	local first_line = lines[1]
	if not first_line:match("^#!") then
		set_bounded_cache_entry(
			shebang_filetype_cache,
			shebang_filetype_cache_order,
			SHEBANG_FILETYPE_CACHE_MAX,
			filepath,
			false
		)
		return nil
	end

	local interpreter = first_line:match("^#!%s*/usr/bin/env%s+%-S%s+([%w%._%-]+)")
		or first_line:match("^#!%s*/usr/bin/env%s+([%w%._%-]+)")
	if not interpreter then
		local executable = first_line:match("^#!%s*([^%s]+)")
		if executable then
			interpreter = executable:match("([^/]+)$")
		end
	end
	if not interpreter then
		set_bounded_cache_entry(
			shebang_filetype_cache,
			shebang_filetype_cache_order,
			SHEBANG_FILETYPE_CACHE_MAX,
			filepath,
			false
		)
		return nil
	end

	local mapped = SHEBANG_FILETYPE_MAP[interpreter:lower()]
	set_bounded_cache_entry(
		shebang_filetype_cache,
		shebang_filetype_cache_order,
		SHEBANG_FILETYPE_CACHE_MAX,
		filepath,
		mapped or false
	)
	return mapped
end

---@param command string
---@return boolean
local function is_simple_command(command)
	if type(command) ~= "string" or command == "" then
		return false
	end
	if command:find("[%c]") or command:find("[|&;<>`]") then
		return false
	end
	if command:find("%$%(") then
		return false
	end
	return true
end

---@param command string
---@return string[]|nil
local function tokenize_command(command)
	---@type string[]
	local tokens = {}
	---@type string[]
	local current = {}
	local quote = nil
	local i = 1

	---@return nil
	local function push_current()
		if #current > 0 then
			tokens[#tokens + 1] = table.concat(current)
			current = {}
		end
	end

	while i <= #command do
		local ch = command:sub(i, i)
		if quote then
			if ch == quote then
				quote = nil
			elseif ch == "\\" and quote == '"' and i < #command then
				i = i + 1
				current[#current + 1] = command:sub(i, i)
			else
				current[#current + 1] = ch
			end
		else
			if ch == "'" or ch == '"' then
				quote = ch
			elseif ch:match("%s") then
				push_current()
			elseif ch == "\\" and i < #command then
				i = i + 1
				current[#current + 1] = command:sub(i, i)
			else
				current[#current + 1] = ch
			end
		end
		i = i + 1
	end

	if quote then
		return nil
	end

	push_current()
	return tokens
end

---@param command_template string
---@param filepath string
---@return string
local function argv_cache_key(command_template, filepath)
	return tostring(command_template) .. "\0" .. tostring(filepath)
end

---@param key string
---@param value { ok: boolean, argv?: string[] }
---@return nil
local function cache_argv_result(key, value)
	if argv_cache[key] == nil then
		argv_cache_order[#argv_cache_order + 1] = key
		if #argv_cache_order > ARGV_CACHE_MAX then
			local oldest = table.remove(argv_cache_order, 1)
			argv_cache[oldest] = nil
		end
	end
	argv_cache[key] = value
end

---@param filetype string
---@param runner string|string[]|table
---@return string
local function normalized_runner_cache_key(filetype, runner)
	return tostring(filetype) .. "\0" .. tostring(runner)
end

---@param key string
---@param value string
---@return nil
local function cache_normalized_runner(key, value)
	if normalized_runner_cache[key] == nil then
		normalized_runner_order[#normalized_runner_order + 1] = key
		if #normalized_runner_order > NORMALIZED_RUNNER_CACHE_MAX then
			local oldest = table.remove(normalized_runner_order, 1)
			normalized_runner_cache[oldest] = nil
		end
	end
	normalized_runner_cache[key] = value
end

---@param list string[]
---@return string[]
local function copy_list(list)
	---@type string[]
	local out = {}
	for i = 1, #list do
		out[i] = list[i]
	end
	return out
end

---@return boolean
local function has_zig_backend()
	if zig_backend_available == nil then
		zig_backend_available = vim.fn.executable(ZIG_EXECUTABLE) == 1
	end
	return zig_backend_available
end

---@return nil
local function notify_backend_missing_once()
	if zig_missing_notified then
		return
	end
	zig_missing_notified = true
	vim.notify(
		"Zignite executable not found at " .. ZIG_EXECUTABLE .. ", falling back to direct shell execution",
		vim.log.levels.INFO
	)
end

---@param requested_filetype string
---@param filepath string
---@return string
function M.resolve_supported_filetype(requested_filetype, filepath)
	local requested = trim_text(requested_filetype)
	local aliased = FILETYPE_ALIAS_MAP[requested] or requested
	local ext_filetype = EXTENSION_FILETYPE_MAP[get_file_extension(filepath)]

	if aliased ~= "" then
		if config.options.runners[aliased] ~= nil or config.options.build_commands[aliased] ~= nil then
			return aliased
		end
		if ext_filetype and ext_filetype ~= "" then
			return ext_filetype
		end
		local shebang_filetype = get_filetype_from_shebang(filepath)
		if shebang_filetype and shebang_filetype ~= "" then
			return shebang_filetype
		end
		return aliased
	end

	if ext_filetype and ext_filetype ~= "" then
		return ext_filetype
	end
	local shebang_filetype = get_filetype_from_shebang(filepath)
	if shebang_filetype and shebang_filetype ~= "" then
		return shebang_filetype
	end
	return requested
end

---@param filepath string
---@param filetype string
---@return string
function M.build_temp_execution_path(filepath, filetype)
	local temp_path
	if type(vim.fn.tempname) == "function" then
		temp_path = vim.fn.tempname()
	else
		temp_path = os.tmpname()
	end

	local ext = get_file_extension(filepath)
	if ext == "" then
		ext = TEMP_FILE_EXTENSION_MAP[filetype] or ""
	end
	if ext == "" then
		return temp_path
	end
	return temp_path .. "." .. ext
end

---@param filetype string
---@param command_name string
---@param command_template string
---@param mode string
---@return string|nil
function M.resolve_command_arguments(filetype, command_name, command_template, mode)
	if type(command_template) ~= "string" then
		return command_template
	end
	if not command_template:find(BUILD_ARG_PLACEHOLDER, 1, true) then
		return command_template
	end

	if type(vim.fn.input) ~= "function" then
		ui.show_output(
			string.format("Command '%s' requires extra arguments, but input prompt is unavailable.", command_name),
			mode
		)
		return nil
	end

	local prompt = string.format("%s %s args: ", filetype, command_name)
	if filetype == "zig" and command_name == "fetch" then
		prompt = "zig fetch url/path: "
	end

	local entered = vim.fn.input(prompt, "")
	if entered == nil then
		return nil
	end

	local trimmed = trim_text(entered)
	if trimmed == "" then
		ui.show_output(string.format("Command '%s' requires an argument.", command_name), mode)
		return nil
	end

	return (command_template:gsub(BUILD_ARG_PLACEHOLDER, shellescape_text(trimmed)))
end

---@param filetype string
---@param runner string|string[]|table
---@return string|nil
function M.get_normalized_runner_command(filetype, runner)
	local key = normalized_runner_cache_key(filetype, runner)
	local cached = normalized_runner_cache[key]
	if cached ~= nil then
		return cached
	end

	local normalized = utils.normalize_command(runner)
	cache_normalized_runner(key, normalized)
	return normalized
end

---@param command_template string
---@param filepath string
---@return string[]|nil
function M.command_to_argv(command_template, filepath)
	local key = argv_cache_key(command_template, filepath)
	local cached = argv_cache[key]
	if cached ~= nil then
		if cached.ok then
			return copy_list(cached.argv)
		end
		return nil
	end

	if not is_simple_command(command_template) then
		cache_argv_result(key, { ok = false })
		return nil
	end

	local tokens = tokenize_command(command_template)
	if not tokens or #tokens == 0 then
		cache_argv_result(key, { ok = false })
		return nil
	end

	for idx, token in ipairs(tokens) do
		local expanded = utils.substitute_variables_raw(token, filepath)
		if expanded:find("%$[%w_]+") then
			cache_argv_result(key, { ok = false })
			return nil
		end
		tokens[idx] = expanded
	end

	cache_argv_result(key, { ok = true, argv = copy_list(tokens) })
	return tokens
end

---@param final_command string|string[]
---@param argv_command string[]|nil
---@return string|string[]
function M.build_system_command(final_command, argv_command)
	if has_zig_backend() then
		---@type string[]
		local system_command = { ZIG_EXECUTABLE }
		if config.options.timeout and type(config.options.timeout) == "number" then
			system_command[#system_command + 1] = "--timeout=" .. config.options.timeout
		end
		if argv_command and #argv_command > 0 then
			system_command[#system_command + 1] = "--argv"
			for _, arg in ipairs(argv_command) do
				system_command[#system_command + 1] = arg
			end
		else
			system_command[#system_command + 1] = final_command
		end
		return system_command
	end

	notify_backend_missing_once()
	if argv_command and #argv_command > 0 then
		return argv_command
	end
	return final_command
end

---@param command string
---@return boolean
function M.is_reserved_argv_command(command)
	if type(command) ~= "string" then
		return false
	end
	local trimmed = command:match("^%s*(.-)%s*$") or ""
	return trimmed == "--argv" or trimmed:match("^%-%-argv%s+") ~= nil
end

---@param command string
---@return string
function M.command_for_display(command)
	if type(command) ~= "string" then
		return ""
	end
	return (command:gsub(BUILD_ARG_PLACEHOLDER, BUILD_ARG_DISPLAY_PLACEHOLDER))
end

---@return nil
function M.reset()
	zig_backend_available = nil
	zig_missing_notified = false
	argv_cache = {}
	argv_cache_order = {}
	normalized_runner_cache = {}
	normalized_runner_order = {}
	shebang_filetype_cache = {}
	shebang_filetype_cache_order = {}
end

---@return table
function M._debug_state()
	return {
		shebang_filetype_cache = shebang_filetype_cache,
		shebang_filetype_cache_order = shebang_filetype_cache_order,
	}
end

return M
