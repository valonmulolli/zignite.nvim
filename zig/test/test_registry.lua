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
	registry.close_all(false)
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
	local first
	for i = 1, 50 do
		first = registry.track(100 + i, 200 + i)
	end
	assert(first ~= nil, "Should still return the last tracked runner")

	-- Tracking 51st should evict oldest (win_id=101, buf_id=201)
	local new = registry.track(999, 888)
	assert(new.win_id == 999, "Should return the new runner")
	assert(new.buf_id == 888, "Should return the new runner buf_id")
	assert(type(new.job_id) == "nil", "job_id should be nil")

	-- The oldest runner (win_id=101) should have been evicted
	-- win_close_calls should have 1 entry for the evicted runner
	assert(#win_close_calls == 1, "Should have evicted the oldest runner via win_close")
	assert(win_close_calls[1].win_id == 101, "Oldest runner's win_id 101 should be closed")
	assert(win_close_calls[1].force == true, "Should close with force=true")

	-- buf_delete_calls should also have 1 entry
	assert(#buf_delete_calls == 1, "Should have evicted the oldest runner via buf_delete")
	assert(buf_delete_calls[1].buf_id == 201, "Oldest runner's buf_id 201 should be deleted")
	assert(buf_delete_calls[1].force == true, "Should delete with force=true")

	print("✓ track(max runners eviction) passed")
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
	registry.track(3, 4)

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

-- Run all tests
test_track_single()
test_track_max_runners()
test_track_job_id()
test_close_by_win_id()
test_close_by_win_id_with_job_stop()
test_clean_invalid()
test_close_all()
test_close_all_with_job_stop()

print("All registry tests passed!")
