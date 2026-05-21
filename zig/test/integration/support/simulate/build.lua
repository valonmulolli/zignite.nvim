local project = require("integration.support.simulate.project")
local util = require("integration.support.simulate.util")

---@type table
local M = {}
local last_command_names = {}

---@param payload table
---@return string
local function encode_json(payload)
	local encode = vim.json and vim.json.encode or vim.fn.json_encode
	return encode(payload)
end

---@param lines string[]
---@return table, table, table
function M.decode_build_resolve_lines(lines)
	local meta = {}
	local commands = {}
	local preferred = {}
	for _, line in ipairs(lines or {}) do
		local kind, name, value = line:match("^([^\t]+)\t([^\t]+)\t(.+)$")
		if kind == "COMMAND" then
			commands[name] = value
		elseif kind == "PREFERRED" then
			preferred[name] = value
		else
			kind, value = line:match("^([^\t]+)\t(.+)$")
			if kind == "ROOT" then
				meta.root = value
			elseif kind == "SYSTEM" then
				meta.system = value
			elseif kind == "BUILD_READY" then
				meta.build_ready = value
			end
		end
	end
	return meta, commands, preferred
end

---@param preferred table<string, string>
---@param commands table<string, string>
local function append_implicit_preferred(preferred, commands)
	for _, key in ipairs({ "build", "run", "live", "test", "clean" }) do
		if preferred[key] == nil and type(commands[key]) == "string" then
			preferred[key] = commands[key]
		end
	end
end

---@param preferred table<string, string>
---@param commands table<string, string>
---@return string|nil
local function preferred_live_name(preferred, commands)
	if type(preferred.live) == "string" or type(commands.live) == "string" then
		return "live"
	end
	return nil
end

---@param command string
---@return boolean
local function command_requires_arguments(command)
	return type(command) == "string" and command:find("$zignite_args", 1, true) ~= nil
end

---@param command string
---@return string
local function command_display(command)
	return tostring(command or ""):gsub("%$zignite_args", "<args>")
end

---@param filetype string
---@param command_name string
---@return string
local function command_arg_prompt(filetype, command_name)
	if filetype == "zig" and command_name == "fetch" then
		return "zig fetch url/path"
	end
	return string.format("%s %s args", filetype, command_name)
end

---@param filetype string
---@param command_name string
---@return string
local function command_arg_help(filetype, command_name)
	if filetype == "zig" and command_name == "fetch" then
		return "Paste GitHub URL only | Enter: run | Esc: cancel | Backspace: edit"
	end
	return "Type arguments | Enter: run | Esc: cancel | Backspace: edit"
end

---@param name string
---@return string|nil, string|nil
local function split_command_prefix(name)
	return tostring(name or ""):match("^(%w+)%-(.+)$")
end

---@param name string
---@return integer|nil
local function common_command_order(name)
	local order = {
		build = 1,
		run = 2,
		clean = 3,
		test = 4,
		install = 5,
		check = 6,
		dev = 7,
		start = 8,
		watch = 9,
		serve = 10,
		preview = 11,
		mod = 12,
		fetch = 13,
	}
	return order[name]
end

---@param name string
---@return integer|nil
local function profile_command_order(name)
	local order = {
		config = 1,
		setup = 2,
		debug = 3,
		release = 4,
	}
	return order[name]
end

---@param name string
---@return string
local function picker_section(name)
	local prefix, rest = split_command_prefix(name)
	local semantic_name = rest or name
	if prefix and (prefix == "cmake" or prefix == "meson") then
		if rest and (rest:match("^build%-.+$") or rest:match("^run%-.+$")) then
			return "targets"
		end
		if common_command_order(rest) then
			return "common"
		end
		if profile_command_order(rest) then
			return "profiles"
		end
	end
	if common_command_order(semantic_name) then
		return "common"
	end
	if profile_command_order(semantic_name) then
		return "profiles"
	end
	return "other"
end

---@param name string
---@return integer
local function picker_rank(name)
	local _, rest = split_command_prefix(name)
	local semantic_name = rest or name
	local section_rank = ({
		common = 1,
		targets = 2,
		profiles = 3,
		other = 4,
	})[picker_section(name)] or 99
	local name_rank = common_command_order(semantic_name) or profile_command_order(semantic_name) or 999
	return section_rank * 1000 + name_rank
end

---@param filetype string
---@return boolean
local function is_c_family(filetype)
	return filetype == "c" or filetype == "cpp"
end

---@param filetype string
---@param commands table<string, string>
---@param command_name string
---@param command_value string
---@return boolean
local function hide_in_picker(filetype, commands, command_name, command_value)
	if not is_c_family(filetype) then
		return false
	end
	local base_name = command_name:match("^cmake%-(.+)$") or command_name:match("^meson%-(.+)$")
	if not base_name or base_name:find("%-") then
		return false
	end
	return type(commands[base_name]) == "string" and commands[base_name] == command_value
end

---@param install_command string|nil
---@return string
local function package_manager_for_install(install_command)
	if type(install_command) ~= "string" then
		return "npm"
	end
	if install_command:match("^bun") then
		return "bun"
	end
	if install_command:match("^pnpm") then
		return "pnpm"
	end
	if install_command:match("^yarn") then
		return "yarn"
	end
	return "npm"
end

---@param script_names string[]
---@param name string
---@return boolean
local function contains_name(script_names, name)
	for _, value in ipairs(script_names) do
		if value == name then
			return true
		end
	end
	return false
end

---@param commands table<string, string>
---@return string[]
local function sorted_command_names(commands)
	local names = {}
	for name, _ in pairs(commands or {}) do
		names[#names + 1] = name
	end
	table.sort(names)
	return names
end

---@param script_names string[]
---@param aliases string[]
---@return string|nil
local function find_alias_source(script_names, aliases)
	for _, alias in ipairs(aliases) do
		if contains_name(script_names, alias) then
			return alias
		end
	end
	return nil
end

---@param root string|nil
---@param install_command string|nil
---@return string[]
local function build_package_json_auto_lines(root, install_command)
	if type(root) ~= "string" or root == "" then
		return {}
	end

	local package_json_path = vim.fs.joinpath(root, "package.json")
	local package_json_lines = util.read_file_lines_direct(package_json_path)
	if type(package_json_lines) ~= "table" then
		return {}
	end

	local package_json = table.concat(package_json_lines, "\n")
	local scripts_block = package_json:match([["scripts"%s*:%s*(%b{})]])
	if type(scripts_block) ~= "string" or scripts_block == "" then
		return {}
	end

	local manager = package_manager_for_install(install_command)
	local commands = {}
	local script_names = {}
	for name in scripts_block:gmatch([["([^"]+)"%s*:]]) do
		script_names[#script_names + 1] = name
		commands[#commands + 1] = string.format("COMMAND\t%s\t%s run %s", name, manager, name)
	end

	local alias_map = {
		build = { "all", "default", "compile", "assemble", "package", "dist", "bundle" },
		run = { "start", "serve", "preview" },
		live = { "dev", "watch", "serve", "preview", "dev:watch", "dev:server", "start:dev", "serve:dev" },
		test = { "verify", "check", "integrationTest", "integration-test", "unitTest", "unit-test", "e2e", "smoke", "smokeTest", "smoke-test" },
		check = { "verify", "validate" },
		fmt = { "format", "spotlessApply", "spotless:apply" },
		release = { "package", "assemble", "dist", "bundle" },
		dist = { "bundle", "package" },
		bundle = { "dist", "package" },
		e2e = { "integrationTest", "integration-test", "smoke", "smokeTest", "smoke-test" },
		smoke = { "smokeTest", "smoke-test", "integrationTest", "integration-test" },
		["integration-test"] = { "integrationTest", "e2e" },
	}

	for alias, candidates in pairs(alias_map) do
		if not contains_name(script_names, alias) then
			local source_name = find_alias_source(script_names, candidates)
			if type(source_name) == "string" then
				commands[#commands + 1] = string.format("COMMAND\t%s\t%s run %s", alias, manager, source_name)
			end
		end
	end

	return commands
end

---@param value string
---@return string
local function normalize_github_repo_reference(value)
	local trimmed = util.trim_text(value)
	if trimmed == "" or trimmed:match("^%-%-") then
		return trimmed
	end

	local shorthand_repo, shorthand_ref = trimmed:match("^([%w%._%-]+/[%w%._%-]+)#(.+)$")
	if shorthand_repo then
		return string.format("--save git+https://github.com/%s#%s", shorthand_repo:gsub("%.git$", ""), shorthand_ref)
	end

	local shorthand = trimmed:match("^([%w%._%-]+/[%w%._%-]+)$")
	if shorthand then
		return string.format("--save git+https://github.com/%s", shorthand:gsub("%.git$", ""))
	end

	local url_repo, url_ref = trimmed:match("^https?://github%.com/([%w%._%-]+/[%w%._%-]+)[/#]?tree/?(.+)$")
	if url_repo then
		return string.format("--save git+https://github.com/%s#%s", url_repo:gsub("%.git$", ""), url_ref)
	end

	local url_plain = trimmed:match("^https?://github%.com/([%w%._%-]+/[%w%._%-]+)/*$")
	if url_plain then
		return string.format("--save git+https://github.com/%s", url_plain:gsub("%.git$", ""))
	end

	if trimmed:match("^git%+https://github%.com/") then
		return "--save " .. trimmed
	end

	return trimmed
end

---@param filetype string
---@param command_name string
---@param template string
---@param command_args string|nil
---@return string|nil
local function resolve_command_template(filetype, command_name, template, command_args)
	if not command_requires_arguments(template) then
		return template
	end

	local trimmed = util.trim_text(command_args)
	if trimmed == "" then
		return nil
	end

	local replacement
	if filetype == "zig" and command_name == "fetch" then
		replacement = normalize_github_repo_reference(trimmed)
	else
		replacement = util.quote_shell_arg(trimmed)
	end

	return template:gsub("%$zignite_args", replacement)
end

---@param filetype string
---@param commands table<string, string>
---@return table<string, table>
local function build_command_meta(filetype, commands)
	local command_meta = {}
	for name, value in pairs(commands or {}) do
		local meta = {
			display_command = command_display(value),
			picker_section = picker_section(name),
			picker_rank = picker_rank(name),
		}
		if command_requires_arguments(value) then
			meta.requires_arguments = true
			meta.argument_prompt = command_arg_prompt(filetype, name)
			meta.argument_help = command_arg_help(filetype, name)
		end
		if hide_in_picker(filetype, commands, name, value) then
			meta.hide_in_picker = true
		end
		command_meta[name] = meta
	end
	return command_meta
end

---@param command_meta table<string, table>
---@param commands table<string, string>
---@param last_command_name string|nil
---@return table[]
local function build_command_entries(command_meta, commands, last_command_name)
	local entries = {}
	for name, command in pairs(commands or {}) do
		local meta = command_meta[name]
		if not (type(meta) == "table" and meta.hide_in_picker == true) then
			entries[#entries + 1] = {
				name = name,
				command = command,
				display_command = type(meta) == "table" and meta.display_command or command,
				requires_arguments = type(meta) == "table" and meta.requires_arguments == true or false,
				argument_prompt = type(meta) == "table" and meta.argument_prompt or nil,
				argument_help = type(meta) == "table" and meta.argument_help or nil,
				picker_section = type(meta) == "table" and meta.picker_section or "other",
				picker_rank = type(meta) == "table" and meta.picker_rank or 99999,
			}
		end
	end

	table.sort(entries, function(a, b)
		if type(last_command_name) == "string" and last_command_name ~= "" then
			local a_last = a.name == last_command_name
			local b_last = b.name == last_command_name
			if a_last ~= b_last then
				return a_last
			end
		end
		if a.picker_rank == b.picker_rank then
			return a.name < b.name
		end
		return a.picker_rank < b.picker_rank
	end)

	return entries
end

---@param entries table[]
---@return string[]
local function build_completion_names(entries)
	local names = {}
	for _, entry in ipairs(entries or {}) do
		if type(entry) == "table" and type(entry.name) == "string" then
			names[#names + 1] = entry.name
		end
	end
	return names
end

---@param filetype string
---@param path string
---@param project_root string|nil
---@param include_configured boolean|nil
---@return string[]
function M.collect_build_resolve_lines(filetype, path, project_root, include_configured)
	local lines = {}
	if filetype == "c" or filetype == "cpp" then
		lines = project.build_c_family_auto_lines(path, project_root)
	elseif filetype == "rust" then
		lines = project.project_backend_lines.cargo or {}
	elseif filetype == "go" then
		lines = project.project_backend_lines.go or {}
	elseif filetype == "java" or filetype == "kotlin" then
		local system_lines = project.build_system_backend_lines(path, "jvm-root", project_root)
		local detected_system = nil
		for _, line in ipairs(system_lines) do
			detected_system = line:match("^SYSTEM\t(.+)$") or detected_system
		end
		if detected_system == "maven" then
			lines = project.project_backend_lines.maven or {}
		elseif detected_system == "gradle" then
			lines = project.project_backend_lines.gradle or {}
		else
			lines = system_lines
		end
	elseif filetype == "javascript" or filetype == "typescript" then
		local system_lines = project.build_system_backend_lines(path, "node-root", project_root)
		if #system_lines > 0 then
			lines = vim.deepcopy(system_lines)
			local meta = M.decode_build_resolve_lines(lines)
			local install_command = meta.commands and meta.commands.install or nil
			for _, line in ipairs(build_package_json_auto_lines(meta.root, install_command)) do
				lines[#lines + 1] = line
			end
		end
	elseif filetype == "python" then
		lines = project.build_system_backend_lines(path, "python-root", project_root)
	elseif filetype == "bzl" then
		lines = project.project_backend_lines["bazel-auto"] or {}
	end

	local config = require("zignite.config")
	local configured = include_configured ~= false
		and type(config.options.build_commands) == "table"
		and config.options.build_commands[filetype]
		or nil
	if type(configured) == "table" then
		local meta, commands, preferred = M.decode_build_resolve_lines(lines)
		for name, command in pairs(configured) do
			commands[name] = command
		end

		local merged = {}
		if type(meta.root) == "string" then
			merged[#merged + 1] = "ROOT\t" .. meta.root
		end
		if type(meta.system) == "string" then
			merged[#merged + 1] = "SYSTEM\t" .. meta.system
		end
		if type(meta.build_ready) == "string" then
			merged[#merged + 1] = "BUILD_READY\t" .. meta.build_ready
		end
		for name, command in pairs(commands) do
			merged[#merged + 1] = string.format("COMMAND\t%s\t%s", name, command)
		end
		for name, command in pairs(preferred) do
			merged[#merged + 1] = string.format("PREFERRED\t%s\t%s", name, command)
		end
		return merged
	end

	return lines
end

---@param request_text string
---@return string[]|nil
function M.parse_config_daemon_request(request_text)
	local req_lines = util.split_lines(request_text or "")
	if #req_lines < 2 then
		return nil
	end
	local begin_line = req_lines[1]
	local request_id = begin_line:match("^@@ZCFG_REQ_BEGIN%s+(%d+)%s+%d+$")
	if not request_id then
		return nil
	end
	local end_line = req_lines[#req_lines]
	local end_id = end_line:match("^@@ZCFG_REQ_END%s+(%d+)$")
	if not end_id or tonumber(end_id) ~= tonumber(request_id) then
		return nil
	end
	return {
		"@@ZCFG_RES_BEGIN " .. request_id,
		"@@ZCFG_RES_END " .. request_id,
	}
end

---@param request_text string
---@return string[]|nil
function M.parse_build_resolve_daemon_request(request_text)
	local args = util.parse_flag_request_args(request_text, "@@ZBR_REQ_BEGIN", "@@ZBR_REQ_END")
	if not args or not args.path or not args.filetype then
		return nil
	end

	local config = require("zignite.config")
	local response = { "@@ZBR_RES_BEGIN " .. args.request_id }
	local lines = M.collect_build_resolve_lines(args.filetype, args.path, args["project-root"], true)
	local meta, commands, preferred = M.decode_build_resolve_lines(lines)
	append_implicit_preferred(preferred, commands)

	if type(args["command-name"]) == "string" and args["command-name"] ~= "" then
		local command_name = args["command-name"]
		local command_template = commands[command_name]
		if type(command_template) == "string" and command_template ~= "" then
				local resolved = resolve_command_template(
					args.filetype,
					command_name,
				command_template,
				args["command-args"]
			)
			if type(resolved) == "string" and resolved ~= "" then
				local exec_argv = require("integration.support.simulate.run").tokenize_command(resolved)
				local system_argv = require("integration.support.simulate.run").build_system_argv(resolved, exec_argv)
				response[#response + 1] = "\tRESULT_JSON\t" .. encode_json({
					filetype = args.filetype,
					cwd = meta.root or util.dirname(args.path),
					name = string.format("%s: %s", args.filetype, command_name),
					exec_command = resolved,
					exec_argv = exec_argv,
					system_argv = system_argv,
					config_revision = config.revision or 0,
				})
				response[#response + 1] = "\tFILETYPE\t" .. args.filetype
				response[#response + 1] = "\tCWD\t" .. (meta.root or util.dirname(args.path))
				response[#response + 1] = "\tNAME\t" .. string.format("%s: %s", args.filetype, command_name)
				response[#response + 1] = "\tEXEC_COMMAND\t" .. resolved
				for _, arg in ipairs(exec_argv) do
					response[#response + 1] = "\tEXEC_ARGV\t" .. arg
				end
			end
		end
	else
		local live_name = preferred_live_name(preferred, commands)
		local command_meta = build_command_meta(args.filetype, commands)
		local command_entries = build_command_entries(command_meta, commands, last_command_names[args.filetype])
		local has_commands = next(commands) ~= nil
		response[#response + 1] = "\tRESULT_JSON\t" .. encode_json({
			ok = has_commands,
			reason = has_commands and nil or "no_build_commands",
			message = has_commands and nil or string.format("No build commands available for filetype: %s", args.filetype),
			root = meta.root,
			filetype = args.filetype,
			system = meta.system,
			build_ready = meta.build_ready == "1",
			config_revision = config.revision or 0,
			commands = commands,
			command_meta = command_meta,
			command_entries = command_entries,
			completion_names = build_completion_names(command_entries),
			preferred_commands = preferred,
			preferred_names = live_name and { live = live_name } or {},
			last_command_name = last_command_names[args.filetype],
		})
		for _, line in ipairs(lines) do
			response[#response + 1] = "\t" .. line
			local kind, name, value = line:match("^([^\t]+)\t([^\t]+)\t(.+)$")
			if kind == "COMMAND" then
				response[#response + 1] = "\tCOMMAND_DISPLAY\t" .. name .. "\t" .. command_display(value)
				if command_requires_arguments(value) then
					response[#response + 1] = "\tCOMMAND_ARGS_REQUIRED\t" .. name .. "\t1"
					response[#response + 1] = "\tCOMMAND_ARG_PROMPT\t" .. name .. "\t" .. command_arg_prompt(args.filetype, name)
					response[#response + 1] = "\tCOMMAND_ARG_HELP\t" .. name .. "\t" .. command_arg_help(args.filetype, name)
				end
			end
		end
		response[#response + 1] = "\tOK\t" .. (has_commands and "1" or "0")
		if not has_commands then
			response[#response + 1] = "\tREASON\tno_build_commands"
			response[#response + 1] = "\tMESSAGE\t" .. string.format("No build commands available for filetype: %s", args.filetype)
		end
		for name, command in pairs(preferred) do
			response[#response + 1] = "\tPREFERRED\t" .. name .. "\t" .. command
		end
		if live_name then
			response[#response + 1] = "\tPREFERRED_NAME\tlive\t" .. live_name
		end
		if type(last_command_names[args.filetype]) == "string" and last_command_names[args.filetype] ~= "" then
			response[#response + 1] = "\tLAST_COMMAND_NAME\t" .. last_command_names[args.filetype]
		end
	end
	response[#response + 1] = "\tCONFIG_REVISION\t" .. tostring(config.revision or 0)
	response[#response + 1] = "@@ZBR_RES_END " .. args.request_id
	return response
end

---@param request_text string
---@return string[]|nil
function M.parse_build_action_daemon_request(request_text)
	local args = util.parse_flag_request_args(request_text, "@@ZBA_REQ_BEGIN", "@@ZBA_REQ_END")
	if not args or not args.path or not args.filetype or (args.action ~= "named" and args.action ~= "live" and args.action ~= "last") then
		return nil
	end

	local config = require("zignite.config")
	local response = { "@@ZBA_RES_BEGIN " .. args.request_id }
	local lines = M.collect_build_resolve_lines(args.filetype, args.path, args["project-root"], true)
	local meta, commands, preferred = M.decode_build_resolve_lines(lines)
	append_implicit_preferred(preferred, commands)

	local resolved_name
	if args.action == "named" then
		resolved_name = util.trim_text(args["command-name"]) ~= "" and args["command-name"] or nil
	elseif args.action == "live" then
		resolved_name = preferred_live_name(preferred, commands)
	elseif util.trim_text(last_command_names[args.filetype]) ~= "" then
		resolved_name = last_command_names[args.filetype]
	end

	if args.action == "last" and util.trim_text(resolved_name) == "" then
		response[#response + 1] = "\tRESULT_JSON\t" .. encode_json({
			ok = false,
			reason = "missing_last_command",
			message = string.format("No previous build command for filetype: %s", args.filetype),
			filetype = args.filetype,
			config_revision = config.revision or 0,
		})
		response[#response + 1] = "\tOK\t0"
		response[#response + 1] = "\tREASON\tmissing_last_command"
		response[#response + 1] = "\tMESSAGE\t" .. string.format("No previous build command for filetype: %s", args.filetype)
		response[#response + 1] = "\tFILETYPE\t" .. args.filetype
		response[#response + 1] = "\tCONFIG_REVISION\t" .. tostring(config.revision or 0)
		response[#response + 1] = "@@ZBA_RES_END " .. args.request_id
		return response
	end

	if args.action == "named" and util.trim_text(args["command-name"]) == "" then
		response[#response + 1] = "\tRESULT_JSON\t" .. encode_json({
			ok = false,
			reason = "missing_command",
			message = string.format("No build commands available for filetype: %s", args.filetype),
			filetype = args.filetype,
			config_revision = config.revision or 0,
		})
		response[#response + 1] = "\tOK\t0"
		response[#response + 1] = "\tREASON\tmissing_command"
		response[#response + 1] = "\tMESSAGE\t" .. string.format("No build commands available for filetype: %s", args.filetype)
		response[#response + 1] = "\tFILETYPE\t" .. args.filetype
		response[#response + 1] = "\tCONFIG_REVISION\t" .. tostring(config.revision or 0)
		response[#response + 1] = "@@ZBA_RES_END " .. args.request_id
		return response
	end

	local resolved_template = resolved_name and commands[resolved_name] or nil
	if type(resolved_template) ~= "string" or resolved_template == "" then
		local reason = (
			args.action == "last" and "stale_last_command"
			or args.action == "named" and "missing_command"
			or "missing_live_command"
		)
		local message
		if args.action == "last" then
			last_command_names[args.filetype] = nil
			message = string.format(
				"Command '%s' not found for %s.\nAvailable commands: %s",
				resolved_name or "",
				args.filetype,
				table.concat(sorted_command_names(commands), ", ")
			)
		elseif args.action == "named" then
			if next(commands) == nil then
				message = string.format("No build commands available for filetype: %s", args.filetype)
			else
				message = string.format(
					"Command '%s' not found for %s.\nAvailable commands: %s",
					args["command-name"],
					args.filetype,
					table.concat(sorted_command_names(commands), ", ")
				)
			end
		else
			message = string.format("No live command resolved for %s.", args.filetype)
		end
		response[#response + 1] = "\tRESULT_JSON\t" .. encode_json({
			ok = false,
			reason = reason,
			message = message,
			resolved_command_name = (
				args.action == "last" and resolved_name
				or args.action == "named" and args["command-name"]
				or nil
			),
			filetype = args.filetype,
			config_revision = config.revision or 0,
		})
		response[#response + 1] = "\tOK\t0"
		response[#response + 1] = "\tREASON\t" .. reason
		response[#response + 1] = "\tMESSAGE\t" .. message
		if args.action == "last" and type(resolved_name) == "string" then
			response[#response + 1] = "\tCOMMAND_NAME\t" .. resolved_name
		elseif args.action == "named" and type(args["command-name"]) == "string" then
			response[#response + 1] = "\tCOMMAND_NAME\t" .. args["command-name"]
		end
		response[#response + 1] = "\tFILETYPE\t" .. args.filetype
		response[#response + 1] = "\tCONFIG_REVISION\t" .. tostring(config.revision or 0)
		response[#response + 1] = "@@ZBA_RES_END " .. args.request_id
		return response
	end

	local raw_args = util.trim_text(args["command-args"])
	if command_requires_arguments(resolved_template) and raw_args == "" then
		response[#response + 1] = "\tRESULT_JSON\t" .. encode_json({
			ok = false,
			reason = "missing_arguments",
			resolved_command_name = resolved_name,
			requires_arguments = true,
			argument_prompt = command_arg_prompt(args.filetype, resolved_name),
			argument_help = command_arg_help(args.filetype, resolved_name),
			filetype = args.filetype,
			config_revision = config.revision or 0,
		})
		response[#response + 1] = "\tOK\t0"
		response[#response + 1] = "\tREASON\tmissing_arguments"
		response[#response + 1] = "\tCOMMAND_NAME\t" .. resolved_name
		response[#response + 1] = "\tREQUIRES_ARGUMENTS\t1"
		response[#response + 1] = "\tARGUMENT_PROMPT\t" .. command_arg_prompt(args.filetype, resolved_name)
		response[#response + 1] = "\tARGUMENT_HELP\t" .. command_arg_help(args.filetype, resolved_name)
		response[#response + 1] = "\tFILETYPE\t" .. args.filetype
		response[#response + 1] = "\tCONFIG_REVISION\t" .. tostring(config.revision or 0)
		response[#response + 1] = "@@ZBA_RES_END " .. args.request_id
		return response
	end

	local resolved = resolve_command_template(args.filetype, resolved_name, resolved_template, args["command-args"])
	if type(resolved) ~= "string" or resolved == "" then
		return nil
	end

	local exec_argv = require("integration.support.simulate.run").tokenize_command(resolved)
	local system_argv = require("integration.support.simulate.run").build_system_argv(resolved, exec_argv)
	last_command_names[args.filetype] = resolved_name
	response[#response + 1] = "\tRESULT_JSON\t" .. encode_json({
		ok = true,
		resolved_command_name = resolved_name,
		filetype = args.filetype,
		cwd = meta.root or util.dirname(args.path),
		name = string.format("%s: %s", args.filetype, resolved_name),
		exec_command = resolved,
		exec_argv = exec_argv,
		system_argv = system_argv,
		config_revision = config.revision or 0,
	})
	response[#response + 1] = "\tOK\t1"
	response[#response + 1] = "\tCOMMAND_NAME\t" .. resolved_name
	response[#response + 1] = "\tFILETYPE\t" .. args.filetype
	response[#response + 1] = "\tCWD\t" .. (meta.root or util.dirname(args.path))
	response[#response + 1] = "\tNAME\t" .. string.format("%s: %s", args.filetype, resolved_name)
	response[#response + 1] = "\tEXEC_COMMAND\t" .. resolved
	for _, arg in ipairs(exec_argv) do
		response[#response + 1] = "\tEXEC_ARGV\t" .. arg
	end
	response[#response + 1] = "\tCONFIG_REVISION\t" .. tostring(config.revision or 0)
	response[#response + 1] = "@@ZBA_RES_END " .. args.request_id
	return response
end

return M
