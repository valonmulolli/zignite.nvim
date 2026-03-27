local backend_client = require("zignite.backend.client")

---@type table
local M = {}

local BUILD_RESOLVE_REQ_BEGIN = "@@ZBR_REQ_BEGIN"
local BUILD_RESOLVE_REQ_END = "@@ZBR_REQ_END"
local BUILD_RESOLVE_RES_BEGIN = "@@ZBR_RES_BEGIN"
local BUILD_RESOLVE_RES_END = "@@ZBR_RES_END"
local BUILD_RESOLVE_RES_ERR = "@@ZBR_RES_ERR"

local BUILD_RESOLVE_PROTOCOL = {
	res_begin = BUILD_RESOLVE_RES_BEGIN,
	res_end = BUILD_RESOLVE_RES_END,
	res_err = BUILD_RESOLVE_RES_ERR,
}

---@param value string
---@return boolean
local function contains_control_characters(value)
	return type(value) ~= "string" or value == "" or value:find("[%c]") ~= nil
end

---@param request_id integer
---@param params table
---@return string|nil
local function build_worker_payload(request_id, params)
	local filepath = type(params) == "table" and params.path or nil
	local filetype = type(params) == "table" and params.filetype or nil
	local command_name = type(params) == "table" and params.command_name or nil
	local command_args = type(params) == "table" and params.command_args or nil
	if contains_control_characters(filepath) or contains_control_characters(filetype) then
		return nil
	end

	local lines = {
		string.format("%s %d", BUILD_RESOLVE_REQ_BEGIN, request_id),
		"\t--build-resolve",
		"\t--path=" .. filepath,
		"\t--filetype=" .. filetype,
	}
	if type(command_name) == "string" and command_name ~= "" then
		if contains_control_characters(command_name) then
			return nil
		end
		lines[#lines + 1] = "\t--command-name=" .. command_name
	end
	if type(command_args) == "string" and command_args ~= "" then
		if contains_control_characters(command_args) then
			return nil
		end
		lines[#lines + 1] = "\t--command-args=" .. command_args
	end
	lines[#lines + 1] = string.format("%s %d", BUILD_RESOLVE_REQ_END, request_id)
	return table.concat(lines, "\n") .. "\n"
end

---@param params table
---@return string[]|nil
local function build_once_argv(params)
	local filepath = type(params) == "table" and params.path or nil
	local filetype = type(params) == "table" and params.filetype or nil
	local command_name = type(params) == "table" and params.command_name or nil
	local command_args = type(params) == "table" and params.command_args or nil
	if contains_control_characters(filepath) or contains_control_characters(filetype) then
		return nil
	end

	local argv = {
		backend_client.ZIG_EXECUTABLE,
		"--build-resolve",
		"--path=" .. filepath,
		"--filetype=" .. filetype,
	}
	if type(command_name) == "string" and command_name ~= "" then
		if contains_control_characters(command_name) then
			return nil
		end
		argv[#argv + 1] = "--command-name=" .. command_name
	end
	if type(command_args) == "string" and command_args ~= "" then
		if contains_control_characters(command_args) then
			return nil
		end
		argv[#argv + 1] = "--command-args=" .. command_args
	end
	return argv
end

local resolve_client = backend_client.new({
	executable = backend_client.ZIG_EXECUTABLE,
	worker_argv = { backend_client.ZIG_EXECUTABLE, "--daemon" },
	protocol = BUILD_RESOLVE_PROTOCOL,
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
	local result = {
		commands = {},
		preferred_commands = {},
		command_meta = {},
	}
	for _, raw_line in ipairs(lines or {}) do
		local line = tostring(raw_line or "")
		local kind, name, value = line:match("^([^\t]+)\t([^\t]+)\t(.+)$")
		if kind == "COMMAND" then
			result.commands[name] = value
		elseif kind == "COMMAND_DISPLAY" then
			result.command_meta[name] = result.command_meta[name] or {}
			result.command_meta[name].display_command = value
		elseif kind == "COMMAND_ARGS_REQUIRED" then
			result.command_meta[name] = result.command_meta[name] or {}
			result.command_meta[name].requires_arguments = value == "1"
		elseif kind == "COMMAND_ARG_PROMPT" then
			result.command_meta[name] = result.command_meta[name] or {}
			result.command_meta[name].argument_prompt = value
		elseif kind == "COMMAND_ARG_HELP" then
			result.command_meta[name] = result.command_meta[name] or {}
			result.command_meta[name].argument_help = value
		elseif kind == "PREFERRED" then
			result.preferred_commands[name] = value
		else
			kind, value = line:match("^([^\t]+)\t(.+)$")
			if kind == "ROOT" then
				result.root = value
			elseif kind == "FILETYPE" then
				result.filetype = value
			elseif kind == "NAME" then
				result.name = value
			elseif kind == "CWD" then
				result.cwd = value
			elseif kind == "EXEC_COMMAND" then
				result.exec_command = value
			elseif kind == "SYSTEM" then
				result.system = value
			elseif kind == "BUILD_READY" then
				result.build_ready = value == "1"
			elseif kind == "CONFIG_REVISION" then
				result.config_revision = tonumber(value)
			end
		end
	end
	return result
end

---@param filepath string
---@param filetype string
---@return table|nil
function M.resolve_sync(filepath, filetype)
	local lines = resolve_client.sync_request({
		path = filepath,
		filetype = filetype,
	})
	if type(lines) ~= "table" then
		return nil
	end
	return decode_resolved_lines(lines)
end

---@param filepath string
---@param filetype string
---@param command_name string
---@param command_args string|nil
---@return table|nil
function M.resolve_command_sync(filepath, filetype, command_name, command_args)
	local lines = resolve_client.sync_request({
		path = filepath,
		filetype = filetype,
		command_name = command_name,
		command_args = command_args,
	})
	if type(lines) ~= "table" then
		return nil
	end
	local resolved = decode_resolved_lines(lines)
	if type(resolved.exec_command) ~= "string" or resolved.exec_command == "" then
		return nil
	end
	return resolved
end

---@param filepath string
---@param filetype string
---@param on_done fun(result: table|nil):nil
---@return boolean
function M.resolve_async(filepath, filetype, on_done)
	return resolve_client.async_request({
		path = filepath,
		filetype = filetype,
	}, function(lines)
		if type(lines) ~= "table" then
			on_done(nil)
			return
		end
		on_done(decode_resolved_lines(lines))
	end) or resolve_client.once_request_async({
		path = filepath,
		filetype = filetype,
	}, function(lines)
		if type(lines) ~= "table" then
			on_done(nil)
			return
		end
		on_done(decode_resolved_lines(lines))
	end)
end

return M
