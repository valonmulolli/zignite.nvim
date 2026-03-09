local config = require("zignite.config")
local ui = require("zignite.ui")
local utils = require("zignite.utils")

---@type table
local M = {}

-- Constants for error messages
local ERRORS = {
	NO_FILE = "Error: No file path. Please save the buffer.",
	NO_RUNNER = "Error: No runner configured for filetype: %s",
	VISUAL_EMPTY = "Error: Visual selection is empty.",
	TEMP_WRITE_FAIL = "Error: Could not write to temporary file.",
	PROJECT_NOT_FOUND = "Error: Current file is not part of any configured project.",
	PROJECT_NO_COMMAND = "Error: No command configured for project: %s",
	ZIG_EXT = "Error: Zig files must have .zig extension. Current file: %s",
	RESERVED_ARGV = "Error: '--argv' is reserved for Zignite internals. Remove it from your runner/build command.",
}

local LIVE_COMMAND_PRIORITY = { "live", "dev", "watch", "serve", "start", "preview" }
local table_unpack = unpack
local table_module = table
if table_unpack == nil and type(table_module) == "table" then
	table_unpack = rawget(table_module, "unpack")
end

-- Get the plugin directory path
---@return string
local function get_plugin_path()
	local source = debug.getinfo(1, "S").source
	if source:sub(1, 1) == "@" then
		source = source:sub(2)
	end
	-- Ensure absolute path
	return vim.fn.fnamemodify(source, ":p:h:h:h")
end

local PLUGIN_PATH = get_plugin_path()
local ZIG_EXECUTABLE = PLUGIN_PATH .. "/zig/zig-out/bin/zignite"

---@type boolean|nil
local zig_backend_available = nil
local zig_missing_notified = false
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
---@type table<string, string>
local last_build_command_by_filetype = {}
---@type table<string, table>
local tool_command_cache = {}
---@type string[]
local tool_command_cache_order = {}
local TOOL_COMMAND_CACHE_MAX = 128
---@type table<string, string|false>
local shebang_filetype_cache = {}
---@type string[]
local shebang_filetype_cache_order = {}
local SHEBANG_FILETYPE_CACHE_MAX = 256
---@type table<string, table>
local package_script_cache = {}
---@type string[]
local package_script_cache_order = {}
local PACKAGE_SCRIPT_CACHE_MAX = 128
---@type table<string, table>
local make_target_cache = {}
---@type string[]
local make_target_cache_order = {}
local MAKE_TARGET_CACHE_MAX = 128
---@type table<string, table>
local detect_runtime_cache = {}
---@type string[]
local detect_runtime_cache_order = {}
local DETECT_RUNTIME_CACHE_MAX = 256
---@type table<string, table>
local detect_runtime_inflight = {}
---@type table|nil
local detect_worker = nil
local BUILD_ARG_PLACEHOLDER = "$zignite_args"
local BUILD_ARG_DISPLAY_PLACEHOLDER = "<args>"
local DETECT_REQ_BEGIN = "@@ZDET_REQ_BEGIN"
local DETECT_REQ_END = "@@ZDET_REQ_END"
local DETECT_RES_BEGIN = "@@ZDET_RES_BEGIN"
local DETECT_RES_END = "@@ZDET_RES_END"
local DETECT_WORKER_WAIT_MS = 1200
local DETECT_WORKER_REQUEST_TIMEOUT_MS = 3000
local DETECT_RUNTIME_DEFAULT_TTL_MS = 15000
local DETECT_RUNTIME_FAILED_TTL_MS = 1000
local zig_detected_command_templates = {
	["ast-check"] = "zig ast-check $file",
	["build"] = "zig build",
	["build-exe"] = "zig build-exe $file",
	["build-lib"] = "zig build-lib $file",
	["build-obj"] = "zig build-obj $file",
	["env"] = "zig env",
	["fetch"] = "zig fetch " .. BUILD_ARG_PLACEHOLDER,
	["fmt"] = "zig fmt $file",
	["help"] = "zig help",
	["init"] = "zig init",
	["libc"] = "zig libc",
	["run"] = "zig run $file",
	["std"] = "zig std",
	["targets"] = "zig targets",
	["test"] = "zig test $file",
	["test-obj"] = "zig test-obj $file",
	["version"] = "zig version",
	["zen"] = "zig zen",
}
local go_detected_command_templates = {
	bug = "go bug",
	build = "go build",
	clean = "go clean",
	doc = "go doc",
	env = "go env",
	fix = "go fix ./...",
	fmt = "go fmt ./...",
	generate = "go generate ./...",
	get = "go get ./...",
	install = "go install ./...",
	list = "go list ./...",
	mod = "go mod tidy",
	run = "go run .",
	telemetry = "go telemetry",
	test = "go test ./...",
	tool = "go tool",
	version = "go version",
	vet = "go vet ./...",
	work = "go work sync",
}
local cargo_detected_command_templates = {
	add = "cargo add " .. BUILD_ARG_PLACEHOLDER,
	bench = "cargo bench",
	build = "cargo build",
	check = "cargo check",
	clean = "cargo clean",
	clippy = "cargo clippy",
	doc = "cargo doc --open",
	fetch = "cargo fetch",
	fix = "cargo fix",
	["generate-lockfile"] = "cargo generate-lockfile",
	init = "cargo init",
	install = "cargo install " .. BUILD_ARG_PLACEHOLDER,
	["locate-project"] = "cargo locate-project",
	login = "cargo login",
	logout = "cargo logout",
	metadata = "cargo metadata",
	new = "cargo new " .. BUILD_ARG_PLACEHOLDER,
	owner = "cargo owner " .. BUILD_ARG_PLACEHOLDER,
	package = "cargo package",
	publish = "cargo publish",
	remove = "cargo remove " .. BUILD_ARG_PLACEHOLDER,
	rm = "cargo rm " .. BUILD_ARG_PLACEHOLDER,
	run = "cargo run",
	rustc = "cargo rustc",
	rustdoc = "cargo rustdoc",
	search = "cargo search " .. BUILD_ARG_PLACEHOLDER,
	test = "cargo test",
	tree = "cargo tree",
	uninstall = "cargo uninstall " .. BUILD_ARG_PLACEHOLDER,
	update = "cargo update",
	vendor = "cargo vendor",
	["verify-project"] = "cargo verify-project",
	version = "cargo version",
}
local odin_detected_command_templates = {
	build = "odin build .",
	check = "odin check .",
	doc = "odin doc .",
	query = "odin query " .. BUILD_ARG_PLACEHOLDER,
	run = "odin run .",
	test = "odin test .",
	version = "odin version",
}
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
	swift = "swift",
	zsh = "zsh",
}

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

---@param command string
---@return string
local function command_for_display(command)
	if type(command) ~= "string" then
		return ""
	end
	return (command:gsub(BUILD_ARG_PLACEHOLDER, BUILD_ARG_DISPLAY_PLACEHOLDER))
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
---@param filetype string
---@return string
local function build_temp_execution_path(filepath, filetype)
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
---@param max_entries number
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

---@param requested_filetype string
---@param filepath string
---@return string
local function resolve_supported_filetype(requested_filetype, filepath)
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

---@param filetype string
---@param command_name string
---@param command_template string
---@param mode string
---@return string|nil
local function resolve_command_arguments(filetype, command_name, command_template, mode)
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

	local escaped = shellescape_text(trimmed)
	return (command_template:gsub(BUILD_ARG_PLACEHOLDER, escaped))
end

---@return nil
local function ensure_config()
	config.ensure()
end

---@return number
local function now_ms()
	local uv = vim.uv or vim.loop
	if uv and type(uv.hrtime) == "function" then
		return uv.hrtime() / 1e6
	end
	return os.clock() * 1000
end

---@return table
local function get_detect_runtime_options()
	local runtime = config.options.detect_runtime or {}
	local ttl = tonumber(runtime.cache_ttl_ms) or DETECT_RUNTIME_DEFAULT_TTL_MS
	if ttl <= 0 then
		ttl = DETECT_RUNTIME_DEFAULT_TTL_MS
	end

	return {
		async_picker = runtime.async_picker ~= false,
		cache_ttl_ms = ttl,
		live_merge = runtime.live_merge ~= false,
	}
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
	local tokens = {}
	local current = {}
	local quote = nil
	local i = 1

	---@return nil
	local function push_current()
		if #current > 0 then
			table.insert(tokens, table.concat(current))
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
				table.insert(current, command:sub(i, i))
			else
				table.insert(current, ch)
			end
		else
			if ch == "'" or ch == '"' then
				quote = ch
			elseif ch:match("%s") then
				push_current()
			elseif ch == "\\" and i < #command then
				i = i + 1
				table.insert(current, command:sub(i, i))
			else
				table.insert(current, ch)
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
		table.insert(argv_cache_order, key)
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
		table.insert(normalized_runner_order, key)
		if #normalized_runner_order > NORMALIZED_RUNNER_CACHE_MAX then
			local oldest = table.remove(normalized_runner_order, 1)
			normalized_runner_cache[oldest] = nil
		end
	end

	normalized_runner_cache[key] = value
end

---@param filetype string
---@param runner string|string[]|table
---@return string|nil
local function get_normalized_runner_command(filetype, runner)
	local key = normalized_runner_cache_key(filetype, runner)
	local cached = normalized_runner_cache[key]
	if cached ~= nil then
		return cached
	end

	local normalized = utils.normalize_command(runner)
	cache_normalized_runner(key, normalized)
	return normalized
end

---@param list string[]
---@return string[]
local function copy_list(list)
	local out = {}
	for i = 1, #list do
		out[i] = list[i]
	end
	return out
end

---@param timeout_ms integer
---@param callback fun():nil
---@return table|nil
local function start_request_timer(timeout_ms, callback)
	local uv = vim.uv or vim.loop
	if not uv or type(uv.new_timer) ~= "function" then
		return nil
	end

	local timer = uv.new_timer()
	if not timer then
		return nil
	end

	timer:start(timeout_ms, 0, vim.schedule_wrap(function()
		pcall(function()
			timer:stop()
		end)
		pcall(function()
			timer:close()
		end)
		callback()
	end))

	return timer
end

---@param timer table|nil
---@return nil
local function stop_request_timer(timer)
	if not timer then
		return
	end
	pcall(function()
		timer:stop()
	end)
	pcall(function()
		timer:close()
	end)
end

---@param command_template string
---@param filepath string
---@return string[]|nil
local function command_to_argv(command_template, filepath)
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
local function build_system_command(final_command, argv_command)
	if has_zig_backend() then
		local system_command = { ZIG_EXECUTABLE }
		if config.options.timeout and type(config.options.timeout) == "number" then
			table.insert(system_command, "--timeout=" .. config.options.timeout)
		end
		if argv_command and #argv_command > 0 then
			table.insert(system_command, "--argv")
			for _, arg in ipairs(argv_command) do
				table.insert(system_command, arg)
			end
		else
			table.insert(system_command, final_command)
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
local function is_reserved_argv_command(command)
	if type(command) ~= "string" then
		return false
	end

	local trimmed = command:match("^%s*(.-)%s*$") or ""
	return trimmed == "--argv" or trimmed:match("^%-%-argv%s+") ~= nil
end

---@param build_cmds table<string, string>
---@return string|nil
local function select_live_command_name(build_cmds)
	for _, candidate in ipairs(LIVE_COMMAND_PRIORITY) do
		if build_cmds[candidate] then
			return candidate
		end
	end
	return nil
end

---@param tbl table<string, string>|nil
---@return table<string, string>
local function copy_string_map(tbl)
	local out = {}
	if type(tbl) ~= "table" then
		return out
	end
	for key, value in pairs(tbl) do
		if type(key) == "string" and type(value) == "string" then
			out[key] = value
		end
	end
	return out
end

---@param lines string[]|nil
---@return table<string, string>
local function parse_zig_help_commands(lines)
	local commands = {}
	local in_commands_section = false

	for _, raw_line in ipairs(lines or {}) do
		local line = tostring(raw_line or "")
		if not in_commands_section then
			if line:match("^Commands:%s*$") then
				in_commands_section = true
			end
		else
			if line:match("^General Options:%s*$") then
				break
			end

			local cmd = line:match("^%s+([%w%+%-]+)%s+")
			if cmd then
				local template = zig_detected_command_templates[cmd]
				if template then
					commands[cmd] = template
				end
			end
		end
	end

	return commands
end

---@param lines string[]|nil
---@return table<string, string>
local function parse_go_help_commands(lines)
	local commands = {}
	local in_commands_section = false

	for _, raw_line in ipairs(lines or {}) do
		local line = tostring(raw_line or "")
		if not in_commands_section then
			if line:match("^The commands are:%s*$") then
				in_commands_section = true
			end
		else
			if line:match("^Additional help topics:%s*$") or line:match('^Use "go help') then
				break
			end

			local cmd = line:match("^%s+([%w%-]+)%s+")
			if cmd and cmd ~= "help" then
				commands[cmd] = go_detected_command_templates[cmd] or ("go " .. cmd)
			end
		end
	end

	return commands
end

---@param lines string[]|nil
---@return table<string, string>
local function parse_cargo_commands(lines)
	local commands = {}
	local in_commands_section = false

	for _, raw_line in ipairs(lines or {}) do
		local line = tostring(raw_line or "")
		if not in_commands_section then
			if line:match("^Installed Commands:%s*$") then
				in_commands_section = true
			end
		else
			local cmd = line:match("^%s+([%w%-]+)%s+")
			if cmd and #cmd > 1 and cmd ~= "help" then
				commands[cmd] = cargo_detected_command_templates[cmd] or ("cargo " .. cmd)
			end
		end
	end

	return commands
end

---@param lines string[]|nil
---@return table<string, string>
local function parse_odin_commands(lines)
	local commands = {}
	local in_commands_section = false

	for _, raw_line in ipairs(lines or {}) do
		local line = tostring(raw_line or "")
		if not in_commands_section then
			if line:match("^Commands:%s*$") then
				in_commands_section = true
			end
		else
			if line:match("^Flags:%s*$") or line:match("^Examples?:%s*$") then
				break
			end

			local cmd = line:match("^%s+([%w%-]+)%s+")
			if cmd and cmd ~= "help" then
				commands[cmd] = odin_detected_command_templates[cmd] or ("odin " .. cmd)
			end
		end
	end

	return commands
end

---@param lines string[]|nil
---@return string[]
local function normalize_detected_names(lines)
	local normalized = {}
	local seen = {}
	for _, raw_line in ipairs(lines or {}) do
		local line = trim_text(raw_line)
		local name = line:match("^([%w%+%-_]+)") or ""
		if name:match("^[%l][%w%+%-_]*$") and not seen[name] then
			seen[name] = true
			normalized[#normalized + 1] = name
		end
	end
	return normalized
end

---@param tool string
---@param names string[]
---@return table<string, string>
local function build_detected_templates_from_names(tool, names)
	local templates
	local default_prefix

	if tool == "zig" then
		templates = zig_detected_command_templates
		default_prefix = "zig "
	elseif tool == "go" then
		templates = go_detected_command_templates
		default_prefix = "go "
	elseif tool == "cargo" then
		templates = cargo_detected_command_templates
		default_prefix = "cargo "
	elseif tool == "odin" then
		templates = odin_detected_command_templates
		default_prefix = "odin "
	else
		return {}
	end

	local commands = {}
	for _, name in ipairs(normalize_detected_names(names)) do
		commands[name] = templates[name] or (default_prefix .. name)
	end

	return commands
end

---@param worker table
---@return nil
local function flush_detect_worker_fallbacks(worker)
	if not worker or not worker.pending then
		return
	end

	for _, request in pairs(worker.pending) do
		stop_request_timer(request.timer)
		if type(request.callbacks) == "table" then
			for _, callback in ipairs(request.callbacks) do
				if type(callback) == "function" then
					pcall(callback, nil)
				end
			end
		end
		request.failed = true
		request.completed = true
	end

	worker.pending = {}
	worker.active_id = nil
	worker.active_lines = {}
end

---@param worker table
---@param data string[]|nil
---@return nil
local function handle_detect_worker_stdout(worker, data)
	if type(data) ~= "table" then
		return
	end

	for _, raw_line in ipairs(data) do
		local line = tostring(raw_line or "")
		if line ~= "" then
			local begin_id = line:match("^" .. DETECT_RES_BEGIN .. "%s+(%d+)$")
			if begin_id then
				worker.active_id = tonumber(begin_id)
				worker.active_lines = {}
				goto continue
			end

				if worker.active_id then
					local end_id = line:match("^" .. DETECT_RES_END .. "%s+(%d+)$")
					if end_id and tonumber(end_id) == worker.active_id then
						local request = worker.pending[worker.active_id]
						worker.pending[worker.active_id] = nil
						local completed_lines = worker.active_lines
						worker.active_id = nil
						worker.active_lines = {}

						if request then
							stop_request_timer(request.timer)
							if type(request.callbacks) == "table" then
								local commands = build_detected_templates_from_names(request.tool or "", completed_lines)
								for _, callback in ipairs(request.callbacks) do
									if type(callback) == "function" then
										pcall(callback, copy_string_map(commands))
									end
								end
							end
							request.lines = completed_lines
							request.completed = true
							request.failed = false
						end
					else
					if line:sub(1, 1) == "\t" then
						worker.active_lines[#worker.active_lines + 1] = line:sub(2)
					else
						worker.active_lines[#worker.active_lines + 1] = line
					end
				end
			end
		end

		::continue::
	end
end

---@return table|nil
local function ensure_detect_worker()
	if not has_zig_backend() then
		return nil
	end

	if type(vim.fn.jobstart) ~= "function" or type(vim.fn.chansend) ~= "function" then
		return nil
	end

	if detect_worker and type(detect_worker.job_id) == "number" and detect_worker.job_id > 0 then
		return detect_worker
	end

	local worker = {
		job_id = nil,
		next_request_id = 0,
		pending = {},
		active_id = nil,
		active_lines = {},
	}

	local job_id = vim.fn.jobstart({ ZIG_EXECUTABLE, "--detect-daemon" }, {
		stdout_buffered = false,
		on_stdout = function(_, data)
			handle_detect_worker_stdout(worker, data)
		end,
		on_exit = function()
			if detect_worker == worker then
				detect_worker = nil
			end
			flush_detect_worker_fallbacks(worker)
		end,
	})

	if type(job_id) ~= "number" or job_id <= 0 then
		return nil
	end

	worker.job_id = job_id
	detect_worker = worker
	return worker
end

---@param tool string
---@return table<string, string>|nil
local function detect_with_zig_worker(tool)
	if type(vim.wait) ~= "function" then
		return nil
	end

	local worker = ensure_detect_worker()
	if not worker then
		return nil
	end

	worker.next_request_id = worker.next_request_id + 1
	local request_id = worker.next_request_id
	local request = {
		completed = false,
		failed = false,
		lines = {},
	}
	worker.pending[request_id] = request

	local payload = string.format(
		"%s %d %s\n%s %d\n",
		DETECT_REQ_BEGIN,
		request_id,
		tool,
		DETECT_REQ_END,
		request_id
	)
	local ok_send = pcall(vim.fn.chansend, worker.job_id, payload)
	if not ok_send then
		worker.pending[request_id] = nil
		if type(vim.fn.jobstop) == "function" then
			pcall(vim.fn.jobstop, worker.job_id)
		end
		if detect_worker == worker then
			detect_worker = nil
		end
		return nil
	end

	local ok_wait = vim.wait(DETECT_WORKER_WAIT_MS, function()
		return request.completed == true
	end, 20)

	if not ok_wait then
		worker.pending[request_id] = nil
		return nil
	end
	if request.failed then
		return nil
	end

	local commands = build_detected_templates_from_names(tool, request.lines)
	if vim.tbl_isempty(commands) then
		return nil
	end
	return commands
end

---@param tool string
---@param on_done fun(commands: table<string, string>|nil):nil
---@return boolean
local function detect_with_zig_worker_async(tool, on_done)
	local worker = ensure_detect_worker()
	if not worker then
		return false
	end

	worker.next_request_id = worker.next_request_id + 1
	local request_id = worker.next_request_id
	local request = {
		tool = tool,
		callbacks = { on_done },
	}
	request.timer = start_request_timer(DETECT_WORKER_REQUEST_TIMEOUT_MS, function()
		if worker.pending[request_id] ~= request then
			return
		end

		worker.pending[request_id] = nil
		if worker.active_id == request_id then
			worker.active_id = nil
			worker.active_lines = {}
		end
		if type(request.callbacks) == "table" then
			for _, callback in ipairs(request.callbacks) do
				if type(callback) == "function" then
					pcall(callback, nil)
				end
			end
		end
		if type(vim.fn.jobstop) == "function" then
			pcall(vim.fn.jobstop, worker.job_id)
		end
		if detect_worker == worker then
			detect_worker = nil
		end
	end)
	worker.pending[request_id] = request

	local payload = string.format(
		"%s %d %s\n%s %d\n",
		DETECT_REQ_BEGIN,
		request_id,
		tool,
		DETECT_REQ_END,
		request_id
	)
	local ok_send = pcall(vim.fn.chansend, worker.job_id, payload)
	if not ok_send then
		stop_request_timer(request.timer)
		worker.pending[request_id] = nil
		if type(vim.fn.jobstop) == "function" then
			pcall(vim.fn.jobstop, worker.job_id)
		end
		if detect_worker == worker then
			detect_worker = nil
		end
		return false
	end

	return true
end

---@param tool string
---@return table<string, string>|nil
local function detect_with_zig_once(tool)
	if not has_zig_backend() or type(vim.fn.systemlist) ~= "function" then
		return nil
	end

	local output_lines = vim.fn.systemlist({ ZIG_EXECUTABLE, "--detect", "--tool=" .. tool })
	local shell_error = (vim.v and tonumber(vim.v.shell_error)) or 0
	if type(output_lines) ~= "table" or shell_error ~= 0 then
		return nil
	end

	local commands = build_detected_templates_from_names(tool, output_lines)
	if vim.tbl_isempty(commands) then
		return nil
	end
	return commands
end

---@param tool string
---@param on_done fun(commands: table<string, string>|nil):nil
---@return boolean
local function detect_with_zig_once_async(tool, on_done)
	if not has_zig_backend() then
		return false
	end
	if type(vim.fn.jobstart) ~= "function" then
		return false
	end

	local output_lines = {}
	local job_id = vim.fn.jobstart({ ZIG_EXECUTABLE, "--detect", "--tool=" .. tool }, {
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data)
			if type(data) ~= "table" then
				return
			end
			for _, raw_line in ipairs(data) do
				local line = trim_text(tostring(raw_line or ""))
				if line ~= "" then
					output_lines[#output_lines + 1] = line
				end
			end
		end,
		on_exit = function(_, exit_code)
			if exit_code ~= 0 then
				on_done(nil)
				return
			end
			local commands = build_detected_templates_from_names(tool, output_lines)
			on_done(commands)
		end,
	})

	if type(job_id) ~= "number" or job_id <= 0 then
		return false
	end

	return true
end

---@param tool string
---@return table<string, string>|nil
local function detect_commands_with_zig_backend(tool)
	local commands = detect_with_zig_worker(tool)
	if commands ~= nil then
		return commands
	end
	return detect_with_zig_once(tool)
end

---@param tool string
---@param on_done fun(commands: table<string, string>|nil):nil
---@return nil
local function detect_commands_with_zig_backend_async(tool, on_done)
	local ok_worker = detect_with_zig_worker_async(tool, on_done)
	if ok_worker then
		return
	end

	local ok_once = detect_with_zig_once_async(tool, on_done)
	if ok_once then
		return
	end

	on_done(nil)
end

---@param cache_key string
---@param tool string
---@param executable string
---@param command_argv string[]
---@param parser fun(lines: string[]): table<string, string>
---@return table<string, string>
local function detect_commands_from_tool(cache_key, tool, executable, command_argv, parser)
	local cached = get_bounded_cache_entry(tool_command_cache, tool_command_cache_order, cache_key)
	if cached ~= nil then
		return copy_string_map(cached)
	end

	local zig_detected = detect_commands_with_zig_backend(tool)
	if zig_detected ~= nil then
		set_bounded_cache_entry(tool_command_cache, tool_command_cache_order, TOOL_COMMAND_CACHE_MAX, cache_key, zig_detected)
		return copy_string_map(zig_detected)
	end

	if type(vim.fn.executable) ~= "function" or vim.fn.executable(executable) ~= 1 then
		set_bounded_cache_entry(tool_command_cache, tool_command_cache_order, TOOL_COMMAND_CACHE_MAX, cache_key, {})
		return {}
	end

	if type(vim.fn.systemlist) ~= "function" then
		set_bounded_cache_entry(tool_command_cache, tool_command_cache_order, TOOL_COMMAND_CACHE_MAX, cache_key, {})
		return {}
	end

	local output_lines = vim.fn.systemlist(command_argv)
	local shell_error = (vim.v and tonumber(vim.v.shell_error)) or 0
	if type(output_lines) ~= "table" or shell_error ~= 0 then
		set_bounded_cache_entry(tool_command_cache, tool_command_cache_order, TOOL_COMMAND_CACHE_MAX, cache_key, {})
		return {}
	end

	local detected = parser(output_lines)
	set_bounded_cache_entry(tool_command_cache, tool_command_cache_order, TOOL_COMMAND_CACHE_MAX, cache_key, detected)
	return copy_string_map(detected)
end

---@param cache_key string
---@param tool string
---@param executable string
---@param command_argv string[]
---@param parser fun(lines: string[]): table<string, string>
---@param on_done fun(commands: table<string, string>|nil):nil
---@param force_refresh boolean|nil
---@return nil
local function detect_commands_from_tool_async(
	cache_key,
	tool,
	executable,
	command_argv,
	parser,
	on_done,
	force_refresh
)
	local cached = get_bounded_cache_entry(tool_command_cache, tool_command_cache_order, cache_key)
	if force_refresh ~= true and cached ~= nil then
		on_done(copy_string_map(cached))
		return
	end

	local function run_command_fallback()
		if type(vim.fn.executable) ~= "function" or vim.fn.executable(executable) ~= 1 then
			set_bounded_cache_entry(tool_command_cache, tool_command_cache_order, TOOL_COMMAND_CACHE_MAX, cache_key, {})
			on_done({})
			return
		end

		if type(vim.fn.jobstart) == "function" then
			local lines = {}
			local job_id = vim.fn.jobstart(command_argv, {
				stdout_buffered = true,
				stderr_buffered = true,
				on_stdout = function(_, data)
					if type(data) ~= "table" then
						return
					end
					for _, raw_line in ipairs(data) do
						local line = tostring(raw_line or "")
						if trim_text(line) ~= "" then
							lines[#lines + 1] = line
						end
					end
				end,
				on_stderr = function(_, data)
					if type(data) ~= "table" then
						return
					end
					for _, raw_line in ipairs(data) do
						local line = tostring(raw_line or "")
						if trim_text(line) ~= "" then
							lines[#lines + 1] = line
						end
					end
				end,
				on_exit = function(_, exit_code)
					if tonumber(exit_code) ~= 0 then
						on_done(nil)
						return
					end
					local detected = parser(lines)
					set_bounded_cache_entry(tool_command_cache, tool_command_cache_order, TOOL_COMMAND_CACHE_MAX, cache_key, detected)
					on_done(copy_string_map(detected))
				end,
			})
			if type(job_id) == "number" and job_id > 0 then
				return
			end
		end

		if type(vim.fn.systemlist) == "function" then
			local output_lines = vim.fn.systemlist(command_argv)
			local shell_error = (vim.v and tonumber(vim.v.shell_error)) or 0
			if type(output_lines) ~= "table" or shell_error ~= 0 then
				on_done(nil)
				return
			end

			local detected = parser(output_lines)
			set_bounded_cache_entry(tool_command_cache, tool_command_cache_order, TOOL_COMMAND_CACHE_MAX, cache_key, detected)
			on_done(copy_string_map(detected))
			return
		end

		on_done(nil)
	end

	detect_commands_with_zig_backend_async(tool, function(zig_detected)
		if zig_detected ~= nil then
			set_bounded_cache_entry(
				tool_command_cache,
				tool_command_cache_order,
				TOOL_COMMAND_CACHE_MAX,
				cache_key,
				zig_detected
			)
			on_done(copy_string_map(zig_detected))
			return
		end
		run_command_fallback()
	end)
end

---@param path string
---@return string|nil
local function get_file_mtime_key(path)
	local uv = vim.uv or vim.loop
	if not uv or type(uv.fs_stat) ~= "function" then
		return nil
	end

	local stat = uv.fs_stat(path)
	if not stat then
		return nil
	end

	local mtime = stat.mtime or {}
	return string.format("%s:%s:%s", tostring(stat.size or 0), tostring(mtime.sec or 0), tostring(mtime.nsec or 0))
end

---@param filepath string
---@return string
local function resolve_project_root_for_detection(filepath)
	local root = utils.get_project_root(filepath, config.options.project)
	if root and root ~= "" then
		return vim.fs.normalize(root)
	end
	local fallback = vim.fn.fnamemodify(filepath, ":h")
	return vim.fs.normalize(fallback)
end

---@param filetype string
---@param filepath string
---@return string
local function detect_runtime_cache_key(filetype, filepath)
	return string.format("%s::%s", tostring(filetype or ""), resolve_project_root_for_detection(filepath))
end

---@param path string
---@return string
local function detect_file_signature(path)
	if type(vim.fn.filereadable) ~= "function" or vim.fn.filereadable(path) ~= 1 then
		return "missing"
	end
	return get_file_mtime_key(path) or "unknown"
end

---@param filetype string
---@param filepath string
---@return string|nil
local function get_mtime_signature_for_filetype(filetype, filepath)
	local root = resolve_project_root_for_detection(filepath)

	if filetype == "c" or filetype == "cpp" then
		local makefile_path = vim.fs.joinpath(root, "Makefile")
		return "makefile:" .. detect_file_signature(makefile_path)
	end

	if filetype == "javascript" or filetype == "typescript" then
		local package_json_path = vim.fs.joinpath(root, "package.json")
		return "package.json:" .. detect_file_signature(package_json_path)
	end

	if filetype == "java" or filetype == "kotlin" then
		local signatures = {
			"pom.xml:" .. detect_file_signature(vim.fs.joinpath(root, "pom.xml")),
			"gradlew:" .. detect_file_signature(vim.fs.joinpath(root, "gradlew")),
			"build.gradle:" .. detect_file_signature(vim.fs.joinpath(root, "build.gradle")),
			"build.gradle.kts:" .. detect_file_signature(vim.fs.joinpath(root, "build.gradle.kts")),
		}
		return table.concat(signatures, "|")
	end

	local tool_name = nil
	if filetype == "zig" then
		tool_name = "zig"
	elseif filetype == "go" then
		tool_name = "go"
	elseif filetype == "rust" then
		tool_name = "cargo"
	elseif filetype == "odin" then
		tool_name = "odin"
	end

	if tool_name then
		local executable_path = nil
		if type(vim.fn.exepath) == "function" then
			local resolved = vim.fn.exepath(tool_name)
			if type(resolved) == "string" and resolved ~= "" then
				executable_path = resolved
			end
		end

		if executable_path then
			return string.format(
				"tool:%s:%s:%s",
				tool_name,
				executable_path,
				get_file_mtime_key(executable_path) or "unknown"
			)
		end
		return "tool:" .. tool_name
	end

	return nil
end

---@param entry table|nil
---@param ttl_ms number
---@param mtime_signature string|nil
---@return boolean
local function is_cache_stale(entry, ttl_ms, mtime_signature)
	if type(entry) ~= "table" then
		return true
	end
	if mtime_signature ~= nil and entry.mtime_signature ~= mtime_signature then
		return true
	end
	local updated_at_ms = tonumber(entry.updated_at_ms) or 0
	local effective_ttl_ms = ttl_ms
	if entry.status == "failed" then
		effective_ttl_ms = math.min(ttl_ms, DETECT_RUNTIME_FAILED_TTL_MS)
	end
	return (now_ms() - updated_at_ms) > effective_ttl_ms
end

---@param payload string
---@return table<string, string|number|boolean|table|nil>|nil
local function decode_json_payload(payload)
	if type(payload) ~= "string" or payload == "" then
		return nil
	end

	if vim.json and type(vim.json.decode) == "function" then
		local ok, decoded = pcall(vim.json.decode, payload)
		if ok then
			return decoded
		end
	end

	if vim.fn and type(vim.fn.json_decode) == "function" then
		local ok, decoded = pcall(vim.fn.json_decode, payload)
		if ok then
			return decoded
		end
	end

	return nil
end

---@param flag string
---@return boolean
local function is_detection_enabled(flag)
	local detect = config.options.detect or {}
	local value = detect[flag]
	if value == nil then
		return true
	end
	return value == true
end

---@param lines string[]|nil
---@return table<string, string>
local function parse_makefile_targets(lines)
	local commands = {}

	for _, raw_line in ipairs(lines or {}) do
		local line = tostring(raw_line or "")
		if line:match("^%s*$") or line:match("^%s*#") then
			goto continue
		end
		if line:match("^\t") then
			goto continue
		end
		if line:match("^%s*[%w%._%-]+%s*[:+?]?=") then
			goto continue
		end

		local target_segment = line:match("^%s*([^:]+)%s*:")
		if not target_segment then
			goto continue
		end

		for raw_target in target_segment:gmatch("%S+") do
			local target = trim_text(raw_target)
			if
				target ~= ""
				and target ~= "|"
				and not target:match("^%.")
				and not target:find("%%", 1, true)
				and not target:find("%$%(", 1, true)
			then
				commands[target] = "make " .. target
			end
		end

		::continue::
	end

	return commands
end

---@param filepath string
---@return table<string, string>
local function detect_makefile_targets(filepath)
	if not filepath or filepath == "" then
		return {}
	end
	if type(vim.fn.filereadable) ~= "function" or type(vim.fn.readfile) ~= "function" then
		return {}
	end

	local root = utils.get_project_root(filepath, config.options.project)
	if not root then
		root = vim.fn.fnamemodify(filepath, ":h")
	end

	local makefile_path = vim.fs.joinpath(root, "Makefile")
	if vim.fn.filereadable(makefile_path) ~= 1 then
		return {}
	end

	local mtime_key = get_file_mtime_key(makefile_path)
	local cached = get_bounded_cache_entry(make_target_cache, make_target_cache_order, makefile_path)
	if cached and cached.mtime_key == mtime_key then
		return copy_string_map(cached.commands)
	end

	local lines = vim.fn.readfile(makefile_path)
	if type(lines) ~= "table" then
		set_bounded_cache_entry(
			make_target_cache,
			make_target_cache_order,
			MAKE_TARGET_CACHE_MAX,
			makefile_path,
			{ mtime_key = mtime_key, commands = {} }
		)
		return {}
	end

	local commands = parse_makefile_targets(lines)
	set_bounded_cache_entry(
		make_target_cache,
		make_target_cache_order,
		MAKE_TARGET_CACHE_MAX,
		makefile_path,
		{
			mtime_key = mtime_key,
			commands = copy_string_map(commands),
		}
	)
	return commands
end

---@param filepath string
---@return table<string, string>
local function detect_package_scripts(filepath)
	if not filepath or filepath == "" then
		return {}
	end

	if type(vim.fn.filereadable) ~= "function" or type(vim.fn.readfile) ~= "function" then
		return {}
	end

	local root = utils.get_project_root(filepath, config.options.project)
	if not root then
		root = vim.fn.fnamemodify(filepath, ":h")
	end

	local package_json_path = vim.fs.joinpath(root, "package.json")
	if vim.fn.filereadable(package_json_path) ~= 1 then
		return {}
	end

	local mtime_key = get_file_mtime_key(package_json_path)
	local cached = get_bounded_cache_entry(package_script_cache, package_script_cache_order, package_json_path)
	if cached and cached.mtime_key == mtime_key then
		return copy_string_map(cached.commands)
	end

	local lines = vim.fn.readfile(package_json_path)
	if type(lines) ~= "table" or #lines == 0 then
		set_bounded_cache_entry(
			package_script_cache,
			package_script_cache_order,
			PACKAGE_SCRIPT_CACHE_MAX,
			package_json_path,
			{ mtime_key = mtime_key, commands = {} }
		)
		return {}
	end

	local parsed = decode_json_payload(table.concat(lines, "\n"))
	local scripts = parsed and parsed.scripts
	local commands = {}

	if type(scripts) == "table" then
		for script_name, script_value in pairs(scripts) do
			if type(script_name) == "string" and type(script_value) == "string" then
				if script_name == "start" then
					commands.start = "npm start"
				elseif script_name == "test" then
					commands.test = "npm test"
				else
					commands[script_name] = "npm run " .. script_name
				end
			end
		end
	end

	set_bounded_cache_entry(
		package_script_cache,
		package_script_cache_order,
		PACKAGE_SCRIPT_CACHE_MAX,
		package_json_path,
		{
			mtime_key = mtime_key,
			commands = copy_string_map(commands),
		}
	)
	return commands
end

---@param filepath string
---@return table<string, string>
local function detect_java_like_project_commands(filepath)
	if not filepath or filepath == "" or type(vim.fn.filereadable) ~= "function" then
		return {}
	end

	---@param start_path string
	---@param candidates string[]
	---@param max_up number
	---@return string|nil
	local function find_root_for_files(start_path, candidates, max_up)
		local dir = vim.fn.fnamemodify(start_path, ":h")
		local limit = max_up or 10
		for _ = 1, limit do
			for _, file_name in ipairs(candidates) do
				if vim.fn.filereadable(vim.fs.joinpath(dir, file_name)) == 1 then
					return dir
				end
			end
			local parent = vim.fn.fnamemodify(dir, ":h")
			if parent == dir then
				break
			end
			dir = parent
		end
		return nil
	end

	local root = utils.get_project_root(filepath, config.options.project)
	if not root then
		root = find_root_for_files(filepath, {
			"pom.xml",
			"gradlew",
			"build.gradle",
			"build.gradle.kts",
		}, 12) or vim.fn.fnamemodify(filepath, ":h")
	end

	local commands = {}
	local pom_xml = vim.fs.joinpath(root, "pom.xml")
	local gradle_wrapper = vim.fs.joinpath(root, "gradlew")
	local gradle_build = vim.fs.joinpath(root, "build.gradle")
	local gradle_build_kts = vim.fs.joinpath(root, "build.gradle.kts")

	if vim.fn.filereadable(pom_xml) == 1 then
		commands["mvn-build"] = "mvn compile"
		commands["mvn-test"] = "mvn test"
		commands["mvn-package"] = "mvn package"
		commands["mvn-run"] = "mvn exec:java"
	end

	if vim.fn.filereadable(gradle_wrapper) == 1 then
		commands["gradle-build"] = "./gradlew build"
		commands["gradle-test"] = "./gradlew test"
		commands["gradle-clean"] = "./gradlew clean"
		commands["gradle-run"] = "./gradlew run"
	elseif vim.fn.filereadable(gradle_build) == 1 or vim.fn.filereadable(gradle_build_kts) == 1 then
		commands["gradle-build"] = "gradle build"
		commands["gradle-test"] = "gradle test"
		commands["gradle-clean"] = "gradle clean"
		commands["gradle-run"] = "gradle run"
	end

	return commands
end

---@return table<string, string>
local function detect_zig_tool_commands()
	return detect_commands_from_tool("zig", "zig", "zig", { "zig", "--help" }, parse_zig_help_commands)
end

---@return table<string, string>
local function detect_go_tool_commands()
	return detect_commands_from_tool("go", "go", "go", { "go", "help" }, parse_go_help_commands)
end

---@return table<string, string>
local function detect_rust_tool_commands()
	return detect_commands_from_tool("cargo", "cargo", "cargo", { "cargo", "--list" }, parse_cargo_commands)
end

---@return table<string, string>
local function detect_odin_tool_commands()
	return detect_commands_from_tool("odin", "odin", "odin", { "odin", "help" }, parse_odin_commands)
end

---@param filetype string
---@param filepath string
---@return table<string, string>
local function detect_tool_commands_for_filetype(filetype, filepath)
	if filetype == "zig" and is_detection_enabled("zig") then
		return detect_zig_tool_commands()
	end
	if filetype == "go" and is_detection_enabled("go") then
		return detect_go_tool_commands()
	end
	if filetype == "rust" and is_detection_enabled("rust") then
		return detect_rust_tool_commands()
	end
	if filetype == "odin" and is_detection_enabled("odin") then
		return detect_odin_tool_commands()
	end
	if (filetype == "c" or filetype == "cpp") and is_detection_enabled("c_cpp_make") then
		return detect_makefile_targets(filepath)
	end
	if (filetype == "javascript" or filetype == "typescript") and is_detection_enabled("js_package_scripts") then
		return detect_package_scripts(filepath)
	end
	if (filetype == "java" or filetype == "kotlin") and is_detection_enabled("java_kotlin_project") then
		return detect_java_like_project_commands(filepath)
	end
	return {}
end

---@param filetype string
---@return boolean
local function can_detect_build_commands_for_filetype(filetype)
	if filetype == "zig" and is_detection_enabled("zig") then
		return true
	end
	if filetype == "go" and is_detection_enabled("go") then
		return true
	end
	if filetype == "rust" and is_detection_enabled("rust") then
		return true
	end
	if filetype == "odin" and is_detection_enabled("odin") then
		return true
	end
	if (filetype == "c" or filetype == "cpp") and is_detection_enabled("c_cpp_make") then
		return true
	end
	if (filetype == "javascript" or filetype == "typescript") and is_detection_enabled("js_package_scripts") then
		return true
	end
	if (filetype == "java" or filetype == "kotlin") and is_detection_enabled("java_kotlin_project") then
		return true
	end
	return false
end

---@param filetype string
---@param filepath string
---@param on_done fun(commands: table<string, string>|nil):nil
---@param force_refresh boolean|nil
---@return nil
local function detect_tool_commands_for_filetype_async(filetype, filepath, on_done, force_refresh)
	if filetype == "zig" and is_detection_enabled("zig") then
		detect_commands_from_tool_async(
			"zig",
			"zig",
			"zig",
			{ "zig", "--help" },
			parse_zig_help_commands,
			on_done,
			force_refresh
		)
		return
	end
	if filetype == "go" and is_detection_enabled("go") then
		detect_commands_from_tool_async("go", "go", "go", { "go", "help" }, parse_go_help_commands, on_done, force_refresh)
		return
	end
	if filetype == "rust" and is_detection_enabled("rust") then
		detect_commands_from_tool_async(
			"cargo",
			"cargo",
			"cargo",
			{ "cargo", "--list" },
			parse_cargo_commands,
			on_done,
			force_refresh
		)
		return
	end
	if filetype == "odin" and is_detection_enabled("odin") then
		detect_commands_from_tool_async(
			"odin",
			"odin",
			"odin",
			{ "odin", "help" },
			parse_odin_commands,
			on_done,
			force_refresh
		)
		return
	end
	if (filetype == "c" or filetype == "cpp") and is_detection_enabled("c_cpp_make") then
		vim.schedule(function()
			on_done(detect_makefile_targets(filepath))
		end)
		return
	end
	if (filetype == "javascript" or filetype == "typescript") and is_detection_enabled("js_package_scripts") then
		vim.schedule(function()
			on_done(detect_package_scripts(filepath))
		end)
		return
	end
	if (filetype == "java" or filetype == "kotlin") and is_detection_enabled("java_kotlin_project") then
		vim.schedule(function()
			on_done(detect_java_like_project_commands(filepath))
		end)
		return
	end
	on_done({})
end

---@param filetype string
---@param filepath string
---@return table<string, string>
local function get_build_commands_for_filetype(filetype, filepath)
	local detected = detect_tool_commands_for_filetype(filetype, filepath)
	local configured = config.options.build_commands[filetype] or {}
	return copy_string_map(vim.tbl_extend("force", detected, configured))
end

---@param filetype string
---@param detected table<string, string>|nil
---@return table<string, string>
local function merge_build_commands(filetype, detected)
	local merged = copy_string_map(detected)
	local configured = config.options.build_commands[filetype] or {}
	for key, value in pairs(configured) do
		if type(key) == "string" and type(value) == "string" then
			merged[key] = value
		end
	end
	return merged
end

---@param filetype string
---@param filepath string
---@return table<string, string>, table|nil, string, string|nil
local function get_cached_detected_commands(filetype, filepath)
	local cache_key = detect_runtime_cache_key(filetype, filepath)
	local mtime_signature = get_mtime_signature_for_filetype(filetype, filepath)
	local entry = get_bounded_cache_entry(detect_runtime_cache, detect_runtime_cache_order, cache_key)
	local cached_detected = {}
	if type(entry) == "table" and type(entry.commands) == "table" then
		cached_detected = copy_string_map(entry.commands)
	end
	return cached_detected, entry, cache_key, mtime_signature
end

---@param filetype string
---@param filepath string
---@param on_refresh fun(commands: table<string, string>):nil
---@return boolean
local function request_build_command_refresh(filetype, filepath, on_refresh)
	local runtime_opts = get_detect_runtime_options()
	if not can_detect_build_commands_for_filetype(filetype) then
		return false
	end

	local cached_detected, entry, cache_key, mtime_signature = get_cached_detected_commands(filetype, filepath)
	if not is_cache_stale(entry, runtime_opts.cache_ttl_ms, mtime_signature) then
		return false
	end

	local inflight = detect_runtime_inflight[cache_key]
	if inflight then
		if type(on_refresh) == "function" then
			table.insert(inflight.callbacks, on_refresh)
		end
		return true
	end

	detect_runtime_inflight[cache_key] = {
		callbacks = type(on_refresh) == "function" and { on_refresh } or {},
	}

	detect_tool_commands_for_filetype_async(filetype, filepath, function(detected)
		local status = "ready"
		local updated_at_ms = now_ms()
		if detected == nil then
			status = "failed"
			detected = cached_detected
			updated_at_ms = updated_at_ms - (DETECT_RUNTIME_FAILED_TTL_MS + 1)
		end

		local detected_copy = copy_string_map(detected)
			set_bounded_cache_entry(
				detect_runtime_cache,
				detect_runtime_cache_order,
				DETECT_RUNTIME_CACHE_MAX,
				cache_key,
				{
					commands = detected_copy,
					updated_at_ms = updated_at_ms,
					mtime_signature = mtime_signature,
					status = status,
				}
			)

		local merged_commands = merge_build_commands(filetype, detected_copy)
		local pending = detect_runtime_inflight[cache_key]
		detect_runtime_inflight[cache_key] = nil
		if not pending or type(pending.callbacks) ~= "table" then
			return
		end
		for _, callback in ipairs(pending.callbacks) do
			if type(callback) == "function" then
				pcall(callback, copy_string_map(merged_commands))
			end
		end
	end, true)

	return true
end

---@param filetype string
---@param filepath string
---@param on_refresh fun(commands: table<string, string>):nil
---@return table<string, string>, boolean
local function get_build_commands_for_cached_lookup(filetype, filepath, on_refresh)
	local cached_detected = get_cached_detected_commands(filetype, filepath)
	local merged = merge_build_commands(filetype, cached_detected)
	local refresh_started = request_build_command_refresh(filetype, filepath, on_refresh)
	return merged, refresh_started
end

---@param filetype string
---@param filepath string
---@param on_refresh fun(commands: table<string, string>):nil
---@return table<string, string>
local function get_build_commands_for_picker(filetype, filepath, on_refresh)
	local runtime_opts = get_detect_runtime_options()
	if runtime_opts.async_picker == false then
		return get_build_commands_for_filetype(filetype, filepath)
	end

	local merged = get_build_commands_for_cached_lookup(filetype, filepath, on_refresh)
	return merged
end

---@param filetype string
---@param command_name string
---@param build_cmds table<string, string>
---@param mode string
---@return nil
local function show_build_command_missing(filetype, command_name, build_cmds, mode)
	if vim.tbl_isempty(build_cmds) then
		ui.show_output(string.format("No build commands available for filetype: %s", filetype), mode)
		return
	end

	local available = {}
	for cmd_name, _ in pairs(build_cmds) do
		table.insert(available, cmd_name)
	end
	table.sort(available)
	ui.show_output(
		string.format(
			"Command '%s' not found for %s.\nAvailable commands: %s",
			command_name,
			filetype,
			table.concat(available, ", ")
		),
		mode
	)
end

---@param filetype string
---@param filepath string
---@param command_name string
---@param command_template string
---@param mode string
---@return nil
local function execute_build_command(filetype, filepath, command_name, command_template, mode)
	local resolved_template = resolve_command_arguments(filetype, command_name, command_template, mode)
	if not resolved_template then
		return
	end

	local command = resolved_template
	if is_reserved_argv_command(command) then
		ui.show_output(ERRORS.RESERVED_ARGV, mode)
		return
	end

	local cwd = utils.get_project_root(filepath, config.options.project)
	if not cwd then
		cwd = vim.fn.fnamemodify(filepath, ":h")
	end

	if filetype == "zig" and command_name == "run" then
		local has_build_zig = vim.fn.filereadable(vim.fs.joinpath(cwd, "build.zig")) == 1
		if not has_build_zig then
			local zig_runner = utils.normalize_command(config.options.runners.zig)
			if type(zig_runner) ~= "string" or zig_runner:match("zig%s+build") then
				zig_runner = "zig run $file"
			end
			if is_reserved_argv_command(zig_runner) then
				ui.show_output(ERRORS.RESERVED_ARGV, mode)
				return
			end
			local standalone_cmd = utils.substitute_variables(zig_runner, filepath)
			local standalone_dir = vim.fn.fnamemodify(filepath, ":h")
			local standalone_argv = command_to_argv(zig_runner, filepath)
			local standalone_system_command = build_system_command(standalone_cmd, standalone_argv)
			M.execute_command(standalone_system_command, filepath, 0, mode, "zig: run", nil, {
				cwd = standalone_dir,
			})
			return
		end
	end

	command = utils.substitute_variables(command, filepath)
	local argv_command = command_to_argv(resolved_template, filepath)
	if not cwd then
		argv_command = nil
	end

	local system_command = build_system_command(command, argv_command)
	local display_name = string.format("%s: %s", filetype, command_name)
	last_build_command_by_filetype[filetype] = command_name
	M.execute_command(system_command, filepath, 0, mode, display_name, nil, { cwd = cwd })
end

-- Helper function to get visual selection
---@return string
local function get_visual_selection()
	local _, start_line, start_col, _ = table_unpack(vim.fn.getpos("'<"))
	local _, end_line, end_col, _ = table_unpack(vim.fn.getpos("'>"))
	if start_line == 0 or end_line == 0 then
		return ""
	end
	return table.concat(vim.api.nvim_buf_get_text(0, start_line - 1, start_col, end_line - 1, end_col, {}), "\n")
end

-- Get the command to run (from project or filetype)
-- Returns the runner config and source ("project" or "filetype")
---@param filepath string
---@param requested_filetype string
---@return string|string[]|table|nil, string|nil, string
function M.get_command(filepath, requested_filetype)
	ensure_config()

	local source_path = filepath or vim.fn.expand("%:p")
	local filetype = resolve_supported_filetype(requested_filetype or vim.bo.filetype, source_path)

	-- 1. Detect project
	local project, _ = utils.detect_project(source_path, config.options.project)

	-- 2. Filetype runner
	local ft_runner = config.options.runners[filetype]

	-- 3. Priority Logic:
	-- Zig build-system projects should run through `zig build ...` even when
	-- editing files in subdirectories (src/, lib/, etc.).
	if filetype == "zig" and project and project.command then
		return project, "project", filetype
	end

	-- A. RunFile should prioritize the filetype runner when available.
	-- Users can still run project commands explicitly via :RunProject.
	if ft_runner then
		return ft_runner, "filetype", filetype
	end

	-- B. Fallback to project when no filetype runner exists.
	if project and project.command then
		return project, "project", filetype
	end

	return nil, nil, filetype
end

-- Run code with specified mode
-- @param range: 0 for file execution, >0 for visual selection
-- @param mode: output mode ("float", "split", etc.)
---@param range integer
---@param mode string
---@return nil
function M.run_code(range, mode)
	ensure_config()

	local buffer_path = vim.fn.expand("%:p")
	local filetype = resolve_supported_filetype(vim.bo.filetype, buffer_path)
	local execution_path
	local code_to_run

	if range > 0 then -- Visual mode execution
		code_to_run = get_visual_selection()
		if code_to_run == "" then
			ui.show_output(ERRORS.VISUAL_EMPTY, mode)
			return
		end
		execution_path = build_temp_execution_path(buffer_path, filetype)
		local file = io.open(execution_path, "w")
		if file then
			local success, err = file:write(code_to_run)
			file:close()
			if not success then
				ui.show_output(ERRORS.TEMP_WRITE_FAIL .. ": " .. err, mode)
				return
			end
		else
			ui.show_output(ERRORS.TEMP_WRITE_FAIL, mode)
			return
		end
	else -- Normal file execution
		execution_path = buffer_path
		if execution_path == "" then
			ui.show_output(ERRORS.NO_FILE, mode)
			return
		end
	end

	-- Get command (project or filetype)
	local runner, source = M.get_command(buffer_path, vim.bo.filetype)

	if not runner then
		ui.show_output(string.format(ERRORS.NO_RUNNER, filetype), mode)
		return
	end

	-- Validate file extension for Zig
	if range == 0 and filetype == "zig" and vim.fn.fnamemodify(execution_path, ":e") ~= "zig" then
		ui.show_output(string.format(ERRORS.ZIG_EXT, execution_path), mode)
		return
	end

	local command_str
	local cleanup_command
	local display_name
	local argv_command
	local command_cwd

	if source == "project" then
		command_str = runner.command
		display_name = runner.name
		command_cwd = utils.get_project_root(buffer_path ~= "" and buffer_path or execution_path, config.options.project)
	else
		command_str = get_normalized_runner_command(filetype, runner)
		if type(runner) == "table" and runner.cleanup_command then
			cleanup_command = runner.cleanup_command
		end
		display_name = filetype
		command_cwd = nil
	end

	if is_reserved_argv_command(command_str) then
		ui.show_output(ERRORS.RESERVED_ARGV, mode)
		return
	end

	-- Substitute variables in command
	local final_command = utils.substitute_variables(command_str, execution_path)
	argv_command = command_to_argv(command_str, execution_path)

	-- Standalone Zig safeguard: if user configured a build-based runner but no
	-- build.zig exists, force single-file execution.
	if filetype == "zig" and source == "filetype" then
		local has_build_zig = vim.fn.filereadable(vim.fs.joinpath(vim.fn.fnamemodify(execution_path, ":h"), "build.zig")) == 1
		local uses_zig_build = final_command:match("zig%s+build") ~= nil
		if not has_build_zig and uses_zig_build then
			final_command = utils.substitute_variables("zig run $file", execution_path)
			argv_command = command_to_argv("zig run $file", execution_path)
		end
	end

	-- If it's a project command, navigate to project root
	if source == "project" then
		if not command_cwd then
			argv_command = nil
		end
	end

	local system_command = build_system_command(final_command, argv_command)

	M.execute_command(system_command, execution_path, range, mode, display_name, cleanup_command, {
		cwd = command_cwd,
	})
end

-- Execute command asynchronously using new UI
---@param system_command string|string[]
---@param execution_path string
---@param range integer
---@param mode string
---@param display_name string
---@param cleanup_command string
---@param exec_opts table|nil
---@return nil
function M.execute_command(system_command, execution_path, range, mode, display_name, cleanup_command, exec_opts)
	ensure_config()

	mode = mode or config.options.mode or "float"

	-- Callback to run cleanup tasks
	---@param exit_code integer
	---@return nil
	local function on_exit()
		-- Clean up temporary file if created for visual selection
		if range > 0 and execution_path then
			os.remove(execution_path)
		end

		if cleanup_command then
			-- Run cleanup in background quietly
			vim.fn.jobstart(utils.substitute_variables(cleanup_command, execution_path), {
				cwd = exec_opts and exec_opts.cwd or nil,
				on_exit = function() end,
			})
		end
	end

	if mode == "float" then
		ui.run_in_float_terminal(system_command, on_exit, display_name, exec_opts)
	else
		ui.run_in_split_terminal(mode, system_command, on_exit, exec_opts)
	end
end

-- Run current project
---@param mode string
---@return nil
function M.run_project(mode)
	ensure_config()

	local filepath = vim.fn.expand("%:p")
	local runner = utils.detect_project(filepath, config.options.project)
	if not runner then
		ui.show_output(ERRORS.PROJECT_NOT_FOUND, mode)
		return
	end

	if not runner.command then
		ui.show_output(string.format(ERRORS.PROJECT_NO_COMMAND, runner.name or "Unknown"), mode)
		return
	end

	local cwd = utils.get_project_root(filepath, config.options.project)
	local command = runner.command
	if is_reserved_argv_command(command) then
		ui.show_output(ERRORS.RESERVED_ARGV, mode)
		return
	end

	-- Substitute variables
	command = utils.substitute_variables(command, filepath)
	local argv_command = command_to_argv(runner.command, filepath)
	if not cwd then
		argv_command = nil
	end

	local system_command = build_system_command(command, argv_command)
	M.execute_command(system_command, filepath, 0, mode, runner.name or "Project", nil, { cwd = cwd })
end

---@return nil
function M.stop_code()
	-- Since UI handles process via terminal buffers, we delegate closing to UI
	ui.close_output(true)
	vim.notify("Runner stopped.", vim.log.levels.INFO)
end

-- Run a specific build command for the current filetype
-- @param command_name: Name of the command (e.g., "build", "run", "test")
-- @param mode: Output mode
---@param command_name string
---@param mode string
---@return nil
function M.run_build_command(command_name, mode)
	ensure_config()

	local filepath = vim.fn.expand("%:p")
	local filetype = resolve_supported_filetype(vim.bo.filetype, filepath)
	local settled = false
	local function try_run(build_cmds)
		if settled then
			return true
		end
		local command_template = build_cmds[command_name]
		if not command_template then
			return false
		end
		settled = true
		execute_build_command(filetype, filepath, command_name, command_template, mode)
		return true
	end

	local build_cmds, refresh_started = get_build_commands_for_cached_lookup(filetype, filepath, function(updated_commands)
		if try_run(updated_commands) then
			return
		end
		if settled then
			return
		end
		settled = true
		show_build_command_missing(filetype, command_name, updated_commands, mode)
	end)

	if try_run(build_cmds) then
		return
	end
	if refresh_started then
		return
	end
	show_build_command_missing(filetype, command_name, build_cmds, mode)
end

-- Run a long-lived live/watch/dev command for the current filetype.
---@param mode string
---@return nil
function M.run_live(mode)
	ensure_config()

	local filepath = vim.fn.expand("%:p")
	local filetype = resolve_supported_filetype(vim.bo.filetype, filepath)
	local settled = false

	local function show_missing_live()
		ui.show_output(
			string.format(
				"No live/watch command found for %s. Add one of: %s",
				filetype,
				table.concat(LIVE_COMMAND_PRIORITY, ", ")
			),
			mode
		)
	end

	local function try_run_live(build_cmds)
		if settled then
			return true
		end
		if vim.tbl_isempty(build_cmds) then
			return false
		end
		local command_name = select_live_command_name(build_cmds)
		if not command_name then
			return false
		end
		settled = true
		M.run_build_command(command_name, mode)
		return true
	end

	local build_cmds, refresh_started = get_build_commands_for_cached_lookup(filetype, filepath, function(updated_commands)
		if try_run_live(updated_commands) then
			return
		end
		if settled then
			return
		end
		settled = true
		show_missing_live()
	end)

	if try_run_live(build_cmds) then
		return
	end
	if refresh_started then
		return
	end
	if vim.tbl_isempty(build_cmds) then
		ui.show_output(string.format("No build commands available for filetype: %s", filetype), mode)
		return
	end
	show_missing_live()
end

-- Show a picker to select and run a build command
-- @param mode: Output mode
---@param mode string
---@return nil
function M.select_build_command(mode)
	ensure_config()

	local filepath = vim.fn.expand("%:p")
	local filetype = resolve_supported_filetype(vim.bo.filetype, filepath)
	local detect_runtime_opts = get_detect_runtime_options()

	-- Get project root to detect build system
	local root = utils.get_project_root(filepath, config.options.project)
	if not root then
		root = vim.fn.fnamemodify(filepath, ":h")
	end

	-- Detect build systems
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
	---@return table
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
				if string.match(cmd_name, "^cmake%-") then
					include = has_cmake
				elseif string.match(cmd_name, "^meson%-") then
					include = has_meson
				elseif tostring(cmd_string or ""):match("^%s*make%s") then
					include = has_makefile
				else
					include = true
				end
			end

			if include then
				table.insert(entries, {
					name = cmd_name,
					command = cmd_string,
				})
			end
		end

		table.sort(entries, function(a, b)
			return a.name < b.name
		end)
		return entries
	end

	local all_commands = {}
	local filtered_commands = {}
	local selected_index = 1
	local command_line_start = 2
	local filter_query = ""
	local picker_ready = false
	---@type table<string, string>|nil
	local pending_refresh_commands = nil

	---@param commands table
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
			local display_command = command_for_display(cmd.command)
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
			pending_refresh_commands = copy_string_map(updated_commands)
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

	local build_cmds
	if detect_runtime_opts.async_picker ~= false then
		build_cmds = get_build_commands_for_picker(filetype, filepath, on_picker_refresh)
	else
		build_cmds = get_build_commands_for_filetype(filetype, filepath)
	end

	local can_refresh_from_detection = detect_runtime_opts.async_picker ~= false
		and can_detect_build_commands_for_filetype(filetype)

	if vim.tbl_isempty(build_cmds) and not can_refresh_from_detection then
		vim.notify(string.format("No build commands available for filetype: %s", filetype), vim.log.levels.WARN)
		return
	end

	local last_selected_name = last_build_command_by_filetype[filetype]
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

	-- Create custom bottom-aligned picker with visual selection
	local buf = vim.api.nvim_create_buf(false, true)
	local ns_id = vim.api.nvim_create_namespace("zignite_picker")

	---@param text string
	---@return string
	local function format_command_preview(text)
		if #text <= 52 then
			return text
		end
		return string.sub(text, 1, 49) .. "..."
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
					local display_command = command_for_display(cmd.command)
					lines[#lines + 1] = string.format("  %-18s → %s", cmd.name, format_command_preview(display_command))
				end
			end

		lines[#lines + 1] = "j/k: navigate | Enter: select | /: filter | c: clear | r: repeat | Esc: cancel"
			local preview_text = "(none)"
			if #filtered_commands > 0 and selected_index >= 1 then
				preview_text = command_for_display(filtered_commands[selected_index].command)
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

	-- Calculate window size based on content and clamp to viewport
	local max_width = 0
	for _, line in ipairs(lines) do
		max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
	end
	local width_cap = math.max(40, math.floor(vim.o.columns * 0.75))
	local width = math.min(max_width + 4, width_cap)
	local height_cap = math.max(8, math.floor(vim.o.lines * 0.65))
	local height = math.min(#lines + 1, height_cap)

	-- Use user's float config style (bottom-aligned, right side)
	local float_config = config.options.float or {}
	local picker_config = config.options.picker or {}
	local preferred_row = math.floor(vim.o.lines * (float_config.y or 0.90)) - height
	local preferred_col = vim.o.columns - width - 2 -- Right side with 2 char padding
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

	-- Enable cursor line highlighting
	vim.api.nvim_set_option_value("cursorline", true, { win = win })
	vim.api.nvim_set_option_value("winhl", "Normal:Normal,FloatBorder:FloatBorder,CursorLine:Visual", { win = win })

	-- Function to update selection indicator
	---@return nil
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

	---@param delta number
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
					current_query = string.sub(current_query, 1, math.max(0, #current_query - 1))
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
			vim.ui.input({
				prompt = "Build filter: ",
				default = filter_query,
			}, apply_input)
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
			if run_inline_filter() then
				return
			end
			if run_ui_filter() then
				return
			end
			if run_cmdline_filter() then
				return
			end
		elseif filter_input_mode == "ui" then
			if run_ui_filter() then
				return
			end
			if run_cmdline_filter() then
				return
			end
		else
			if run_cmdline_filter() then
				return
			end
		end

		vim.notify("Build filter prompt is unavailable in this environment", vim.log.levels.WARN)
	end

	-- Key mappings
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
		M.run_build_command(selected.name, mode)
	end

	---@return nil
	local function run_last_selected()
		local command_name = last_build_command_by_filetype[filetype]
		if not command_name then
			vim.notify(string.format("No previous build command for filetype: %s", filetype), vim.log.levels.WARN)
			return
		end
		close_picker()
		M.run_build_command(command_name, mode)
	end

	-- Enhanced j/k navigation with boundary checking
	vim.keymap.set("n", "j", function()
		move_selection(1)
	end, { buffer = buf, nowait = true })

	vim.keymap.set("n", "k", function()
		move_selection(-1)
	end, { buffer = buf, nowait = true })

	-- Arrow keys support
	vim.keymap.set("n", "<Down>", function()
		move_selection(1)
	end, { buffer = buf, nowait = true })

	vim.keymap.set("n", "<Up>", function()
		move_selection(-1)
	end, { buffer = buf, nowait = true })

	-- Enter to select
	vim.keymap.set("n", "<CR>", function()
		if selected_index >= 1 and selected_index <= #filtered_commands then
			select_command(selected_index)
		end
	end, { buffer = buf, nowait = true })

	-- Map number keys (still works!)
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

	-- Map escape and q to close
	vim.keymap.set("n", "<Esc>", close_picker, { buffer = buf, nowait = true })
	vim.keymap.set("n", "q", close_picker, { buffer = buf, nowait = true })

	-- Show initial selection and preview, then apply deferred async refresh.
	picker_ready = true
	if pending_refresh_commands then
		on_picker_refresh(pending_refresh_commands)
	else
		render_picker()
	end
end

---@param mode string
---@return nil
function M.run_last_build_command(mode)
	ensure_config()

	local filepath = vim.fn.expand("%:p")
	local filetype = resolve_supported_filetype(vim.bo.filetype, filepath)
	local command_name = last_build_command_by_filetype[filetype]
	if not command_name then
		ui.show_output(string.format("No previous build command for filetype: %s", filetype), mode)
		return
	end

	M.run_build_command(command_name, mode)
end

---@param filetype string
---@return table<string, string>
function M.get_build_commands_for_filetype(filetype)
	ensure_config()
	local filepath = vim.fn.expand("%:p")
	local ft = resolve_supported_filetype(filetype or vim.bo.filetype, filepath)
	return get_build_commands_for_filetype(ft, filepath)
end

---@param filetype string
---@return table<string, string>
function M.get_build_commands_for_completion(filetype)
	ensure_config()
	local filepath = vim.fn.expand("%:p")
	local ft = resolve_supported_filetype(filetype or vim.bo.filetype, filepath)
	local build_cmds = get_build_commands_for_cached_lookup(ft, filepath, nil)
	return build_cmds
end

---@return nil
function M.close_runner()
	ensure_config()
	local close_behavior = tostring(config.options.close_behavior or "stop"):lower()
	local should_stop = close_behavior ~= "hide"
	ui.close_output(should_stop)
	if not should_stop then
		vim.notify("Runner closed (hide mode). Use :StopCode to terminate active jobs.", vim.log.levels.INFO)
	end
end

---@param opts table|nil
---@return nil
function M.setup(opts)
	zig_backend_available = nil
	zig_missing_notified = false
	if detect_worker and type(detect_worker.job_id) == "number" and detect_worker.job_id > 0 then
		if type(vim.fn.jobstop) == "function" then
			pcall(vim.fn.jobstop, detect_worker.job_id)
		end
	end
	detect_worker = nil
	argv_cache = {}
	argv_cache_order = {}
	normalized_runner_cache = {}
	normalized_runner_order = {}
	last_build_command_by_filetype = {}
	tool_command_cache = {}
	tool_command_cache_order = {}
	shebang_filetype_cache = {}
	shebang_filetype_cache_order = {}
	package_script_cache = {}
	package_script_cache_order = {}
	make_target_cache = {}
	make_target_cache_order = {}
	detect_runtime_cache = {}
	detect_runtime_cache_order = {}
	detect_runtime_inflight = {}
	config.setup(opts)
	utils.clear_project_cache()
end

return M
