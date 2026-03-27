local backend_client = require("zignite.backend.client")
local config = require("zignite.config")
local config_sync = require("zignite.backend.config_sync")

---@type table
local M = {}

local RUN_RESOLVE_REQ_BEGIN = "@@ZRUN_REQ_BEGIN"
local RUN_RESOLVE_REQ_END = "@@ZRUN_REQ_END"
local RUN_RESOLVE_RES_BEGIN = "@@ZRUN_RES_BEGIN"
local RUN_RESOLVE_RES_END = "@@ZRUN_RES_END"
local RUN_RESOLVE_RES_ERR = "@@ZRUN_RES_ERR"

local RUN_RESOLVE_PROTOCOL = {
	res_begin = RUN_RESOLVE_RES_BEGIN,
	res_end = RUN_RESOLVE_RES_END,
	res_err = RUN_RESOLVE_RES_ERR,
}

---@param value string
---@return boolean
local function contains_control_characters(value)
	return type(value) ~= "string" or value == "" or value:find("[%c]") ~= nil
end

---@param filepath string
---@return boolean
local function can_use_backend_run_resolve(filepath)
	if type(filepath) ~= "string" or filepath == "" then
		return false
	end
	return tonumber(config_sync.get_last_synced_revision and config_sync.get_last_synced_revision() or 0)
		== tonumber(config.revision or 0)
end

---@param request_id integer
---@param params table
---@return string|nil
local function build_worker_payload(request_id, params)
	local filepath = type(params) == "table" and params.path or nil
	local filetype = type(params) == "table" and params.filetype or nil
	local context_path = type(params) == "table" and params.context_path or nil
	if contains_control_characters(filepath) or contains_control_characters(filetype) then
		return nil
	end

	local lines = {
		string.format("%s %d", RUN_RESOLVE_REQ_BEGIN, request_id),
		"\t--run-resolve",
		"\t--path=" .. filepath,
		"\t--filetype=" .. filetype,
	}
	if type(context_path) == "string" and context_path ~= "" then
		if contains_control_characters(context_path) then
			return nil
		end
		lines[#lines + 1] = "\t--context-path=" .. context_path
	end
	lines[#lines + 1] = string.format("%s %d", RUN_RESOLVE_REQ_END, request_id)
	return table.concat(lines, "\n") .. "\n"
end

---@param params table
---@return string[]|nil
local function build_once_argv(params)
	local filepath = type(params) == "table" and params.path or nil
	local filetype = type(params) == "table" and params.filetype or nil
	local context_path = type(params) == "table" and params.context_path or nil
	if contains_control_characters(filepath) or contains_control_characters(filetype) then
		return nil
	end

	local argv = {
		backend_client.ZIG_EXECUTABLE,
		"--run-resolve",
		"--path=" .. filepath,
		"--filetype=" .. filetype,
	}
	if type(context_path) == "string" and context_path ~= "" then
		if contains_control_characters(context_path) then
			return nil
		end
		argv[#argv + 1] = "--context-path=" .. context_path
	end
	return argv
end

local resolve_client = backend_client.new({
	executable = backend_client.ZIG_EXECUTABLE,
	worker_argv = { backend_client.ZIG_EXECUTABLE, "--daemon" },
	protocol = RUN_RESOLVE_PROTOCOL,
	worker_wait_ms = 1200,
	request_timeout_ms = 3000,
	buffered_stdout = true,
	reset_on_sync_timeout = true,
	build_worker_payload = build_worker_payload,
	build_once_argv = build_once_argv,
})

---@param lines string[]|nil
---@return table
local function decode_resolved_lines(lines)
	local result = { argv = {} }
	for _, raw_line in ipairs(lines or {}) do
		local line = tostring(raw_line or "")
		local kind, value = line:match("^([^\t]+)\t(.+)$")
		if kind == "COMMAND" then
			result.command = value
		elseif kind == "ARGV" then
			result.argv[#result.argv + 1] = value
		elseif kind == "SOURCE" then
			result.source = value
		elseif kind == "FILETYPE" then
			result.filetype = value
		elseif kind == "CLEANUP_COMMAND" then
			result.cleanup_command = value
		elseif kind == "CWD" then
			result.cwd = value
		elseif kind == "NAME" then
			result.name = value
		elseif kind == "CONFIG_REVISION" then
			result.config_revision = tonumber(value)
		end
	end
	return result
end

---@param filepath string
---@param filetype string
---@param context_path string|nil
---@return table|nil
function M.resolve_sync(filepath, filetype, context_path)
	if not can_use_backend_run_resolve(filepath) then
		return nil
	end
	local lines = resolve_client.sync_request({
		path = filepath,
		filetype = filetype,
		context_path = context_path,
	}) or resolve_client.once_request({
		path = filepath,
		filetype = filetype,
		context_path = context_path,
	})
	if type(lines) ~= "table" then
		return nil
	end
	local resolved = decode_resolved_lines(lines)
	if type(resolved.command) ~= "string" or resolved.command == "" then
		return nil
	end
	return resolved
end

return M
