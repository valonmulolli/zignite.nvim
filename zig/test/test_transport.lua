-- Regression tests for the line-framed daemon transport.

local original_vim = _G.vim
local original_transport = package.loaded["zignite.rpc.transport"]

local function make_fake_vim(response_lines, send_result)
	local jobs = {}
	local next_job_id = 1

	local function joinpath(left, right)
		return tostring(left):gsub("[/\\]+$", "") .. "/" .. tostring(right):gsub("^[/\\]+", "")
	end

	return {
		fn = {
			has = function()
				return 0
			end,
			filereadable = function()
				return 0
			end,
			executable = function()
				return 1
			end,
			jobstart = function(_, opts)
				local job_id = next_job_id
				next_job_id = next_job_id + 1
				jobs[job_id] = opts
				return job_id
			end,
			chansend = function(job_id)
				if send_result ~= nil then
					return send_result
				end
				local opts = jobs[job_id]
				assert(opts and opts.on_stdout, "transport did not install stdout callback")
				local data = {}
				for _, line in ipairs(response_lines) do
					data[#data + 1] = line
				end
				data[#data + 1] = ""
				opts.on_stdout(job_id, data)
				return 1
			end,
			jobwait = function()
				return { -9 }
			end,
			jobstop = function()
				return 1
			end,
		},
		fs = {
			joinpath = joinpath,
			normalize = function(path)
				return path
			end,
			dirname = function(path)
				return path:match("^(.*)[/\\][^/\\]*$") or "."
			end,
		},
		uv = {
			cwd = function()
				return "."
			end,
		},
		wait = function(_, condition)
			return condition()
		end,
	}
end

local function new_client(transport)
	return transport.new({
		executable = "zignite-test",
		worker_argv = { "zignite-test-worker" },
		protocol = {
			res_begin = "@@ZTEST_RES_BEGIN",
			res_end = "@@ZTEST_RES_END",
			res_err = "@@ZTEST_RES_ERR",
		},
		worker_wait_ms = 100,
		build_worker_payload = function(request_id)
			return string.format("@@ZTEST_REQ_BEGIN %d\n@@ZTEST_REQ_END %d\n", request_id, request_id)
		end,
	})
end

local function run_tests()
	local transport = require("zignite.rpc.transport")

	local valid = new_client(transport)
	local valid_lines = valid.sync_request({})
	assert(type(valid_lines) == "table", "valid response should complete")
	assert(valid_lines[1] == "RESULT\tok", "tab-prefixed payload should be unwrapped")
	assert(valid_lines[2] == "@@ZTEST_RES_END 1", "marker-like payload must remain data")
	assert(valid.has_live_worker() == false, "signaled worker must not be reported as live")
	transport.reset_all()

	_G.vim = make_fake_vim({
		"@@ZTEST_RES_BEGIN 1",
		"unprefixed payload",
		"@@ZTEST_RES_END 1",
	})
	package.loaded["zignite.rpc.transport"] = nil
	local malformed_transport = require("zignite.rpc.transport")
	local malformed = new_client(malformed_transport)
	assert(malformed.sync_request({}) == nil, "unprefixed payload must fail the request")
	malformed_transport.reset_all()

	_G.vim = make_fake_vim({}, 0)
	package.loaded["zignite.rpc.transport"] = nil
	local send_failure_transport = require("zignite.rpc.transport")
	local send_failure = new_client(send_failure_transport)
	local callback_called = false
	assert(send_failure.async_request({}, function(lines)
		callback_called = true
		assert(lines == nil, "failed send should complete with an error")
	end), "request should be accepted before send is attempted")
	assert(callback_called, "failed send should not wait for the request timeout")
	send_failure_transport.reset_all()
end

local ok, err = xpcall(function()
	_G.vim = make_fake_vim({
		"@@ZTEST_RES_BEGIN 1",
		"\tRESULT\tok",
		"\t@@ZTEST_RES_END 1",
		"@@ZTEST_RES_END 1",
	})
	package.loaded["zignite.rpc.transport"] = nil
	run_tests()
end, debug.traceback)

package.loaded["zignite.rpc.transport"] = original_transport
_G.vim = original_vim

if not ok then
	error(err)
end

print("transport protocol tests passed")
