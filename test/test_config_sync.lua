-- Regression probe for UTF-8-safe config framing.

package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local original_transport = package.loaded["zignite.rpc.transport"]
local original_config_sync = package.loaded["zignite.rpc.config_sync"]

local options
package.loaded["zignite.rpc.transport"] = {
	BACKEND_EXECUTABLE = "zignite-test",
	new = function(value)
		options = value
		return {}
	end,
}
package.loaded["zignite.rpc.config_sync"] = nil

local ok, err = xpcall(function()
	require("zignite.rpc.config_sync")
	local json = '{"x":"' .. string.rep("a", 3993) .. "ë" .. '"}'
	local frame = options.build_worker_payload(1, { revision = 1, json = json })
	assert(type(frame) == "string", "config payload should be constructed")

	local chunks = {}
	for chunk in frame:gmatch("\t([^\n]*)\n") do
		assert(utf8.len(chunk) ~= nil, "each config frame chunk must be valid UTF-8")
		chunks[#chunks + 1] = chunk
	end
	assert(table.concat(chunks) == json, "chunking must preserve the JSON payload")
end, debug.traceback)

package.loaded["zignite.rpc.transport"] = original_transport
package.loaded["zignite.rpc.config_sync"] = original_config_sync

if not ok then
	error(err)
end

print("config sync UTF-8 framing tests passed")
