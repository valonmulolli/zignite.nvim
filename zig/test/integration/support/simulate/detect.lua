local data = require("integration.support.simulate.data")

---@type table
local M = {
	detect_backend_tool_commands = data.detect_backend_tool_commands,
}

---@param text string
---@return string[]
local function split_lines(text)
	---@type string[]
	local lines = {}
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		if line ~= "" then
			table.insert(lines, line)
		end
	end
	return lines
end

---@param request_text string
---@return string[]|nil
function M.parse_detect_daemon_request(request_text)
	local req_lines = split_lines(request_text or "")
	if #req_lines < 2 then
		return nil
	end

	local begin_line = req_lines[1]
	local request_id, tool = begin_line:match("^@@ZDET_REQ_BEGIN%s+(%d+)%s+([%w_%-]+)$")
	if not request_id or not tool then
		return nil
	end

	local end_line = req_lines[#req_lines]
	local end_id = end_line:match("^@@ZDET_REQ_END%s+(%d+)$")
	if not end_id or tonumber(end_id) ~= tonumber(request_id) then
		return nil
	end

	local response = { "@@ZDET_RES_BEGIN " .. request_id }
	local commands = M.detect_backend_tool_commands[tool] or {}
	for _, command in ipairs(commands) do
		response[#response + 1] = "\t" .. command
	end
	response[#response + 1] = "@@ZDET_RES_END " .. request_id
	return response
end

---@param cmd string[]|string
---@return string[]|nil
function M.simulated_tool_help_output(cmd)
	if type(cmd) ~= "table" or type(cmd[1]) ~= "string" then
		return nil
	end

	if cmd[2] == "--detect" and type(cmd[3]) == "string" then
		local tool = cmd[3]:match("^%-%-tool=(.+)$")
		if tool then
			return M.detect_backend_tool_commands[tool] or {}
		end
	end

	if cmd[1] == "zig" and cmd[2] == "--help" then
		return {
			"Usage: zig [command] [options]",
			"",
			"Commands:",
			"",
			"  build            Build project from build.zig",
			"  fetch            Copy a package into global cache and print its hash",
			"  fmt              Reformat Zig source into canonical form",
			"  run              Create executable and run immediately",
			"",
			"General Options:",
			"  -h, --help       Print command-specific usage",
		}
	end

	if cmd[1] == "go" and cmd[2] == "help" then
		return {
			"The commands are:",
			"",
			"    build       compile packages and dependencies",
			"    env         print Go environment information",
			"    fmt         gofmt package sources",
			"",
			"Additional help topics:",
		}
	end

	if cmd[1] == "cargo" and cmd[2] == "--list" then
		return {
			"Installed Commands:",
			"    build      Compile a local package and all of its dependencies",
			"    check      Analyze the current package and report errors",
			"    run        Run a binary or example of the local package",
		}
	end

	if cmd[1] == "odin" and cmd[2] == "help" then
		return {
			"Commands:",
			"  build      Build an Odin package",
			"  run        Build and run an Odin package",
			"  test       Build and run tests for an Odin package",
			"Flags:",
		}
	end

	return nil
end

return M
