-- Tests for zignite.rpc.json_result module

package.path = package.path .. ";./lua/?.lua"
package.path = package.path .. ";./lua/?/init.lua"

-- Mock vim.json.decode with a simple lookup table
_G.vim = {
	json = {
		decode = function(text)
			if text == "invalid" then
				error("Invalid JSON")
			end
			if text == "{}" then return {} end
			if text == '{"key":"value"}' then return { key = "value" } end
			if text == '{"first":true}' then return { first = true } end
			if text == '{"second":true}' then return { second = true } end
			if text == '{"enabled":true,"count":42}' then return { enabled = true, count = 42 } end
			if text == '{"arr":[1,2,3]}' then return { arr = { 1, 2, 3 } } end
			if text == '{"enabled":true}' then return { enabled = true } end
			if text == '{"count":12}' then return { count = 12 } end
			error("Unknown JSON: " .. text)
		end,
	},
	fn = {},
}

local json_result = require('zignite.rpc.json_result')

local function test_decode_nil()
	local result = json_result.decode(nil)
	assert(result == nil, "nil input should return nil")
	print("✓ decode(nil) passed")
end

local function test_decode_empty_lines()
	local result = json_result.decode({})
	assert(result == nil, "Empty lines array should return nil")
	print("✓ decode({}) passed")
end

local function test_decode_no_match()
	local result = json_result.decode({ "garbage", "other lines", "" })
	assert(result == nil, "No RESULT_JSON line should return nil")
	print("✓ decode(no match) passed")
end

local function test_decode_simple()
	local lines = { 'RESULT_JSON\t{"key":"value"}' }
	local result = json_result.decode(lines)
	assert(type(result) == "table", "Should return a table")
	assert(result.key == "value", "Should decode key")
	print("✓ decode(simple) passed")
end

local function test_decode_empty_json()
	local lines = { "RESULT_JSON\t{}" }
	local result = json_result.decode(lines)
	assert(type(result) == "table", "Empty JSON should produce a table")
	assert(next(result) == nil, "Empty JSON should produce empty table")
	print("✓ decode(empty JSON) passed")
end

local function test_decode_empty_payload()
	local result = json_result.decode({ "RESULT_JSON\t" })
	assert(result == nil, "Empty payload after prefix should return nil")
	print("✓ decode(empty payload) passed")
end

local function test_decode_first_match()
	local lines = {
		"RESULT_JSON\t{\"first\":true}",
		"RESULT_JSON\t{\"second\":true}",
	}
	local result = json_result.decode(lines)
	assert(type(result) == "table", "Should return a table")
	assert(result.first == true, "Should decode the first match, not the second")
	assert(result.second == nil, "Should not include second match data")
	print("✓ decode(first match) passed")
end

local function test_decode_with_garbage()
	local lines = {
		"garbage before",
		"RESULT_JSON\t{\"key\":\"value\"}",
		"garbage after",
	}
	local result = json_result.decode(lines)
	assert(type(result) == "table", "Should return a table despite surrounding garbage")
	assert(result.key == "value", "Should decode correctly")
	print("✓ decode(with garbage) passed")
end

local function test_decode_invalid_json()
	local lines = { "RESULT_JSON\tinvalid" }
	local result = json_result.decode(lines)
	assert(result == nil, "Invalid JSON should return nil")
	print("✓ decode(invalid JSON) passed")
end

-- Run all tests
test_decode_nil()
test_decode_empty_lines()
test_decode_no_match()
test_decode_simple()
test_decode_empty_json()
test_decode_empty_payload()
test_decode_first_match()
test_decode_with_garbage()
test_decode_invalid_json()

print("All json_result tests passed!")
