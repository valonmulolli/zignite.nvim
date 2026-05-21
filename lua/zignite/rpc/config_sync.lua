local backend_client = require("zignite.rpc.transport")
local config = require("zignite.config")
local input_guard = require("zignite.rpc.input_guard")

---@type table
local M = {}

local CONFIG_REQ_BEGIN = "@@ZCFG_REQ_BEGIN"
local CONFIG_REQ_END = "@@ZCFG_REQ_END"
local CONFIG_RES_BEGIN = "@@ZCFG_RES_BEGIN"
local CONFIG_RES_END = "@@ZCFG_RES_END"
local CONFIG_RES_ERR = "@@ZCFG_RES_ERR"
local CHUNK_SIZE = 4000

local CONFIG_PROTOCOL = {
	res_begin = CONFIG_RES_BEGIN,
	res_end = CONFIG_RES_END,
	res_err = CONFIG_RES_ERR,
}
local CONFIG_SYNC_WAIT_MS = 1000
local CONFIG_SYNC_ONCE_MAX_BYTES = 1024 * 1024
local last_synced_state = {
	revision = 0,
	worker_generation = 0,
	warning_signature = nil,
}

---@param request_id integer
---@param params table
---@return string|nil
local function build_config_payload(request_id, params)
	local revision = type(params) == "table" and tonumber(params.revision) or nil
	local json_payload = type(params) == "table" and params.json or nil
	if not revision or revision <= 0 or input_guard.contains_control_characters(json_payload or "", true) then
		return nil
	end

	local lines = { string.format("%s %d %d", CONFIG_REQ_BEGIN, request_id, revision) }
	local cursor = 1
	while cursor <= #json_payload do
		lines[#lines + 1] = "\t" .. json_payload:sub(cursor, cursor + CHUNK_SIZE - 1)
		cursor = cursor + CHUNK_SIZE
	end
	lines[#lines + 1] = string.format("%s %d", CONFIG_REQ_END, request_id)
	return table.concat(lines, "\n") .. "\n"
end

local config_client = backend_client.new({
	executable = backend_client.ZIG_EXECUTABLE,
	worker_argv = { backend_client.ZIG_EXECUTABLE, "--daemon" },
	protocol = CONFIG_PROTOCOL,
	worker_wait_ms = CONFIG_SYNC_WAIT_MS,
	request_timeout_ms = CONFIG_SYNC_WAIT_MS,
	build_worker_payload = build_config_payload,
	build_once_argv = function(_)
		return nil
	end,
})

---@param revision integer|nil
---@return nil
local function remember_synced_state(revision)
	last_synced_state.revision = tonumber(revision) or 0
	last_synced_state.worker_generation = config_client.get_worker_generation()
end

---@param revision integer
---@return boolean
local function has_current_sync(revision)
	return tonumber(last_synced_state.revision) == tonumber(revision)
		and config_client.has_live_worker()
		and config_client.get_worker_generation() == tonumber(last_synced_state.worker_generation)
end

---@param options table
---@param revision integer
---@return string|nil
local function encode_synced_config(options, revision)
	if type(vim.json) ~= "table" or type(vim.json.encode) ~= "function" then
		return string.format('{"revision":%d}', revision)
	end

	return vim.json.encode({
		build_commands = type(options) == "table" and options.build_commands or {},
		detect = type(options) == "table" and options.detect or {},
		runners = type(options) == "table" and options.runners or {},
		project = type(options) == "table" and options.project or {},
		timeout = type(options) == "table" and options.timeout or nil,
		revision = revision,
	})
end

---@param lines string[]|nil
---@return integer|nil
local function decode_synced_revision(lines)
	for _, raw_line in ipairs(lines or {}) do
		local kind, value = tostring(raw_line or ""):match("^([^\t]+)\t(.+)$")
		if kind == "REVISION" then
			return tonumber(value)
		end
	end
	return nil
end

---@param lines string[]|nil
---@return string[]
local function decode_warning_messages(lines)
	local warnings = {}
	for _, raw_line in ipairs(lines or {}) do
		local kind, value = tostring(raw_line or ""):match("^([^\t]+)\t(.+)$")
		if kind == "WARN" and value and value ~= "" then
			warnings[#warnings + 1] = value
		end
	end
	return warnings
end

---@param lines string[]|nil
---@param revision integer
---@return nil
local function notify_backend_warnings(lines, revision)
	local warnings = decode_warning_messages(lines)
	if #warnings == 0 or type(vim.notify) ~= "function" then
		return
	end
	local signature = tostring(revision) .. "\n" .. table.concat(warnings, "\n")
	if last_synced_state.warning_signature == signature then
		return
	end
	last_synced_state.warning_signature = signature
	for _, warning in ipairs(warnings) do
		vim.notify(tostring(warning), vim.log.levels.WARN)
	end
end

---@param options table
---@param revision integer
---@return table|nil
local function build_sync_request(options, revision)
	local json_payload = encode_synced_config(options, revision)
	if type(json_payload) ~= "string" or json_payload == "" then
		return nil
	end
	return {
		revision = revision,
		json = json_payload,
	}
end

---@param lines string[]|nil
---@param revision integer
---@return boolean
local function accept_synced_revision(lines, revision)
	local synced_revision = decode_synced_revision(lines) or revision
	remember_synced_state(synced_revision)
	notify_backend_warnings(lines, synced_revision)
	return tonumber(synced_revision) == tonumber(revision)
end

---@param options table
---@param revision integer
---@return boolean
local function sync_async(options, revision)
	local request = build_sync_request(options, revision)
	if type(request) ~= "table" then
		return false
	end

	return config_client.async_request(request, function(lines)
		local synced_revision = decode_synced_revision(lines)
		if tonumber(synced_revision) then
			remember_synced_state(synced_revision)
			notify_backend_warnings(lines, synced_revision)
		end
	end)
end

---@param options table
---@param revision integer
---@return boolean
local function sync_sync(options, revision)
	local request = build_sync_request(options, revision)
	if type(request) ~= "table" then
		return false
	end

	local lines = config_client.sync_request(request)
	if type(lines) ~= "table" then
		return false
	end
	return accept_synced_revision(lines, revision)
end

---@param options table
---@param revision integer
---@return boolean
local function sync_once(options, revision)
	local request = build_sync_request(options, revision)
	if type(request) ~= "table" or type(vim.fn.systemlist) ~= "function" then
		return false
	end
	local total_bytes = #request.json
	if total_bytes <= 0 or total_bytes > CONFIG_SYNC_ONCE_MAX_BYTES then
		return false
	end

	local argv = {
		backend_client.ZIG_EXECUTABLE,
		"--config-sync",
		"--revision=" .. tostring(revision),
	}
	local lines = vim.fn.systemlist(argv, request.json)
	local shell_error = (vim.v and tonumber(vim.v.shell_error)) or 0
	if type(lines) ~= "table" or shell_error ~= 0 then
		return false
	end
	local synced_revision = decode_synced_revision(lines)
	if tonumber(synced_revision) == nil then
		return false
	end
	remember_synced_state(synced_revision)
	notify_backend_warnings(lines, synced_revision)
	return tonumber(synced_revision) == tonumber(revision)
end

---@param options table
---@param revision integer
---@return boolean
local function ensure_synced(options, revision)
	local target_revision = tonumber(revision) or 0
	if target_revision <= 0 then
		return false
	end
	if has_current_sync(target_revision) then
		return true
	end
	if sync_sync(options, target_revision) then
		return true
	end
	if type(config_client.reset) == "function" then
		pcall(config_client.reset)
	end
	if sync_sync(options, target_revision) then
		return true
	end
	if sync_once(options, target_revision) then
		return true
	end
	return false
end

---@param options table
---@param revision integer
---@return boolean
function M.ensure_synced(options, revision)
	return ensure_synced(options, revision)
end

---@return boolean
function M.ensure_current()
	return M.ensure_synced(config.options or {}, config.revision)
end

---@return boolean
function M.sync_current_async()
	return sync_async(config.options or {}, config.revision)
end

return M
