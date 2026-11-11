-- Tests for zignite.ui.registry module

package.path = package.path .. ";./lua/?.lua"
package.path = package.path .. ";./lua/?/init.lua"

-- Track calls to neovim APIs
local win_close_calls = {}
local buf_delete_calls = {}
local jobstop_calls = {}

-- Mock vim API
_G.vim = {
	api = {
		nvim_win_is_valid = function(win_id)
			return win_id > 0
		end,
		nvim_win_close = function(win_id, force)
			table.insert(win_close_calls, { win_id = win_id, force = force })
		end,
		nvim_buf_is_valid = function(buf_id)
			return buf_id > 0
		end,
		nvim_buf_delete = function(buf_id, opts)
			table.insert(buf_delete_calls, { buf_id = buf_id, force = opts and opts.force })
		end,
	},
	fn = {
		jobstop = function(job_id)
			table.insert(jobstop_calls, { job_id = job_id })
		end,
	},
}

local registry = require('zignite.ui.registry')

local function reset_state()
	registry.close_all(true)
	win_close_calls = {}
	buf_delete_calls = {}
	jobstop_calls = {}
end

local function test_track_single()
	reset_state()
	local r = registry.track(100, 200)
	assert(type(r) == "table", "Should return a runner table")
	assert(r.win_id == 100, "Should store win_id")
	assert(r.buf_id == 200, "Should store buf_id")
	assert(r.job_id == nil, "job_id should default to nil")
	print("✓ track(single) passed")
end

local function test_track_max_runners()
	reset_state()
	-- Track MAX_RUNNERS (50) runners that won't trigger eviction
	local oldest
	for i = 1, 50 do
		local runner = registry.track(100 + i, 200 + i)
		runner.job_id = 700 + i
		if i == 1 then
			oldest = runner
		end
	end
	assert(oldest ~= nil, "Should still return the oldest tracked runner")

	-- Tracking 51st must not silently stop an active runner.
	local new = registry.track(999, 888)
	assert(new.win_id == 999, "Should return the new runner")
	assert(new.buf_id == 888, "Should return the new runner buf_id")
	assert(type(new.job_id) == "nil", "job_id should be nil")

	assert(#win_close_calls == 0, "Active runner windows must remain open")
	assert(#buf_delete_calls == 0, "Active runner buffers must remain intact")
	assert(#jobstop_calls == 0, "Tracking another runner must not stop active jobs")
	assert(oldest.job_id == 701, "The oldest active job must remain tracked")

	print("✓ track(max runners eviction) passed")
end

local function test_track_evicts_completed_runner_before_active_runners()
	reset_state()
	local completed
	for i = 1, 50 do
		local runner = registry.track(200 + i, 300 + i)
		if i == 1 then
			completed = runner
		else
			runner.job_id = 1000 + i
		end
	end
	registry.track(999, 888)

	assert(#win_close_calls == 1, "one completed runner should be evicted at capacity")
	assert(win_close_calls[1].win_id == 201, "the oldest completed runner should be evicted")
	assert(#jobstop_calls == 0, "evicting a completed runner must not stop active jobs")
	assert(completed.job_id == nil, "the completed runner remains inactive")
	registry.close_all(true)
	print("✓ track evicts completed runner before active runners")
end

local function test_track_job_id()
	reset_state()
	local r = registry.track(10, 20)
	r.job_id = 42
	assert(r.job_id == 42, "Should allow setting job_id after tracking")
	print("✓ track(job id) passed")
end

local function test_close_by_win_id()
	reset_state()
	registry.track(1, 2)
	local r2 = registry.track(3, 4)

	-- Close runner with win_id=1
	local result = registry.close_by_win_id(1, false)
	assert(result == true, "Should return true for existing runner")
	assert(#win_close_calls == 1, "Should have called win_close once")
	assert(win_close_calls[1].win_id == 1, "Should close win_id 1")
	-- jobstop should not be called with stop_job=false
	assert(#jobstop_calls == 0, "Should not call jobstop with stop_job=false")

	-- Try closing non-existent win_id
	local non_existent = registry.close_by_win_id(999, false)
	assert(non_existent == false, "Should return false for non-existent win_id")

	print("✓ close_by_win_id passed")
end

local function test_close_by_win_id_with_job_stop()
	reset_state()
	local r = registry.track(10, 20)
	r.job_id = 42

	local closed = registry.close_by_win_id(10, true)
	assert(closed == true, "Should close the runner")
	assert(#jobstop_calls == 1, "Should call jobstop when stop_job=true")
	assert(jobstop_calls[1].job_id == 42, "Should stop the correct job")

	print("✓ close_by_win_id(with job stop) passed")
end

local function test_clean_invalid()
	reset_state()
	registry.track(1, 2)
	local invalid = registry.track(3, 4)
	invalid.job_id = 88

	-- Override nvim_win_is_valid to make first runner valid, second invalid
	_G.vim.api.nvim_win_is_valid = function(win_id)
		return win_id == 1 -- only win_id=1 is valid
	end
	_G.vim.api.nvim_buf_is_valid = function(buf_id)
		return true
	end

	registry.clean_invalid()

	-- Restore mock
	_G.vim.api.nvim_win_is_valid = function(win_id) return win_id > 0 end

	-- The second runner should have its buf deleted because its win was invalid
	assert(#buf_delete_calls == 1, "Should have deleted buf of invalid runner")
	assert(buf_delete_calls[1].buf_id == 4, "Should delete buf_id 4 of invalid runner's buf")
	assert(#jobstop_calls == 1, "Should stop the invalid runner job")
	assert(jobstop_calls[1].job_id == 88, "Should stop the invalid runner's job")

	print("✓ clean_invalid passed")
end

local function test_close_all()
	reset_state()
	registry.track(10, 20)
	registry.track(30, 40)
	registry.track(50, 60)

	registry.close_all(false)

	-- Should have 3 close calls for all 3 runners
	assert(#win_close_calls == 3, "Should close all 3 runner windows")
	assert(#buf_delete_calls == 3, "Should delete all 3 runner buffers")

	-- jobstop should not be called with stop_jobs=false
	assert(#jobstop_calls == 0, "Should not call jobstop with stop_jobs=false")

	print("✓ close_all passed")
end

local function test_close_all_with_job_stop()
	reset_state()
	local r1 = registry.track(10, 20)
	r1.job_id = 42
	local r2 = registry.track(30, 40)
	r2.job_id = 99

	registry.close_all(true)

	-- Should have 2 jobstop calls (last closed first due to reverse iteration)
	assert(#jobstop_calls == 2, "Should stop both runner jobs")
	assert(jobstop_calls[1].job_id == 99, "Should stop second job first (reverse iteration)")
	assert(jobstop_calls[2].job_id == 42, "Should stop first job second")

	-- Should also have 2 window closes and 2 buffer deletes
	assert(#win_close_calls == 2, "Should close both windows")

	print("✓ close_all(with job stop) passed")
end

local function test_close_all_hide_keeps_active_job_discoverable()
	reset_state()
	local runner = registry.track(10, 20)
	runner.job_id = 42

	registry.close_all(false)
	assert(#jobstop_calls == 0, "Hide mode should not stop the active job")

	registry.close_all(true)
	assert(#jobstop_calls == 1, "StopCode should still find a hidden active job")
	assert(jobstop_calls[1].job_id == 42, "StopCode should stop the hidden job")

	print("✓ close_all(hide active job) passed")
end

local function test_clean_invalid_keeps_intentionally_hidden_job()
	reset_state()
	local runner = registry.track(10, 20)
	runner.job_id = 42
	registry.close_by_win_id(10, false)

	_G.vim.api.nvim_win_is_valid = function()
		return false
	end
	registry.clean_invalid()
	_G.vim.api.nvim_win_is_valid = function(win_id)
		return win_id > 0
	end

	assert(#jobstop_calls == 0, "clean_invalid must not stop an intentionally hidden job")
	registry.close_all(true)
	assert(#jobstop_calls == 1, "the hidden job must remain available to StopCode")
	assert(jobstop_calls[1].job_id == 42, "StopCode must stop the hidden job")
	print("✓ clean_invalid preserves hidden active job")
end

-- Run all tests
test_track_single()
test_track_max_runners()
test_track_evicts_completed_runner_before_active_runners()
test_track_job_id()
test_close_by_win_id()
test_close_by_win_id_with_job_stop()
test_clean_invalid()
test_close_all()
test_close_all_with_job_stop()
test_close_all_hide_keeps_active_job_discoverable()
test_clean_invalid_keeps_intentionally_hidden_job()

print("All registry tests passed!")
