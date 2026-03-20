---@type table
local M = {}

local BUILD_ARG_PLACEHOLDER = "$zignite_args"

local zig_detected_command_templates = {
	["ast-check"] = "zig ast-check $file",
	build = "zig build",
	["build-exe"] = "zig build-exe $file",
	["build-lib"] = "zig build-lib $file",
	["build-obj"] = "zig build-obj $file",
	env = "zig env",
	fetch = "zig fetch " .. BUILD_ARG_PLACEHOLDER,
	fmt = "zig fmt $file",
	help = "zig help",
	init = "zig init",
	libc = "zig libc",
	run = "zig run $file",
	std = "zig std",
	targets = "zig targets",
	test = "zig test $file",
	["test-obj"] = "zig test-obj $file",
	version = "zig version",
	zen = "zig zen",
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

---@param value string
---@return string
local function trim_text(value)
	if type(value) ~= "string" then
		return ""
	end
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param lines string[]|nil
---@return string[]
local function normalize_detected_names(lines)
	---@type string[]
	local normalized = {}
	---@type table<string, boolean>
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

---@param lines string[]|nil
---@return table<string, string>
function M.parse_zig_help_commands(lines)
	---@type table<string, string>
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
function M.parse_go_help_commands(lines)
	---@type table<string, string>
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
function M.parse_cargo_commands(lines)
	---@type table<string, string>
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
function M.parse_odin_commands(lines)
	---@type table<string, string>
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

---@param tool string
---@param names string[]
---@return table<string, string>
function M.build_detected_templates_from_names(tool, names)
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

	---@type table<string, string>
	local commands = {}
	for _, name in ipairs(normalize_detected_names(names)) do
		commands[name] = templates[name] or (default_prefix .. name)
	end
	return commands
end

return M
