local backend_client = require("zignite.rpc.transport")
local common_path_request = require("zignite.rpc.common_path_request")
local config_sync = require("zignite.rpc.config_sync")
local input_guard = require("zignite.rpc.input_guard")
local json_result = require("zignite.rpc.json_result")

---@type table
local M = {}

local RUN_RESOLVE_REQ_BEGIN = "@@ZRUN_REQ_BEGIN"
local RUN_RESOLVE_REQ_PAYLOAD_BEGIN = "@@ZRUN_REQ_PAYLOAD_BEGIN"
local RUN_RESOLVE_REQ_PAYLOAD_END = "@@ZRUN_REQ_PAYLOAD_END"
local RUN_RESOLVE_REQ_END = "@@ZRUN_REQ_END"
local RUN_RESOLVE_RES_BEGIN = "@@ZRUN_RES_BEGIN"
local RUN_RESOLVE_RES_END = "@@ZRUN_RES_END"
local RUN_RESOLVE_RES_ERR = "@@ZRUN_RES_ERR"

local RUN_RESOLVE_PROTOCOL = {
	res_begin = RUN_RESOLVE_RES_BEGIN,
	res_end = RUN_RESOLVE_RES_END,
	res_err = RUN_RESOLVE_RES_ERR,
}
local RUN_RESOLVE_SYNC_WAIT_MS = 5000
local RUN_RESOLVE_ASYNC_TIMEOUT_MS = 1500

---@param filetype string|nil
---@param message string
---@param reason string|nil
---@return table
local function failed_resolution(filetype, message, reason)
	return {
		ok = false,
		reason = reason or "backend_unavailable",
		filetype = type(filetype) == "string" and filetype or "",
		message = message,
	}
end

---@param filepath string|nil
---@param has_inline_source boolean
---@return boolean
local function can_use_backend_run_resolve(filepath, has_inline_source)
	if not has_inline_source and (type(filepath) ~= "string" or filepath == "") then
		return false
	end
	if has_inline_source and type(filepath) ~= "string" then
		return false
	end
	return config_sync.ensure_current()
end

---@param value any
---@return boolean
local function contains_invalid_payload_characters(value)
	if type(value) ~= "string" or value == "" then
		return true
	end
	return value:find("[\0\1-\8\11\12\14-\31]") ~= nil
end

---@param text string
---@return string[]
local function split_payload_lines(text)
	local normalized = tostring(text or ""):gsub("\r\n?", "\n")
	local lines = {}
	for line in (normalized .. "\n"):gmatch("([^\n]*)\n") do
		lines[#lines + 1] = line
	end
	if #lines > 0 and lines[#lines] == "" then
		lines[#lines] = nil
	end
	return lines
end

---@param request_id integer
---@param params table
---@return string|nil
local function build_worker_payload(request_id, params)
	local filepath = type(params) == "table" and params.path or nil
	local filetype = type(params) == "table" and params.filetype or nil
	local context_path = type(params) == "table" and params.context_path or nil
	local buffer_id = type(params) == "table" and params.buffer_id or nil
	local selection_text = type(params) == "table" and params.selection_text or nil
	local has_inline_source = type(selection_text) == "string" and selection_text ~= ""
	local allow_empty_path = has_inline_source
	if input_guard.contains_control_characters(filepath, allow_empty_path) or input_guard.contains_control_characters(filetype) then
		return nil
	end
	if type(context_path) == "string" and context_path ~= "" and input_guard.contains_control_characters(context_path) then
		return nil
	end
	if buffer_id ~= nil and tonumber(buffer_id) == nil then
		return nil
	end
	if has_inline_source and contains_invalid_payload_characters(selection_text) then
		return nil
	end

	local lines = common_path_request.begin_worker_lines(
		RUN_RESOLVE_REQ_BEGIN,
		request_id,
		"--run-resolve",
		filepath,
		filetype
	)
	if type(context_path) == "string" and context_path ~= "" then
		common_path_request.append_optional_worker_flag(lines, "context-path", context_path)
	end
	if buffer_id ~= nil then
		common_path_request.append_optional_worker_flag(lines, "buffer-id", tostring(math.floor(tonumber(buffer_id))))
	end

	if has_inline_source then
		lines[#lines + 1] = string.format("%s %d", RUN_RESOLVE_REQ_PAYLOAD_BEGIN, request_id)
		for _, line in ipairs(split_payload_lines(selection_text)) do
			lines[#lines + 1] = "\t" .. line
		end
		lines[#lines + 1] = string.format("%s %d", RUN_RESOLVE_REQ_PAYLOAD_END, request_id)
	end

	return common_path_request.finish_worker_payload(lines, RUN_RESOLVE_REQ_END, request_id)
end

---@param params table
---@return string[]|nil
local function build_once_argv(params)
	local filepath = type(params) == "table" and params.path or nil
	local filetype = type(params) == "table" and params.filetype or nil
	local context_path = type(params) == "table" and params.context_path or nil
	local buffer_id = type(params) == "table" and params.buffer_id or nil
	local selection_text = type(params) == "table" and params.selection_text or nil
	local has_inline_source = type(selection_text) == "string" and selection_text ~= ""
	if has_inline_source then
		return nil
	end
	return common_path_request.compose_once_argv(
		backend_client.ZIG_EXECUTABLE,
		"--run-resolve",
		filepath,
		filetype,
		{
			{ name = "context-path", value = context_path },
			{ name = "buffer-id", value = buffer_id and tostring(math.floor(tonumber(buffer_id))) or nil },
		},
		input_guard.is_invalid_payload_value
	)
end

local resolve_client = backend_client.new({
	executable = backend_client.ZIG_EXECUTABLE,
	worker_argv = { backend_client.ZIG_EXECUTABLE, "--daemon" },
	protocol = RUN_RESOLVE_PROTOCOL,
	worker_wait_ms = RUN_RESOLVE_SYNC_WAIT_MS,
	request_timeout_ms = RUN_RESOLVE_ASYNC_TIMEOUT_MS,
	reset_on_sync_timeout = false,
	build_worker_payload = build_worker_payload,
	build_once_argv = build_once_argv,
})

---@param resolved table|nil
---@param requested_filetype string
---@return table|nil
local function normalize_resolved_output(resolved, requested_filetype)
	if type(resolved) ~= "table" then
		return nil
	end
	if resolved.ok == nil then
		resolved.ok = type(resolved.command) == "string" and resolved.command ~= ""
	end
	if type(resolved.filetype) ~= "string" or resolved.filetype == "" then
		resolved.filetype = requested_filetype
	end
	if type(resolved.execution_path) ~= "string" or resolved.execution_path == "" then
		resolved.execution_path = nil
	end
	if type(resolved.argv) ~= "table" or #resolved.argv == 0 then
		resolved.argv = nil
	end
	if type(resolved.system_argv) ~= "table" or #resolved.system_argv == 0 then
		resolved.system_argv = nil
	end
	return resolved
end

---@param params table
---@return table|nil
function M.resolve_sync_request(params)
	local filepath = type(params) == "table" and params.path or nil
	local filetype = type(params) == "table" and params.filetype or nil
	local selection_text = type(params) == "table" and params.selection_text or nil
	local has_inline_source = type(selection_text) == "string" and selection_text ~= ""
	if filetype == nil or filetype == "" then
		return failed_resolution(filetype or "", "Cannot resolve runner: unknown filetype. Save the buffer to a file first.", "unknown_filetype")
	end
	if not can_use_backend_run_resolve(filepath, has_inline_source) then
		return failed_resolution(
			filetype,
			string.format("Failed to resolve runner for filetype: %s", tostring(filetype or "")),
			"config_sync_failed"
		)
	end
	local request = {
		path = filepath,
		filetype = filetype,
		context_path = type(params) == "table" and params.context_path or nil,
		buffer_id = type(params) == "table" and params.buffer_id or nil,
		selection_text = selection_text,
	}

	local lines = resolve_client.sync_request(request)
	if type(lines) ~= "table" and not has_inline_source then
		lines = resolve_client.once_request(request)
	end
	if type(lines) ~= "table" then
		local fail_msg = has_inline_source
			and "Failed to resolve runner for inline source. Backend unavailable and fallback path does not support inline source."
			or string.format("Failed to resolve runner for filetype: %s. Backend unavailable or timed out.", tostring(filetype or ""))
		return failed_resolution(filetype, fail_msg, "backend_unavailable")
	end
	local resolved = normalize_resolved_output(json_result.decode(lines), filetype)
	if type(resolved) == "table" then
		return resolved
	end
	return failed_resolution(filetype, string.format("Failed to resolve runner for filetype: %s", tostring(filetype or "")))
end

---@param filepath string
---@param filetype string
---@param context_path string|nil
---@return table|nil
function M.resolve_sync(filepath, filetype, context_path)
	return M.resolve_sync_request({
		path = filepath,
		filetype = filetype,
		context_path = context_path,
	})
end

return M
