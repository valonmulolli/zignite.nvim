-- Integration tests for zignite

local project_root = arg[1] or "."
package.path = package.path .. ";" .. project_root .. "/lua/?.lua"
package.path = package.path .. ";" .. project_root .. "/lua/?/init.lua"
package.path = package.path .. ";" .. project_root .. "/test/?.lua"

local ctx = require("integration.support")
local exported_globals = {
	project_root = project_root,
	config = ctx.config,
	init = ctx.init,
	ui = ctx.ui,
	state = ctx.state,
	job_results = ctx.job_results,
	quickfix_results = ctx.quickfix_results,
	notify_results = ctx.notify_results,
	mock_jobs = ctx.mock_jobs,
	command_to_string = ctx.command_to_string,
	reset_job_results = ctx.reset_job_results,
	reset_quickfix_results = ctx.reset_quickfix_results,
	reset_notify_results = ctx.reset_notify_results,
	count_quickfix_backend_jobs = ctx.count_quickfix_backend_jobs,
	count_quickfix_daemon_jobs = ctx.count_quickfix_daemon_jobs,
	count_detect_backend_jobs = ctx.count_detect_backend_jobs,
	count_detect_backend_requests = ctx.count_detect_backend_requests,
	get_upvalue_by_name = ctx.get_upvalue_by_name,
	detect_backend_tool_commands = ctx.detect_backend_tool_commands,
	is_detect_daemon_cmd = ctx.is_detect_daemon_cmd,
	parse_detect_daemon_request = ctx.parse_detect_daemon_request,
}
local suites = {
	"integration.core",
	"integration.quickfix",
	"integration.build_select",
	"integration.build_execute",
	"integration.build_resolve",
	"integration.detect",
	"integration.runtime",
}

for key, value in pairs(exported_globals) do
	_G[key] = value
end

local ok, err = xpcall(function()
	for _, suite in ipairs(suites) do
		require(suite)
	end
end, debug.traceback)

ctx.restore()
for key in pairs(exported_globals) do
	_G[key] = nil
end

if not ok then
	error(err)
end

print("All integration tests passed!")
