local data = require("integration.support.simulate.data")
local detect = require("integration.support.simulate.detect")
local quickfix = require("integration.support.simulate.quickfix")
local resolve = require("integration.support.simulate.resolve")

---@type table
local M = {
	detect_backend_tool_commands = data.detect_backend_tool_commands,
	project_backend_lines = data.project_backend_lines,
	simulate_quickfix_backend = quickfix.simulate_quickfix_backend,
	parse_daemon_request = quickfix.parse_daemon_request,
	is_quickfix_daemon_cmd = quickfix.is_quickfix_daemon_cmd,
	is_detect_daemon_cmd = quickfix.is_detect_daemon_cmd,
	is_project_daemon_cmd = quickfix.is_project_daemon_cmd,
	is_unified_daemon_cmd = quickfix.is_unified_daemon_cmd,
	is_quickfix_backend_cmd = quickfix.is_quickfix_backend_cmd,
	parse_detect_daemon_request = detect.parse_detect_daemon_request,
	parse_project_daemon_request = resolve.parse_project_daemon_request,
	parse_unified_daemon_request = resolve.parse_unified_daemon_request,
	simulated_tool_help_output = detect.simulated_tool_help_output,
}

return M
