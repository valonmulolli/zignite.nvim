local backend_client = require("zignite.backend.client")
local state = require("zignite.runtime.state")

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
	local project_root = type(params) == "table" and params.project_root or nil
	if contains_control_characters(filepath) or contains_control_characters(filetype) then
		return nil
	end

	local lines = {
		string.format("%s %d", BUILD_RESOLVE_REQ_BEGIN, request_id),
		"\t--build-resolve",
		"\t--path=" .. filepath,
		"\t--filetype=" .. filetype,
	}
	if type(project_root) == "string" and project_root ~= "" then
		if contains_control_characters(project_root) then
			return nil
		end
		lines[#lines + 1] = "\t--project-root=" .. project_root
	end
	lines[#lines + 1] = string.format("%s %d", BUILD_RESOLVE_REQ_END, request_id)
	return table.concat(lines, "\n") .. "\n"
end

---@param params table
---@return string[]|nil
local function build_once_argv(params)
	local filepath = type(params) == "table" and params.path or nil
	local filetype = type(params) == "table" and params.filetype or nil
	local project_root = type(params) == "table" and params.project_root or nil
	if contains_control_characters(filepath) or contains_control_characters(filetype) then
		return nil
	end

	local argv = {
		state.ZIG_EXECUTABLE,
		"--build-resolve",
		"--path=" .. filepath,
		"--filetype=" .. filetype,
	}
	if type(project_root) == "string" and project_root ~= "" then
		if contains_control_characters(project_root) then
			return nil
		end
		argv[#argv + 1] = "--project-root=" .. project_root
	end
	return argv
end

local resolve_client = backend_client.new({
	executable = state.ZIG_EXECUTABLE,
	worker_argv = { state.ZIG_EXECUTABLE, "--daemon" },
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
	}
	for _, raw_line in ipairs(lines or {}) do
		local line = tostring(raw_line or "")
		local kind, name, value = line:match("^([^\t]+)\t([^\t]+)\t(.+)$")
		if kind == "COMMAND" then
			result.commands[name] = value
		elseif kind == "PREFERRED" then
			result.preferred_commands[name] = value
		else
			kind, value = line:match("^([^\t]+)\t(.+)$")
			if kind == "ROOT" then
				result.root = value
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
---@param project_root string|nil
---@return table|nil
function M.resolve_sync(filepath, filetype, project_root)
	local lines = resolve_client.sync_request({
		path = filepath,
		filetype = filetype,
		project_root = project_root,
	})
	if type(lines) ~= "table" then
		return nil
	end
	return decode_resolved_lines(lines)
end

return M
