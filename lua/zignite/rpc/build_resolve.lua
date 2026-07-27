local backend_client = require("zignite.rpc.transport")
local common_path_request = require("zignite.rpc.common_path_request")
local config_sync = require("zignite.rpc.config_sync")
local input_guard = require("zignite.rpc.input_guard")
local json_result = require("zignite.rpc.json_result")

---@type table
local M = {}

local BUILD_RESOLVE_REQ_BEGIN = "@@ZBR_REQ_BEGIN"
local BUILD_RESOLVE_REQ_END = "@@ZBR_REQ_END"
local BUILD_RESOLVE_RES_BEGIN = "@@ZBR_RES_BEGIN"
local BUILD_RESOLVE_RES_END = "@@ZBR_RES_END"
local BUILD_RESOLVE_RES_ERR = "@@ZBR_RES_ERR"
local BUILD_ACTION_REQ_BEGIN = "@@ZBA_REQ_BEGIN"
local BUILD_ACTION_REQ_END = "@@ZBA_REQ_END"
local BUILD_ACTION_RES_BEGIN = "@@ZBA_RES_BEGIN"
local BUILD_ACTION_RES_END = "@@ZBA_RES_END"
local BUILD_ACTION_RES_ERR = "@@ZBA_RES_ERR"

local BUILD_RESOLVE_PROTOCOL = {
	res_begin = BUILD_RESOLVE_RES_BEGIN,
	res_end = BUILD_RESOLVE_RES_END,
	res_err = BUILD_RESOLVE_RES_ERR,
}

local BUILD_ACTION_PROTOCOL = {
	res_begin = BUILD_ACTION_RES_BEGIN,
	res_end = BUILD_ACTION_RES_END,
	res_err = BUILD_ACTION_RES_ERR,
}
local BUILD_RESOLVE_SYNC_WAIT_MS = 1500
local BUILD_RESOLVE_ASYNC_TIMEOUT_MS = 3000
local BUILD_ACTION_SYNC_WAIT_MS = 1500
local BUILD_ACTION_ASYNC_TIMEOUT_MS = 3000

---@param filetype string|nil
---@param message string
---@param reason string|nil
---@return table
local function failed_build_resolution(filetype, message, reason)
	return {
		ok = false,
		reason = reason or "backend_unavailable",
		filetype = type(filetype) == "string" and filetype or "",
		message = message,
	}
end

---@param params table
---@return { path: string|nil, filetype: string|nil, extras: {name:string,value:string|nil}[] }
local function unpack_build_params(params)
	local p = type(params) == "table" and params or {}
	local extras = {}
	if p.command_name then extras[#extras + 1] = { name = "command-name", value = p.command_name } end
	if p.command_args then extras[#extras + 1] = { name = "command-args", value = p.command_args } end
	if p.action then extras[#extras + 1] = { name = "action", value = p.action } end
	return { path = p.path, filetype = p.filetype, extras = extras }
end

---@param req_begin string
---@param req_end string
---@param backend_flag string
---@param request_id integer
---@param params table
---@return string|nil
local function compose_worker_payload(req_begin, req_end, backend_flag, request_id, params)
	local p = unpack_build_params(params)
	return common_path_request.compose_worker_payload(
		req_begin,
		req_end,
		request_id,
		backend_flag,
		p.path,
		p.filetype,
		p.extras,
		input_guard.is_invalid_payload_value
	)
end

---@param backend_flag string
---@param params table
---@return string[]|nil
local function compose_once_argv(backend_flag, params)
	local p = unpack_build_params(params)
	return common_path_request.compose_once_argv(
		backend_client.ZIG_EXECUTABLE,
		backend_flag,
		p.path,
		p.filetype,
		p.extras,
		input_guard.is_invalid_payload_value
	)
end

local resolve_client = backend_client.new({
	executable = backend_client.ZIG_EXECUTABLE,
	worker_argv = { backend_client.ZIG_EXECUTABLE, "--daemon" },
	protocol = BUILD_RESOLVE_PROTOCOL,
	worker_wait_ms = BUILD_RESOLVE_SYNC_WAIT_MS,
	request_timeout_ms = BUILD_RESOLVE_ASYNC_TIMEOUT_MS,
	reset_on_sync_timeout = true,
	build_worker_payload = function(request_id, params)
		return compose_worker_payload(BUILD_RESOLVE_REQ_BEGIN, BUILD_RESOLVE_REQ_END, "--build-resolve", request_id, params)
	end,
	build_once_argv = function(params)
		return compose_once_argv("--build-resolve", params)
	end,
})

local action_client = backend_client.new({
	executable = backend_client.ZIG_EXECUTABLE,
	worker_argv = { backend_client.ZIG_EXECUTABLE, "--daemon" },
	protocol = BUILD_ACTION_PROTOCOL,
	worker_wait_ms = BUILD_ACTION_SYNC_WAIT_MS,
	request_timeout_ms = BUILD_ACTION_ASYNC_TIMEOUT_MS,
	reset_on_sync_timeout = true,
	build_worker_payload = function(request_id, params)
		return compose_worker_payload(BUILD_ACTION_REQ_BEGIN, BUILD_ACTION_REQ_END, "--build-action", request_id, params)
	end,
	build_once_argv = function(params)
		return compose_once_argv("--build-action", params)
	end,
})

---@param resolved table|nil
---@return table
local function normalize_resolved_output(resolved)
	local output = type(resolved) == "table" and resolved or {}
	output.commands = type(output.commands) == "table" and output.commands or {}
	output.command_meta = type(output.command_meta) == "table" and output.command_meta or {}
	output.command_entries = type(output.command_entries) == "table" and output.command_entries or {}
	output.completion_names = type(output.completion_names) == "table" and output.completion_names or {}
	output.preferred_commands = type(output.preferred_commands) == "table" and output.preferred_commands or {}
	output.preferred_names = type(output.preferred_names) == "table" and output.preferred_names or {}
	if output.ok == nil then
		output.ok = next(output.commands) ~= nil or #output.command_entries > 0
	end
	return output
end

---@param filepath string
---@param filetype string
---@return table
function M.resolve_sync(filepath, filetype)
	local lines
	-- Try daemon path with config sync
	if config_sync.ensure_current() then
		lines = resolve_client.sync_request({
			path = filepath,
			filetype = filetype,
		})
	end
	-- Always fall back to one-shot if daemon path fails
	if type(lines) ~= "table" then
		lines = resolve_client.once_request({
			path = filepath,
			filetype = filetype,
		})
	end
	if type(lines) ~= "table" then
		return normalize_resolved_output(failed_build_resolution(
			filetype,
			string.format("Failed to resolve build commands for %s. Backend unavailable or timed out.", tostring(filetype or "")),
			"backend_unavailable"
		))
	end
	local resolved = json_result.decode(lines)
	if type(resolved) ~= "table" then
		return normalize_resolved_output(failed_build_resolution(
			filetype,
			string.format("Failed to resolve build commands for %s.", tostring(filetype or "")),
			"invalid_backend_response"
		))
	end
	return normalize_resolved_output(resolved)
end

---@param filepath string
---@param filetype string
---@param action "named"|"live"|"last"
---@param command_name string|nil
---@param command_args string|nil
---@return table|nil
function M.resolve_action_sync(filepath, filetype, action, command_name, command_args)
	local lines
	-- Try daemon path with config sync
	if config_sync.ensure_current() then
		lines = action_client.sync_request({
			path = filepath,
			filetype = filetype,
			action = action,
			command_name = command_name,
			command_args = command_args,
		})
	end
	-- Always fall back to one-shot if daemon path fails
	if type(lines) ~= "table" then
		lines = action_client.once_request({
			path = filepath,
			filetype = filetype,
			action = action,
			command_name = command_name,
			command_args = command_args,
		})
	end
	if type(lines) ~= "table" then
		return failed_build_resolution(
			filetype,
			string.format("Failed to resolve build action for %s. Backend unavailable or timed out.", tostring(filetype or "")),
			"backend_unavailable"
		)
	end
	local resolved = json_result.decode(lines)
	if type(resolved) ~= "table" then
		return failed_build_resolution(
			filetype,
			string.format("Failed to resolve build action for %s.", tostring(filetype or "")),
			"invalid_backend_response"
		)
	end
	if type(resolved.exec_argv) ~= "table" or #resolved.exec_argv == 0 then
		resolved.exec_argv = nil
	end
	if type(resolved.system_argv) == "table" and #resolved.system_argv > 0 then
		return resolved
	end
	resolved.system_argv = nil
	return resolved
end

---@param filepath string
---@param filetype string
---@param action "named"|"live"|"last"
---@param command_name string|nil
---@param provided_args string|nil
---@param prompt_args fun(plan: table, current_args: string|nil): string|false|nil
---@return table|nil
function M.resolve_action_interactive(filepath, filetype, action, command_name, provided_args, prompt_args)
	local function resolve_with_args(command_args)
		return M.resolve_action_sync(filepath, filetype, action, command_name, command_args)
	end

	local plan = resolve_with_args(provided_args)
	if plan.requires_arguments == true then
		if type(prompt_args) ~= "function" then
			return failed_build_resolution(
				filetype,
				string.format("Failed to collect required arguments for build action in %s.", tostring(filetype or "")),
				"prompt_unavailable"
			)
		end
		local command_args = prompt_args(plan, provided_args)
		if command_args == false or command_args == nil then
			return failed_build_resolution(
				filetype,
				nil,
				"cancelled"
			)
		end
		plan = resolve_with_args(command_args)
	end

	return plan
end

---@param filetype string
---@param reason string
---@return table
local function build_resolve_failure(filetype, reason)
	local messages = {
		config_sync_failed = "Failed to resolve build commands for %s.",
		backend_unavailable = "Failed to resolve build commands for %s. Backend unavailable or timed out.",
		invalid_backend_response = "Failed to resolve build commands for %s.",
	}
	return normalize_resolved_output(failed_build_resolution(
		filetype,
		string.format(messages[reason] or "Failed to resolve build commands for %s.", tostring(filetype or "")),
		reason
	))
end

---@param lines string[]|nil
---@param filetype string
---@param on_done fun(result: table):nil
---@return boolean
local function handle_resolve_lines(lines, filetype, on_done)
	if type(lines) ~= "table" then
		on_done(build_resolve_failure(filetype, "backend_unavailable"))
		return false
	end
	local resolved = json_result.decode(lines)
	if type(resolved) ~= "table" then
		on_done(build_resolve_failure(filetype, "invalid_backend_response"))
		return false
	end
	on_done(normalize_resolved_output(resolved))
	return true
end

---@param filepath string
---@param filetype string
---@param on_done fun(result: table|nil):nil
---@return boolean
function M.resolve_async(filepath, filetype, on_done)
	-- Try daemon path first
	if resolve_client.async_request({
		path = filepath,
		filetype = filetype,
	}, function(lines)
		-- Note: daemon responses already use synced config
		handle_resolve_lines(lines, filetype, on_done)
	end) then
		return true
	end

	-- Fall back to one-shot async (no daemon needed, works without config sync)
	if resolve_client.once_request_async({
		path = filepath,
		filetype = filetype,
	}, function(lines)
		handle_resolve_lines(lines, filetype, on_done)
	end) then
		return true
	end

	on_done(build_resolve_failure(filetype, "backend_unavailable"))
	return false
end

---@param filepath string
---@param filetype string
---@param on_refresh fun(result: table):nil|nil
---@return table
function M.resolve_for_picker(filepath, filetype, on_refresh)
	local resolved = normalize_resolved_output(M.resolve_sync(filepath, filetype))
	if type(on_refresh) == "function" then
		M.resolve_async(filepath, filetype, function(updated)
			on_refresh(normalize_resolved_output(updated))
		end)
	end
	return resolved
end

---@param on_done fun(healthy: boolean):nil
---@param timeout_ms integer|nil
---@return boolean
function M.ping_async(on_done, timeout_ms)
	return resolve_client.ping_async(on_done, timeout_ms)
end

return M
