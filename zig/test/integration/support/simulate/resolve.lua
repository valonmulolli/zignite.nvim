local build = require("integration.support.simulate.build")
local detect = require("integration.support.simulate.detect")
local project = require("integration.support.simulate.project")
local quickfix = require("integration.support.simulate.quickfix")
local run = require("integration.support.simulate.run")
local util = require("integration.support.simulate.util")

---@type table
local M = {
	parse_project_daemon_request = project.parse_project_daemon_request,
}

---@param request_text string
---@return string[]|nil
function M.parse_unified_daemon_request(request_text)
	local begin_line = util.split_lines(request_text or "")[1] or ""
	if begin_line:match("^@@ZCFG_REQ_BEGIN%s+") then
		return build.parse_config_daemon_request(request_text)
	end
	if begin_line:match("^@@ZBR_REQ_BEGIN%s+") then
		return build.parse_build_resolve_daemon_request(request_text)
	end
	if begin_line:match("^@@ZBA_REQ_BEGIN%s+") then
		return build.parse_build_action_daemon_request(request_text)
	end
	if begin_line:match("^@@ZRUN_REQ_BEGIN%s+") then
		return run.parse_run_resolve_daemon_request(request_text)
	end
	if begin_line:match("^@@ZQF_BEGIN%s+") then
		return quickfix.parse_daemon_request(request_text)
	end
	if begin_line:match("^@@ZDET_REQ_BEGIN%s+") then
		return detect.parse_detect_daemon_request(request_text)
	end
	if begin_line:match("^@@ZPRJ_REQ_BEGIN%s+") then
		return project.parse_project_daemon_request(request_text)
	end
	return nil
end

return M
