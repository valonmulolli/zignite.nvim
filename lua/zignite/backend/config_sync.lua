local backend_client = require("zignite.backend.client")
local state = require("zignite.runtime.state")

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

---@param value string
---@return boolean
local function contains_control_characters(value)
	return type(value) ~= "string" or value:find("[%c]") ~= nil
end

---@param request_id integer
---@param params table
---@return string|nil
local function build_config_payload(request_id, params)
	local revision = type(params) == "table" and tonumber(params.revision) or nil
	local json_payload = type(params) == "table" and params.json or nil
	if not revision or revision <= 0 or contains_control_characters(json_payload or "") then
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
	executable = state.ZIG_EXECUTABLE,
	worker_argv = { state.ZIG_EXECUTABLE, "--daemon" },
	protocol = CONFIG_PROTOCOL,
	worker_wait_ms = 1200,
	request_timeout_ms = 3000,
	build_worker_payload = build_config_payload,
	build_once_argv = function(_)
		return nil
	end,
})

---@param options table
---@param revision integer
---@return string|nil
local function encode_synced_config(options, revision)
	if type(vim.json) ~= "table" or type(vim.json.encode) ~= "function" then
		return nil
	end

	return vim.json.encode({
		build_commands = type(options) == "table" and options.build_commands or {},
		detect = type(options) == "table" and options.detect or {},
		revision = revision,
	})
end

---@param options table
---@param revision integer
---@return boolean
function M.sync_async(options, revision)
	local json_payload = encode_synced_config(options, revision)
	if type(json_payload) ~= "string" or json_payload == "" then
		return false
	end

	return config_client.async_request({
		revision = revision,
		json = json_payload,
	}, function(_) end)
end

return M
