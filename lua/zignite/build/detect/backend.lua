local cache_utils = require("zignite.utils.cache")
local backend_client = require("zignite.backend.client")

---@type table
local M = {}

local DETECT_REQ_BEGIN = "@@ZDET_REQ_BEGIN"
local DETECT_REQ_END = "@@ZDET_REQ_END"
local DETECT_RES_BEGIN = "@@ZDET_RES_BEGIN"
local DETECT_RES_END = "@@ZDET_RES_END"
local DETECT_RES_ERR = "@@ZDET_RES_ERR"
local DETECT_WORKER_WAIT_MS = 1200
local DETECT_WORKER_REQUEST_TIMEOUT_MS = 3000
local PROJECT_REQ_BEGIN = "@@ZPRJ_REQ_BEGIN"
local PROJECT_REQ_END = "@@ZPRJ_REQ_END"
local PROJECT_RES_BEGIN = "@@ZPRJ_RES_BEGIN"
local PROJECT_RES_END = "@@ZPRJ_RES_END"
local PROJECT_RES_ERR = "@@ZPRJ_RES_ERR"
local PROJECT_WORKER_WAIT_MS = 1200

local ZIG_EXECUTABLE = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h:h")
	.. "/zig/zig-out/bin/zignite"

local DETECT_PROTOCOL = {
	res_begin = DETECT_RES_BEGIN,
	res_end = DETECT_RES_END,
	res_err = DETECT_RES_ERR,
}

local PROJECT_PROTOCOL = {
	res_begin = PROJECT_RES_BEGIN,
	res_end = PROJECT_RES_END,
	res_err = PROJECT_RES_ERR,
}

---@param value string
---@return boolean
local function contains_control_characters(value)
	return type(value) ~= "string" or value == "" or value:find("[%c]") ~= nil
end

---@param request_id integer
---@param params table
---@return string|nil
local function build_detect_payload(request_id, params)
	local tool = type(params) == "table" and params.tool or nil
	if contains_control_characters(tool) then
		return nil
	end
	return string.format("%s %d %s\n%s %d\n", DETECT_REQ_BEGIN, request_id, tool, DETECT_REQ_END, request_id)
end

---@param request_id integer
---@param params table
---@return string|nil
local function build_project_payload(request_id, params)
	local kind = type(params) == "table" and params.kind or nil
	local path = type(params) == "table" and params.path or nil
	if contains_control_characters(kind) or contains_control_characters(path) then
		return nil
	end

	local payload_lines = {
		string.format("%s %d", PROJECT_REQ_BEGIN, request_id),
		"\t--kind=" .. kind,
		"\t--path=" .. path,
	}
	for _, arg in ipairs((type(params) == "table" and params.extra_args) or {}) do
		if type(arg) == "string" and arg ~= "" then
			if contains_control_characters(arg) then
				return nil
			end
			payload_lines[#payload_lines + 1] = "\t" .. arg
		end
	end
	payload_lines[#payload_lines + 1] = string.format("%s %d", PROJECT_REQ_END, request_id)
	return table.concat(payload_lines, "\n") .. "\n"
end

---@param params table
---@return string[]|nil
local function build_detect_once_argv(params)
	local tool = type(params) == "table" and params.tool or nil
	if contains_control_characters(tool) then
		return nil
	end
	return { ZIG_EXECUTABLE, "--detect", "--tool=" .. tool }
end

---@param params table
---@return string[]|nil
local function build_project_once_argv(params)
	local kind = type(params) == "table" and params.kind or nil
	local path = type(params) == "table" and params.path or nil
	if contains_control_characters(kind) or contains_control_characters(path) then
		return nil
	end

	---@type string[]
	local argv = {
		ZIG_EXECUTABLE,
		"--project-parse",
		"--kind=" .. kind,
		"--path=" .. path,
	}
	for _, arg in ipairs((type(params) == "table" and params.extra_args) or {}) do
		if type(arg) == "string" and arg ~= "" then
			if contains_control_characters(arg) then
				return nil
			end
			argv[#argv + 1] = arg
		end
	end
	return argv
end

local detect_client = backend_client.new({
	executable = ZIG_EXECUTABLE,
	worker_argv = { ZIG_EXECUTABLE, "--daemon" },
	protocol = DETECT_PROTOCOL,
	worker_wait_ms = DETECT_WORKER_WAIT_MS,
	request_timeout_ms = DETECT_WORKER_REQUEST_TIMEOUT_MS,
	build_worker_payload = build_detect_payload,
	build_once_argv = build_detect_once_argv,
})

local project_client = backend_client.new({
	executable = ZIG_EXECUTABLE,
	worker_argv = { ZIG_EXECUTABLE, "--daemon" },
	protocol = PROJECT_PROTOCOL,
	worker_wait_ms = PROJECT_WORKER_WAIT_MS,
	buffered_stdout = true,
	reset_on_sync_timeout = true,
	build_worker_payload = build_project_payload,
	build_once_argv = build_project_once_argv,
})

---@param tool string
---@param build_from_names fun(tool: string, names: string[]): table<string, string>
---@return table<string, string>|nil
function M.detect_with_zig_worker(tool, build_from_names)
	local lines = detect_client.sync_request({ tool = tool })
	if type(lines) ~= "table" then
		return nil
	end
	local commands = build_from_names(tool, lines)
	if vim.tbl_isempty(commands) then
		return nil
	end
	return commands
end

---@param tool string
---@param on_done fun(commands: table<string, string>|nil):nil
---@param build_from_names fun(tool: string, names: string[]): table<string, string>
---@return boolean
function M.detect_with_zig_worker_async(tool, on_done, build_from_names)
	return detect_client.async_request({ tool = tool }, function(lines)
		if type(lines) ~= "table" then
			on_done(nil)
			return
		end
		local commands = build_from_names(tool, lines)
		if vim.tbl_isempty(commands) then
			on_done(nil)
			return
		end
		on_done(cache_utils.copy_string_map(commands))
	end)
end

---@param tool string
---@param build_from_names fun(tool: string, names: string[]): table<string, string>
---@return table<string, string>|nil
function M.detect_with_zig_once(tool, build_from_names)
	local lines = detect_client.once_request({ tool = tool })
	if type(lines) ~= "table" then
		return nil
	end
	local commands = build_from_names(tool, lines)
	if vim.tbl_isempty(commands) then
		return nil
	end
	return commands
end

---@param tool string
---@param on_done fun(commands: table<string, string>|nil):nil
---@param build_from_names fun(tool: string, names: string[]): table<string, string>
---@return boolean
function M.detect_with_zig_once_async(tool, on_done, build_from_names)
	return detect_client.once_request_async({ tool = tool }, function(lines)
		if type(lines) ~= "table" then
			on_done(nil)
			return
		end
		local commands = build_from_names(tool, lines)
		if vim.tbl_isempty(commands) then
			on_done(nil)
			return
		end
		on_done(commands)
	end)
end

---@param kind string
---@param path string
---@param extra_args string[]|nil
---@return string[]|nil
function M.parse_project_lines_once(kind, path, extra_args)
	if type(kind) ~= "string" or kind == "" or type(path) ~= "string" or path == "" then
		return nil
	end
	if not project_client.has_backend() then
		return nil
	end
	local params = {
		kind = kind,
		path = path,
		extra_args = extra_args,
	}
	return project_client.sync_request(params) or project_client.once_request(params)
end

---@param kind string
---@param path string
---@return string[]|nil
function M.parse_project_names_once(kind, path)
	return M.parse_project_lines_once(kind, path, nil)
end

---@return nil
function M.reset()
	detect_client.reset()
	project_client.reset()
end

return M
