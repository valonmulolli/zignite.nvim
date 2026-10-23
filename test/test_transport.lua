-- Regression tests for the line-framed daemon transport.

local original_vim = _G.vim
local original_transport = package.loaded["zignite.rpc.transport"]

local function make_fake_vim(response_lines, send_result, jobstart_error)
	local jobs = {}
	local timers = {}
	local next_job_id = 1
	local stopped_jobs = 0

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
				if jobstart_error then
					error(jobstart_error)
				end
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
				stopped_jobs = stopped_jobs + 1
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
			new_timer = function()
				local timer = {}
				function timer:start(_, _, callback)
					self.callback = callback
				end
			function timer:stop()
				self.callback = nil
			end
			function timer:close()
				self.closed = true
			end
				timers[#timers + 1] = timer
				return timer
			end,
		},
		schedule_wrap = function(callback)
			return callback
		end,
		wait = function(_, condition)
			return condition()
		end,
		test = {
			job_count = function()
				return next_job_id - 1
			end,
			stopped_jobs = function()
				return stopped_jobs
			end,
			fire_timers = function()
				for _, timer in ipairs(timers) do
					local callback = timer.callback
					if callback then
						callback()
					end
				end
			end,
		},
	}
end

local function new_client(transport, overrides)
	local options = {
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
			build_once_argv = function()
				return { "zignite-test-worker" }
			end,
	}
	for key, value in pairs(overrides or {}) do
		options[key] = value
	end
	return transport.new(options)
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
	assert(malformed.has_live_worker() == false, "malformed frames must stop the worker")
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

	_G.vim = make_fake_vim({}, nil, "jobstart failed")
	package.loaded["zignite.rpc.transport"] = nil
	local jobstart_failure_transport = require("zignite.rpc.transport")
	local jobstart_failure = new_client(jobstart_failure_transport)
	assert(jobstart_failure.async_request({}, function()
		error("failed jobstart must not invoke the callback")
	end) == false, "worker jobstart exceptions should return false")
	assert(jobstart_failure.once_request_async({}, function()
		error("failed jobstart must not invoke the callback")
	end) == false, "one-shot jobstart exceptions should return false")
	jobstart_failure_transport.reset_all()

	local timeout_vim = make_fake_vim({})
	_G.vim = timeout_vim
	package.loaded["zignite.rpc.transport"] = nil
	local timeout_transport = require("zignite.rpc.transport")
	local timeout_client = new_client(timeout_transport, { request_timeout_ms = 10 })
	local timeout_callback_called = false
	assert(timeout_client.async_request({}, function(lines)
		timeout_callback_called = true
		assert(lines == nil, "timed-out request should fail")
	end), "timed request should be accepted")
	assert(timeout_vim.test.job_count() == 1, "first request should start one worker")
	timeout_vim.test.fire_timers()
	assert(timeout_callback_called, "timeout should complete its callback")
	assert(timeout_vim.test.stopped_jobs() == 1, "active timeout must stop its worker")
	assert(timeout_client.async_request({}, function() end), "next request should be accepted")
	assert(timeout_vim.test.job_count() == 2, "next request should use a fresh worker")
	timeout_transport.reset_all()
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
