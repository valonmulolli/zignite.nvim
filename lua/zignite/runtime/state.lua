---@type table
local M = {}

local BUILD_ARG_PLACEHOLDER = "$zignite_args"
local BUILD_ARG_DISPLAY_PLACEHOLDER = "<args>"

---@type table<string, { ok: boolean, argv?: string[] }>
local argv_cache = {}
---@type string[]
local argv_cache_order = {}
local ARGV_CACHE_MAX = 256

---@type table<string, string>
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

M.FILETYPE_ALIAS_MAP = {
	["c++"] = "cpp",
	bash = "sh",
	cxx = "cpp",
	javascriptreact = "javascript",
	jsx = "javascript",
	typescriptreact = "typescript",
	tsx = "typescript",
}

M.EXTENSION_FILETYPE_MAP = {
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

M.TEMP_FILE_EXTENSION_MAP = {
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

M.SHEBANG_FILETYPE_MAP = {
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
	return vim.fn.fnamemodify(source, ":p:h:h:h:h")
end

M.BUILD_ARG_PLACEHOLDER = BUILD_ARG_PLACEHOLDER
M.BUILD_ARG_DISPLAY_PLACEHOLDER = BUILD_ARG_DISPLAY_PLACEHOLDER
M.ZIG_EXECUTABLE = get_plugin_path() .. "/zig/zig-out/bin/zignite"

---@param value string
---@return string
function M.trim_text(value)
	if type(value) ~= "string" then
		return ""
	end
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param value string
---@return string
function M.shellescape_text(value)
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
function M.set_bounded_cache_entry(cache, order, max_entries, key, value)
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
function M.get_bounded_cache_entry(cache, order, key)
	local value = cache[key]
	if value ~= nil and type(key) == "string" and key ~= "" then
		touch_cache_key(order, key)
	end
	return value
end

---@param key string
---@return { ok: boolean, argv?: string[] }|nil
function M.get_argv_cache(key)
	return argv_cache[key]
end

---@param key string
---@param value { ok: boolean, argv?: string[] }
---@return nil
function M.set_argv_cache(key, value)
	M.set_bounded_cache_entry(argv_cache, argv_cache_order, ARGV_CACHE_MAX, key, value)
end

---@param key string
---@return string|nil
function M.get_normalized_runner_cache(key)
	return normalized_runner_cache[key]
end

---@param key string
---@param value string
---@return nil
function M.set_normalized_runner_cache(key, value)
	M.set_bounded_cache_entry(
		normalized_runner_cache,
		normalized_runner_order,
		NORMALIZED_RUNNER_CACHE_MAX,
		key,
		value
	)
end

---@param key string
---@return string|false|nil
function M.get_shebang_cache(key)
	return M.get_bounded_cache_entry(shebang_filetype_cache, shebang_filetype_cache_order, key)
end

---@param key string
---@param value string|false
---@return nil
function M.set_shebang_cache(key, value)
	M.set_bounded_cache_entry(
		shebang_filetype_cache,
		shebang_filetype_cache_order,
		SHEBANG_FILETYPE_CACHE_MAX,
		key,
		value
	)
end

---@param list string[]
---@return string[]
function M.copy_list(list)
	---@type string[]
	local out = {}
	for index = 1, #list do
		out[index] = list[index]
	end
	return out
end

---@return boolean|nil
function M.get_zig_backend_available()
	return zig_backend_available
end

---@param value boolean|nil
---@return nil
function M.set_zig_backend_available(value)
	zig_backend_available = value
end

---@return boolean
function M.get_zig_missing_notified()
	return zig_missing_notified
end

---@param value boolean
---@return nil
function M.set_zig_missing_notified(value)
	zig_missing_notified = value
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
function M.debug_state()
	return {
		shebang_filetype_cache = shebang_filetype_cache,
		shebang_filetype_cache_order = shebang_filetype_cache_order,
	}
end

return M
