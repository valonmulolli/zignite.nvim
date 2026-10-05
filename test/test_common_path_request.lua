-- Tests for zignite.rpc.common_path_request module

package.path = package.path .. ";./lua/?.lua"
package.path = package.path .. ";./lua/?/init.lua"

local cpr = require('zignite.rpc.common_path_request')

-- begin_worker_lines
local function test_begin_worker_lines()
	local lines = cpr.begin_worker_lines("@@ZBR_REQ_BEGIN", 1, "--build-resolve", "/home/user/main.zig", "zig")
	assert(type(lines) == "table", "Should return a table")
	assert(#lines == 4, "Should have 4 lines")
	assert(lines[1] == "@@ZBR_REQ_BEGIN 1", "First line should be begin marker with request_id")
	assert(lines[2] == "\t--build-resolve", "Second line should be mode flag with tab")
	assert(lines[3] == "\t--path=/home/user/main.zig", "Third line should be path flag")
	assert(lines[4] == "\t--filetype=zig", "Fourth line should be filetype flag")
	print("✓ begin_worker_lines tests passed")
end

-- append_optional_worker_flag
local function test_append_optional_worker_flag()
	local lines = { "existing" }
	cpr.append_optional_worker_flag(lines, "timeout", "5000")
	assert(#lines == 2, "Should append one line")
	assert(lines[2] == "\t--timeout=5000", "Should format as --timeout=5000")

	cpr.append_optional_worker_flag(lines, "cleanup", "rm -rf")
	assert(#lines == 3, "Should append another line")
	assert(lines[3] == "\t--cleanup=rm -rf", "Should format as --cleanup=rm -rf")
	print("✓ append_optional_worker_flag tests passed")
end

-- finish_worker_payload
local function test_finish_worker_payload()
	local lines = { "line1", "line2" }
	local result = cpr.finish_worker_payload(lines, "@@ZBR_REQ_END", 42)
	assert(result == "line1\nline2\n@@ZBR_REQ_END 42\n", "Should join with newlines and add trailing newline")
	assert(#lines == 3, "Should append end marker to lines")
	print("✓ finish_worker_payload tests passed")
end

-- begin_once_argv
local function test_begin_once_argv()
	local argv = cpr.begin_once_argv("/usr/bin/zignite", "--build-resolve", "/home/user/main.zig", "zig")
	assert(type(argv) == "table", "Should return a table")
	assert(#argv == 4, "Should have 4 elements")
	assert(argv[1] == "/usr/bin/zignite", "First should be executable")
	assert(argv[2] == "--build-resolve", "Second should be mode flag")
	assert(argv[3] == "--path=/home/user/main.zig", "Third should be path flag")
	assert(argv[4] == "--filetype=zig", "Fourth should be filetype flag")
	print("✓ begin_once_argv tests passed")
end

-- append_optional_argv
local function test_append_optional_argv()
	local argv = { "exe", "--flag" }
	cpr.append_optional_argv(argv, "timeout", "5000")
	assert(#argv == 3, "Should append one element")
	assert(argv[3] == "--timeout=5000", "Should format as --timeout=5000")
	print("✓ append_optional_argv tests passed")
end

-- compose_worker_payload
local function test_compose_worker_payload()
	local function always_invalid(value)
		return value == "bad"
	end

	-- Valid payload
	local payload = cpr.compose_worker_payload(
		"@@ZBR_REQ_BEGIN", "@@ZBR_REQ_END", 1,
		"--build-resolve", "/home/user/main.zig", "zig",
		nil, always_invalid
	)
	assert(type(payload) == "string", "Valid payload should return string")
	assert(payload:find("@@ZBR_REQ_BEGIN 1") ~= nil, "Should contain begin marker")
	assert(payload:find("--path=/home/user/main%.zig") ~= nil, "Should contain path")
	assert(payload:find("--filetype=zig") ~= nil, "Should contain filetype")

	-- Invalid filepath
	assert(cpr.compose_worker_payload("B", "E", 1, "--mode", "bad", "zig", nil, always_invalid) == nil,
		"Invalid filepath should return nil")

	-- Invalid filetype
	assert(cpr.compose_worker_payload("B", "E", 1, "--mode", "/good/path", "bad", nil, always_invalid) == nil,
		"Invalid filetype should return nil")

	-- With optional flags
	local payload2 = cpr.compose_worker_payload(
		"@@ZBR_REQ_BEGIN", "@@ZBR_REQ_END", 2,
		"--build-resolve", "/path", "go",
		{ { name = "timeout", value = "5000" } },
		always_invalid
	)
	assert(type(payload2) == "string", "Payload with optional flags should return string")
	assert(payload2:find("--timeout=5000") ~= nil, "Should contain optional timeout flag")

	-- Optional flag with invalid value
	assert(cpr.compose_worker_payload("B", "E", 3, "--mode", "/path", "go",
		{ { name = "badflag", value = "bad" } }, always_invalid) == nil,
		"Optional flag with invalid value should return nil")

	print("✓ compose_worker_payload tests passed")
end

-- compose_once_argv
local function test_compose_once_argv()
	local function always_invalid(value)
		return value == "bad"
	end

	-- Valid argv
	local argv = cpr.compose_once_argv(
		"/usr/bin/zignite", "--build-resolve", "/home/user/main.zig", "zig",
		nil, always_invalid
	)
	assert(type(argv) == "table", "Valid argv should return table")
	assert(#argv == 4, "Should have 4 elements")

	-- Invalid filepath
	assert(cpr.compose_once_argv("/exe", "--mode", "bad", "zig", nil, always_invalid) == nil,
		"Invalid filepath should return nil")

	-- Invalid filetype
	assert(cpr.compose_once_argv("/exe", "--mode", "/path", "bad", nil, always_invalid) == nil,
		"Invalid filetype should return nil")

	-- With optional flags
	local argv2 = cpr.compose_once_argv(
		"/exe", "--mode", "/path", "go",
		{ { name = "timeout", value = "3000" } },
		always_invalid
	)
	assert(type(argv2) == "table", "Should return table")
	assert(argv2[5] == "--timeout=3000", "Should include optional flag")

	print("✓ compose_once_argv tests passed")
end

-- Run all tests
test_begin_worker_lines()
test_append_optional_worker_flag()
test_finish_worker_payload()
test_begin_once_argv()
test_append_optional_argv()
test_compose_worker_payload()
test_compose_once_argv()

print("All common_path_request tests passed!")
