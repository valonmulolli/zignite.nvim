-- Regression tests for the line-framed daemon transport.

local original_vim = _G.vim
local original_transport = package.loaded["zignite.rpc.transport"]

local function make_fake_vim(response_lines, send_result, jobstart_error, options)
	options = options or {}
	local jobs = {}
	local timers = {}
	local pending_responses = {}
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
			chansend = function(job_id, payload)
				if send_result ~= nil then
					return send_result
				end
				local opts = jobs[job_id]
				assert(opts and opts.on_stdout, "transport did not install stdout callback")
				local lines = type(response_lines) == "function" and response_lines(payload) or response_lines
				local data = {}
				for _, line in ipairs(lines) do
					data[#data + 1] = line
				end
				data[#data + 1] = ""
				if options.defer_response then
					pending_responses[#pending_responses + 1] = { job_id = job_id, data = data }
				else
					opts.on_stdout(job_id, data)
				end
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
			if options.wait_result == false then
				return false
			end
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
			deliver_response = function()
				local response = table.remove(pending_responses, 1)
				if not response then
					return false
				end
				jobs[response.job_id].on_stdout(response.job_id, response.data)
				return true
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

	local delayed_vim = make_fake_vim(function(payload)
		local request_id = assert(payload:match("@@ZTEST_REQ_BEGIN (%d+)"))
		return {
			"@@ZTEST_RES_BEGIN " .. request_id,
			"\tRESULT\t" .. request_id,
			"@@ZTEST_RES_END " .. request_id,
		}
	end, nil, nil, { defer_response = true, wait_result = false })
	_G.vim = delayed_vim
	package.loaded["zignite.rpc.transport"] = nil
	local delayed_transport = require("zignite.rpc.transport")
	local delayed_client = new_client(delayed_transport)
	assert(delayed_client.sync_request({}) == nil, "sync wait should report timeout")
	assert(delayed_vim.test.job_count() == 1, "sync wait timeout should keep the shared worker")
	assert(delayed_vim.test.stopped_jobs() == 0, "sync wait timeout must not stop the daemon immediately")
	local next_result
	assert(delayed_client.async_request({}, function(lines)
		next_result = lines
	end), "next request should queue behind the timed-out request")
	assert(delayed_vim.test.job_count() == 1, "queued request should reuse the same daemon")
	assert(delayed_vim.test.deliver_response(), "late response for timed-out request should arrive")
	assert(next_result == nil, "late response should not complete the next request")
	assert(delayed_vim.test.deliver_response(), "queued request response should arrive")
	assert(next_result and next_result[1] == "RESULT\t2", "queued request should receive its own response")
	assert(delayed_vim.test.stopped_jobs() == 0, "successful recovery should preserve the daemon")
	delayed_transport.reset_all()

	local hard_timeout_vim = make_fake_vim(function(payload)
		local request_id = assert(payload:match("@@ZTEST_REQ_BEGIN (%d+)"))
		return {
			"@@ZTEST_RES_BEGIN " .. request_id,
			"\tRESULT\t" .. request_id,
			"@@ZTEST_RES_END " .. request_id,
		}
	end, nil, nil, { defer_response = true, wait_result = false })
	_G.vim = hard_timeout_vim
	package.loaded["zignite.rpc.transport"] = nil
	local hard_timeout_transport = require("zignite.rpc.transport")
	local hard_timeout_client = new_client(hard_timeout_transport, {
		sync_request_max_lifetime_ms = 10,
	})
	assert(hard_timeout_client.sync_request({}) == nil, "sync request should return at its wait deadline")
	assert(hard_timeout_vim.test.stopped_jobs() == 0, "wait deadline should not immediately stop the worker")
	hard_timeout_vim.test.fire_timers()
	assert(hard_timeout_vim.test.stopped_jobs() == 1, "hard lifetime deadline should recover a stuck worker")
	hard_timeout_transport.reset_all()
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
