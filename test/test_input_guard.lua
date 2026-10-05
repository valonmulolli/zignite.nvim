-- Tests for zignite.rpc.input_guard module

package.path = package.path .. ";./lua/?.lua"
package.path = package.path .. ";./lua/?/init.lua"

local input_guard = require('zignite.rpc.input_guard')

-- contains_control_characters
local function test_contains_control_characters()
	assert(input_guard.contains_control_characters("hello") == false,
		"Plain string should not contain control characters")
	assert(input_guard.contains_control_characters("hello world") == false,
		"Spaces are not control characters")
	assert(input_guard.contains_control_characters("") == true,
		"Empty string is invalid (no allow_empty)")
	assert(input_guard.contains_control_characters("", true) == false,
		"Empty string is allowed with allow_empty=true")
	assert(input_guard.contains_control_characters(42) == true,
		"Non-string should return true")
	assert(input_guard.contains_control_characters(nil) == true,
		"nil should return true")
	assert(input_guard.contains_control_characters("\n") == true,
		"Newline is a control character")
	assert(input_guard.contains_control_characters("\r") == true,
		"Carriage return is a control character")
	assert(input_guard.contains_control_characters("\t") == true,
		"Tab is a control character")
	assert(input_guard.contains_control_characters("\0") == true,
		"Null byte is a control character")
	assert(input_guard.contains_control_characters("hello\nworld") == true,
		"String with embedded newline contains control chars")
	assert(input_guard.contains_control_characters(true) == true,
		"Boolean should return true")
	assert(input_guard.contains_control_characters({}) == true,
		"Table should return true")
	print("✓ contains_control_characters tests passed")
end

-- contains_protocol_delimiters
local function test_contains_protocol_delimiters()
	assert(input_guard.contains_protocol_delimiters("hello") == false,
		"Plain string should not contain delimiters")
	assert(input_guard.contains_protocol_delimiters("/home/user/file.zig") == false,
		"File path should not contain delimiters")
	assert(input_guard.contains_protocol_delimiters("@@ZQF_foo") == true,
		"@@ZQF_ should be detected")
	assert(input_guard.contains_protocol_delimiters("@@ZBR_something") == true,
		"@@ZBR_ should be detected")
	assert(input_guard.contains_protocol_delimiters("@@ZDET_value") == true,
		"@@ZDET_ should be detected")
	assert(input_guard.contains_protocol_delimiters("@@ZPRJ_value") == true,
		"@@ZPRJ_ should be detected")
	assert(input_guard.contains_protocol_delimiters("@@ZCFG_value") == true,
		"@@ZCFG_ should be detected")
	assert(input_guard.contains_protocol_delimiters("@@ZBA_value") == true,
		"@@ZBA_ should be detected")
	assert(input_guard.contains_protocol_delimiters("@@ZRUN_value") == true,
		"@@ZRUN_ should be detected")
	assert(input_guard.contains_protocol_delimiters(42) == true,
		"Non-string should return true")
	assert(input_guard.contains_protocol_delimiters(nil) == true,
		"nil should return true")
	print("✓ contains_protocol_delimiters tests passed")
end

-- is_invalid_payload_value
local function test_is_invalid_payload_value()
	assert(input_guard.is_invalid_payload_value("/home/user/file.zig") == false,
		"Valid filepath should be accepted")
	assert(input_guard.is_invalid_payload_value("zig") == false,
		"Valid filetype should be accepted")
	assert(input_guard.is_invalid_payload_value("") == true,
		"Empty string should be rejected")
	assert(input_guard.is_invalid_payload_value(nil) == true,
		"nil should be rejected")
	assert(input_guard.is_invalid_payload_value(42) == true,
		"Number should be rejected")
	assert(input_guard.is_invalid_payload_value("hello\nworld") == true,
		"String with control char should be rejected")
	assert(input_guard.is_invalid_payload_value("@@ZQF_test") == true,
		"String with protocol delimiter should be rejected")
	assert(input_guard.is_invalid_payload_value("@@ZBR_test") == true,
		"String with build resolve delimiter should be rejected")
	assert(input_guard.is_invalid_payload_value("/path/with spaces") == false,
		"Spaces are valid (no control chars)")
	assert(input_guard.is_invalid_payload_value("/path/with-hyphen_and_underscore") == false,
		"Path with special chars (but not control chars) is valid")
	print("✓ is_invalid_payload_value tests passed")
end

-- Run all tests
test_contains_control_characters()
test_contains_protocol_delimiters()
test_is_invalid_payload_value()

print("All input_guard tests passed!")
