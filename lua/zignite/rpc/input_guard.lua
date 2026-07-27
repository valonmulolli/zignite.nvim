---@type table
local M = {}

--- Known protocol delimiter prefixes from the Zig backend daemon.
--- Values containing these should not be embedded in payload lines
--- that lack a leading tab prefix (defense-in-depth against injection).
local PROTOCOL_DELIMITERS = {
	"@@ZQF_",
	"@@ZBR_",
	"@@ZDET_",
	"@@ZPRJ_",
	"@@ZCFG_",
	"@@ZBA_",
	"@@ZRUN_",
}

---@param value any
---@param allow_empty boolean|nil
---@return boolean
function M.contains_control_characters(value, allow_empty)
	if type(value) ~= "string" then
		return true
	end
	if not allow_empty and value == "" then
		return true
	end
	return value:find("[%c]") ~= nil
end

--- Check if a value contains known protocol delimiter prefixes.
--- Used as defense-in-depth: if user-provided data (filepaths, config values)
--- somehow reaches the daemon without a leading tab, delimiter prefixes
--- could be mistaken for frame markers.
---@param value string
---@return boolean
function M.contains_protocol_delimiters(value)
	if type(value) ~= "string" then
		return true
	end
	for _, delim in ipairs(PROTOCOL_DELIMITERS) do
		if value:find(delim, 1, true) then
			return true
		end
	end
	return false
end

--- Combined validator for payload values (filepaths, filetypes, flag values).
--- Returns true when the value is invalid for use in a daemon payload.
--- Checks: non-string, empty, control characters, and protocol delimiters.
--- This is the recommended function to pass as the `is_invalid` callback to
--- `common_path_request.compose_worker_payload` and `compose_once_argv`.
---@param value any
---@return boolean
function M.is_invalid_payload_value(value)
	if type(value) ~= "string" then
		return true
	end
	if value == "" then
		return true
	end
	if value:find("[%c]") ~= nil then
		return true
	end
	return M.contains_protocol_delimiters(value)
end

return M
