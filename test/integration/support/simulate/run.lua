local build = require("integration.support.simulate.build")
local project = require("integration.support.simulate.project")
local util = require("integration.support.simulate.util")

---@type table
local M = {}

local SIMULATED_ZIGNITE_EXECUTABLE = "zig/zig-out/bin/zignite"

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

local BUILTIN_RUNNERS = {
	c = {
		cmd = {
			"gcc $file -o /tmp/$fileNameWithoutExt",
			"/tmp/$fileNameWithoutExt",
		},
		cleanup_command = "rm /tmp/$fileNameWithoutExt",
	},
	cpp = {
		cmd = {
			"c++ -pipe $file -o /tmp/$fileNameWithoutExt",
			"/tmp/$fileNameWithoutExt",
		},
		cleanup_command = "rm /tmp/$fileNameWithoutExt",
	},
	rust = {
		cmd = {
			"rustc $file -o /tmp/$fileNameWithoutExt",
			"/tmp/$fileNameWithoutExt",
		},
		cleanup_command = "rm /tmp/$fileNameWithoutExt",
	},
	go = "go run $file",
	zig = "zig run $file",
	java = {
		cmd = {
			"javac $file",
			"java -cp $dir $fileNameWithoutExt",
		},
		cleanup_command = "rm -f $dir/$fileNameWithoutExt.class",
	},
	kotlin = {
		cmd = {
			"kotlinc $file -include-runtime -d /tmp/$fileNameWithoutExt.jar",
			"java -jar /tmp/$fileNameWithoutExt.jar",
		},
		cleanup_command = "rm /tmp/$fileNameWithoutExt.jar",
	},
	python = "python3 -u $file",
	javascript = "node $file",
	typescript = "bun $file",
	lua = "lua $file",
	ruby = "ruby $file",
	php = "php $file",
	perl = "perl $file",
	r = "Rscript $file",
	julia = "julia $file",
	sh = "bash $file",
	zsh = "zsh $file",
	html = "xdg-open $file",
	dart = "dart run $file",
	swift = "swift $file",
	elixir = "elixir $file",
	haskell = {
		cmd = {
			"ghc -o /tmp/$fileNameWithoutExt $file",
			"/tmp/$fileNameWithoutExt",
		},
		cleanup_command = "rm /tmp/$fileNameWithoutExt",
	},
	odin = "odin run $file -file",
	fortran = {
		cmd = {
			"gfortran $file -o /tmp/$fileNameWithoutExt",
			"/tmp/$fileNameWithoutExt",
		},
		cleanup_command = "rm /tmp/$fileNameWithoutExt",
	},
}

---@param payload table
---@return string
local function encode_json(payload)
	local encode = vim.json and vim.json.encode or vim.fn.json_encode
	return encode(payload)
end

---@param text string
---@return string
local function stable_hash(text)
	local hash = 0
	for index = 1, #text do
		hash = (hash * 131 + text:byte(index)) % 4294967296
	end
	return string.format("%08x", hash)
end

---@param source_path string
---@param filetype string
---@return string
local function selection_extension(source_path, filetype)
	local extension = vim.fn.fnamemodify(source_path, ":e")
	if type(extension) == "string" and extension ~= "" then
		return extension:lower()
	end
	return TEMP_FILE_EXTENSION_MAP[filetype] or ""
end

---@return string
local function selection_root()
	local explicit = os.getenv("ZIGNITE_RUN_CACHE_DIR")
	if type(explicit) == "string" and explicit ~= "" then
		return explicit
	end
	local xdg_cache_home = os.getenv("XDG_CACHE_HOME")
	if type(xdg_cache_home) == "string" and xdg_cache_home ~= "" then
		return xdg_cache_home .. "/zignite/run"
	end
	local home = os.getenv("HOME")
	if type(home) == "string" and home ~= "" then
		return home .. "/.cache/zignite/run"
	end
	return "/tmp/zignite-run"
end

---@param source_key string
---@param extension_source_path string
---@param filetype string
---@param inline_text string
---@return string
local function resolve_inline_execution_path(source_key, extension_source_path, filetype, inline_text)
	local root = selection_root()
	os.execute("mkdir -p " .. util.quote_shell_arg(root) .. " >/dev/null 2>&1")

	local extension = selection_extension(extension_source_path, filetype)
	local file_name = stable_hash(source_key .. "\0" .. filetype .. "\0" .. tostring(inline_text or ""))
	local execution_path = root .. "/" .. file_name .. (extension ~= "" and ("." .. extension) or "")

	local handle = io.open(execution_path, "w")
	if handle then
		handle:write(inline_text)
		handle:close()
	end

	return execution_path
end

---@param source_path string
---@return string|nil
local function read_source_file(source_path)
	if type(source_path) ~= "string" or source_path == "" then
		return nil
	end
	local handle = io.open(source_path, "r")
	if not handle then
		return nil
	end
	local contents = handle:read("*a")
	handle:close()
	return contents
end

---@param path string
---@param cwd string|nil
---@param shell_escape boolean
---@return string
local function substitute_runner_variables(template, path, cwd, shell_escape)
	local file = path
	local dir = util.dirname(path)
	local file_name = vim.fn.fnamemodify(path, ":t")
	local file_name_without_ext = vim.fn.fnamemodify(path, ":t:r")
	local file_ext = vim.fn.fnamemodify(path, ":e")
	local root = cwd or dir
	local dir_name = vim.fn.fnamemodify(root, ":t")

	local replacements = {
		["%%"] = file,
		["$dir"] = dir,
		["$file"] = file,
		["$fileName"] = file_name,
		["$fileNameWithoutExt"] = file_name_without_ext,
		["$fileExt"] = file_ext,
		["$dirName"] = dir_name,
	}

	local result = tostring(template or "")
	for key, value in pairs(replacements) do
		local replacement = shell_escape and util.quote_shell_arg(value) or value
		result = result:gsub(key:gsub("%%", "%%%%"), replacement)
	end
	return result
end

---@param command string
---@return boolean
local function has_unsupported_shell_syntax(command)
	if type(command) ~= "string" or command == "" then
		return true
	end
	return command:find("[`|;&<>]") ~= nil
		or command:find("%$%(") ~= nil
		or command:find("%$[%a_][%w_]*") ~= nil
		or command:find("%$%b{}") ~= nil
end

---@param command string
---@return string[]
function M.tokenize_command(command)
	if has_unsupported_shell_syntax(command) then
		return {}
	end

	local tokens = {}
	local i = 1
	local len = #command
	while i <= len do
		while i <= len and command:sub(i, i):match("%s") do
			i = i + 1
		end
		if i > len then
			break
		end

		local ch = command:sub(i, i)
		if ch == "'" or ch == '"' then
			local quote = ch
			local j = i + 1
			while j <= len and command:sub(j, j) ~= quote do
				j = j + 1
			end
			if j > len then
				return {}
			end
			tokens[#tokens + 1] = command:sub(i + 1, j - 1)
			i = j + 1
		else
			local j = i
			while j <= len and not command:sub(j, j):match("%s") do
				j = j + 1
			end
			tokens[#tokens + 1] = command:sub(i, j - 1)
			i = j
		end
	end

	return tokens
end

---@param final_command string
---@param argv string[]
---@param cleanup_command string|nil
---@return string[]
function M.build_system_argv(final_command, argv, cleanup_command)
	local config = require("zignite.config")
	local timeout = nil
	if type(config.options.timeout) == "number" and config.options.timeout > 0 then
		timeout = math.floor(config.options.timeout)
	end
	if timeout == nil and (type(cleanup_command) ~= "string" or cleanup_command == "") and type(argv) == "table" and #argv > 0 then
		local direct_argv = {}
		for _, arg in ipairs(argv) do
			direct_argv[#direct_argv + 1] = arg
		end
		return direct_argv
	end
	local system_argv = { SIMULATED_ZIGNITE_EXECUTABLE }
	if timeout ~= nil then
		system_argv[#system_argv + 1] = "--timeout=" .. timeout
	end
	if type(cleanup_command) == "string" and cleanup_command ~= "" then
		system_argv[#system_argv + 1] = "--cleanup=" .. cleanup_command
	end
	if type(argv) == "table" and #argv > 0 then
		system_argv[#system_argv + 1] = "--argv"
		for _, arg in ipairs(argv) do
			system_argv[#system_argv + 1] = arg
		end
	else
		system_argv[#system_argv + 1] = final_command
	end
	return system_argv
end

---@param runner any
---@return string|nil, string|nil, string|nil
local function parse_runner_value(runner)
	if type(runner) == "string" and runner ~= "" then
		return runner, nil, nil
	end
	if type(runner) ~= "table" then
		return nil, nil, nil
	end
	if type(runner.cmd) == "string" and runner.cmd ~= "" then
		return runner.cmd, runner.cleanup_command, runner.cwd
	end
	if type(runner.cmd) == "table" and #runner.cmd > 0 then
		return table.concat(runner.cmd, " && "), runner.cleanup_command, runner.cwd
	end
	if #runner > 0 then
		return table.concat(runner, " && "), nil, nil
	end
	return nil, nil, nil
end

---@param filepath string
---@param project_root string|nil
---@return string|nil
local function zig_project_root_if_required(filepath, project_root)
	local root = project_root
	if type(root) ~= "string" or root == "" then
		root = util.find_root_for_markers(filepath, { "build.zig" }, 12)
	end
	if type(root) ~= "string" or root == "" then
		return nil
	end
	if not util.filereadable(vim.fs.joinpath(root, "build.zig")) then
		return nil
	end

	local handle = io.open(filepath, "r")
	if not handle then
		return nil
	end
	local contents = handle:read("*a") or ""
	handle:close()

	local i = 1
	local line_start = true
	local only_leading_whitespace = true

	local function skip_to_line_end(index)
		while index <= #contents and contents:sub(index, index) ~= "\n" do
			index = index + 1
		end
		return index
	end

	local function skip_quoted(index, quote)
		while index <= #contents do
			local ch = contents:sub(index, index)
			if ch == "\\" and index < #contents then
				index = index + 2
			elseif ch == quote then
				return index + 1
			elseif ch == "\n" then
				return index
			else
				index = index + 1
			end
		end
		return index
	end

	while i <= #contents do
		local ch = contents:sub(i, i)

		if ch == "\n" then
			line_start = true
			only_leading_whitespace = true
			i = i + 1
		elseif line_start and only_leading_whitespace and (ch == " " or ch == "\t" or ch == "\r") then
			i = i + 1
		elseif line_start and only_leading_whitespace and ch == "\\" and contents:sub(i + 1, i + 1) == "\\" then
			i = skip_to_line_end(i + 2)
			line_start = false
			only_leading_whitespace = false
		else
			line_start = false
			only_leading_whitespace = false

			if ch == "/" and contents:sub(i + 1, i + 1) == "/" then
				i = skip_to_line_end(i + 2)
			elseif ch == '"' then
				i = skip_quoted(i + 1, '"')
			elseif ch == "'" then
				i = skip_quoted(i + 1, "'")
			elseif contents:sub(i, i + 8) == '@import("' then
				local close_index = contents:find('"', i + 9, true)
				if not close_index then
					return nil
				end
				local import_name = contents:sub(i + 9, close_index - 1)
				if import_name ~= "std" and import_name ~= "builtin" and import_name ~= "root"
					and not import_name:match("%.zig$")
				then
					return root
				end
				i = close_index + 1
			else
				i = i + 1
			end
		end
	end

	return nil
end

---@param request_text string
---@return string[]|nil
function M.parse_run_resolve_daemon_request(request_text)
	local args = util.parse_flag_request_with_payload(
		request_text,
		"@@ZRUN_REQ_BEGIN",
		"@@ZRUN_REQ_PAYLOAD_BEGIN",
		"@@ZRUN_REQ_PAYLOAD_END",
		"@@ZRUN_REQ_END"
	)
	if not args or not args.path or not args.filetype then
		return nil
	end

	local config = require("zignite.config")
	local options = config.options or {}
	local filetype = args.filetype
	local source_path = args.path
	local context_path = args["context-path"] or source_path
	local source_key = source_path ~= "" and source_path or string.format("buffer:%s", tostring(args["buffer-id"] or "0"))
	local project_root = args["project-root"]
	local execution_path = source_path
	local has_inline_source = type(args.selection_text) == "string" and args.selection_text ~= ""
	if has_inline_source then
		execution_path = resolve_inline_execution_path(source_key, source_path, filetype, args.selection_text or "")
	elseif filetype == "zig" and source_path ~= "" and not source_path:match("%.zig$") then
		local source_text = read_source_file(source_path)
		if type(source_text) == "string" then
			execution_path = resolve_inline_execution_path(source_key, "", filetype, source_text)
		end
	end
	local resolved_build_lines = {}
	if type(context_path) == "string" and context_path ~= "" then
		resolved_build_lines = build.collect_build_resolve_lines(filetype, context_path, project_root, false)
	end
	local meta, commands, preferred = build.decode_build_resolve_lines(resolved_build_lines)

	local response = { "@@ZRUN_RES_BEGIN " .. args.request_id }
	local configured_runner = type(options.runners) == "table" and options.runners[filetype] or nil
	local default_runner = BUILTIN_RUNNERS[filetype]
	local runner = configured_runner or default_runner

	if filetype == "zig" then
		local root = zig_project_root_if_required(context_path, project_root)
		if type(root) == "string" then
			local system_argv = M.build_system_argv("zig build run", { "zig", "build", "run" })
			response[#response + 1] = "\tRESULT_JSON\t" .. encode_json({
				execution_path = execution_path,
				command = "zig build run",
				argv = { "zig", "build", "run" },
				system_argv = system_argv,
				source = "project",
				filetype = filetype,
				config_revision = config.revision or 0,
				cwd = root,
				name = "Zig Project",
			})
			response[#response + 1] = "\tCOMMAND\tzig build run"
			response[#response + 1] = "\tEXECUTION_PATH\t" .. execution_path
			response[#response + 1] = "\tARGV\tzig"
			response[#response + 1] = "\tARGV\tbuild"
			response[#response + 1] = "\tARGV\trun"
			response[#response + 1] = "\tSOURCE\tproject"
			response[#response + 1] = "\tFILETYPE\t" .. filetype
			response[#response + 1] = "\tCONFIG_REVISION\t" .. tostring(config.revision or 0)
			response[#response + 1] = "\tCWD\t" .. root
			response[#response + 1] = "\tNAME\tZig Project"
			response[#response + 1] = "@@ZRUN_RES_END " .. args.request_id
			return response
		end
	end

	local command, cleanup_command, cwd = parse_runner_value(runner)
	local default_command = select(1, parse_runner_value(default_runner))
	if type(command) == "string" and filetype == "python" and command == default_command then
		local project_run = preferred.run or commands.run
		if type(project_run) == "string" and (project_run:match("^uv run ") or project_run:match("^conda run ")) then
			command = project_run
		end
	end
	if type(command) == "string" and command ~= "" then
		local resolved_command = substitute_runner_variables(command, execution_path, cwd, true)
		local argv = M.tokenize_command(substitute_runner_variables(command, execution_path, cwd, false))
		local resolved_cleanup = type(cleanup_command) == "string" and cleanup_command ~= ""
				and substitute_runner_variables(cleanup_command, execution_path, cwd, true)
			or nil
		local system_argv = M.build_system_argv(resolved_command, argv, resolved_cleanup)
		response[#response + 1] = "\tRESULT_JSON\t" .. encode_json({
			execution_path = execution_path,
			command = resolved_command,
			argv = argv,
			system_argv = system_argv,
			source = "filetype",
			filetype = filetype,
			config_revision = config.revision or 0,
			cwd = type(cwd) == "string" and cwd ~= "" and substitute_runner_variables(cwd, execution_path, nil, false) or nil,
			name = filetype,
		})
		response[#response + 1] = "\tCOMMAND\t" .. resolved_command
		response[#response + 1] = "\tEXECUTION_PATH\t" .. execution_path
		for _, arg in ipairs(argv) do
			response[#response + 1] = "\tARGV\t" .. arg
		end
		response[#response + 1] = "\tSOURCE\tfiletype"
		response[#response + 1] = "\tFILETYPE\t" .. filetype
		response[#response + 1] = "\tCONFIG_REVISION\t" .. tostring(config.revision or 0)
		if type(cwd) == "string" and cwd ~= "" then
			response[#response + 1] = "\tCWD\t" .. substitute_runner_variables(cwd, execution_path, nil, false)
		end
		response[#response + 1] = "\tNAME\t" .. filetype
		response[#response + 1] = "@@ZRUN_RES_END " .. args.request_id
		return response
	end

	local project_run = preferred.run or commands.run or preferred.live or commands.live or commands.build
	if type(project_run) == "string" and project_run ~= "" then
		local argv = M.tokenize_command(project_run)
		local system_argv = M.build_system_argv(project_run, argv)
		response[#response + 1] = "\tRESULT_JSON\t" .. encode_json({
			execution_path = execution_path,
			command = project_run,
			argv = argv,
			system_argv = system_argv,
			source = "project",
			filetype = filetype,
			config_revision = config.revision or 0,
			cwd = type(meta.root) == "string" and meta.root ~= "" and meta.root or nil,
			name = filetype:gsub("^%l", string.upper) .. " Project",
		})
		response[#response + 1] = "\tCOMMAND\t" .. project_run
		response[#response + 1] = "\tEXECUTION_PATH\t" .. execution_path
		for _, arg in ipairs(argv) do
			response[#response + 1] = "\tARGV\t" .. arg
		end
		response[#response + 1] = "\tSOURCE\tproject"
		response[#response + 1] = "\tFILETYPE\t" .. filetype
		response[#response + 1] = "\tCONFIG_REVISION\t" .. tostring(config.revision or 0)
		if type(meta.root) == "string" and meta.root ~= "" then
			response[#response + 1] = "\tCWD\t" .. meta.root
		end
		response[#response + 1] = "\tNAME\t" .. (filetype:gsub("^%l", string.upper) .. " Project")
	end

	response[#response + 1] = "\tRESULT_JSON\t" .. encode_json({
		ok = false,
		reason = "no_runner",
		message = "Error: No runner configured for filetype: " .. filetype,
		source = "filetype",
		filetype = filetype,
		config_revision = config.revision or 0,
	})
	response[#response + 1] = "\tOK\t0"
	response[#response + 1] = "\tREASON\tno_runner"
	response[#response + 1] = "\tMESSAGE\tError: No runner configured for filetype: " .. filetype
	response[#response + 1] = "\tSOURCE\tfiletype"
	response[#response + 1] = "\tFILETYPE\t" .. filetype
	response[#response + 1] = "\tCONFIG_REVISION\t" .. tostring(config.revision or 0)

	response[#response + 1] = "@@ZRUN_RES_END " .. args.request_id
	return response
end

return M
