-- luacheck: globals project_root config init ui state job_results quickfix_results notify_results mock_jobs
-- luacheck: globals command_to_string reset_job_results reset_quickfix_results reset_notify_results
-- luacheck: globals count_quickfix_backend_jobs count_quickfix_daemon_jobs
-- luacheck: globals count_detect_backend_jobs count_detect_backend_requests
-- luacheck: globals get_upvalue_by_name detect_backend_tool_commands

local build_module = require("zignite.build")
local runtime_module = require("zignite.runtime")

-- Test picker path never relies on vim.wait when async picker mode is enabled.
---@return nil
local function test_picker_async_path_without_wait()
	init.setup({
		build_commands = {},
		detect_runtime = {
			async_picker = true,
			cache_ttl_ms = 15000,
			live_merge = true,
		},
	})

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_open_win = vim.api.nvim_open_win
	local original_wait = vim.wait
	local picker_opened = false
	local wait_called = false

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/asyncwait/main.go"
		end
		return original_expand(expr)
	end
	vim.api.nvim_open_win = function(...)
		picker_opened = true
		return original_open_win(...)
	end
	vim.wait = function()
		wait_called = true
		error("picker async path should not call vim.wait")
	end

	local ok, err = pcall(init.select_build_command, "float")
	assert(ok, "Picker should open without vim.wait dependency: " .. tostring(err))
	assert(picker_opened, "Picker should still open in async mode")
	assert(not wait_called, "Async picker path should never call vim.wait")

	vim.fn.expand = original_expand
	vim.api.nvim_open_win = original_open_win
	vim.wait = original_wait

	print("✓ Picker async no-wait test passed")
end

-- Test RunBuild uses async detection fallback instead of sync vim.wait when
-- a detected command is not yet cached.
---@return nil
local function test_run_build_async_detect_without_wait()
	init.setup({
		build_commands = {},
		detect_runtime = {
			async_picker = true,
			cache_ttl_ms = 15000,
			live_merge = true,
		},
	})

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_wait = vim.wait

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/async-build/main.go"
		end
		return original_expand(expr)
	end
	vim.wait = function()
		error("run_build_command should not call vim.wait")
	end

	reset_job_results()
	local ok, err = pcall(init.run_build_command, "fmt", "float")
	assert(ok, "RunBuild should resolve detected commands without vim.wait: " .. tostring(err))
	assert(#job_results > 0, "RunBuild should start a job for detected command")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("go fmt"), "RunBuild should execute detected go fmt command")

	vim.fn.expand = original_expand
	vim.wait = original_wait
	reset_job_results()

	print("✓ RunBuild async detect test passed")
end

-- Test RunBuild completion stays non-blocking and uses literal prefix matching.
---@return nil
local function test_run_build_completion_nonblocking_prefix()
	local original_create_user_command = vim.api.nvim_create_user_command
	local original_expand = vim.fn.expand
	local original_wait = vim.wait
	local commands = {}

	config.setup({
		build_commands = {
			cpp = {
				["c++"] = "zig c++",
				clean = "make clean",
			},
		},
	})

	vim.bo.filetype = "cpp"
	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/completion/main.cpp"
		end
		return original_expand(expr)
	end
	vim.wait = function()
		error("completion should not call vim.wait")
	end
	vim.api.nvim_create_user_command = function(name, fn, opts)
		commands[name] = { fn = fn, opts = opts }
	end
	vim.g = vim.g or {}
	vim.g.loaded_zignite = nil

	dofile(project_root .. "/plugin/zignite.lua")

	assert(commands.RunBuild ~= nil, "Plugin should register RunBuild command")
	local matches = commands.RunBuild.opts.complete("c+", "", 0)
	assert(#matches == 1 and matches[1] == "c++", "RunBuild completion should use literal prefix matching")

	vim.api.nvim_create_user_command = original_create_user_command
	vim.fn.expand = original_expand
	vim.wait = original_wait
	vim.g.loaded_zignite = nil

	print("✓ RunBuild completion nonblocking prefix test passed")
end

-- Test picker opens from immediate commands then live-merges async detected commands.
---@return nil
local function test_picker_async_live_merge_refresh()
	init.setup({
		build_commands = {
			go = {
				build = "go build",
			},
		},
		detect_runtime = {
			async_picker = true,
			cache_ttl_ms = 1,
			live_merge = true,
		},
	})

	local targets_module = require("zignite.build.targets")
	local original_detect_async = targets_module.detect_tool_commands_for_filetype_async
	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_buf_set_lines = vim.api.nvim_buf_set_lines
	local rendered_lines = {}
	local deferred_detect = nil

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/asyncrefresh/main.go"
		end
		return original_expand(expr)
	end
	vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
		if type(lines) == "table" and #lines > 0 then
			rendered_lines = lines
		end
		if original_buf_set_lines then
			return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
		end
	end
	targets_module.detect_tool_commands_for_filetype_async = function(filetype, filepath, on_done)
		assert(filetype == "go", "Picker live refresh test should request Go tool detection")
		assert(filepath == "/tmp/asyncrefresh/main.go", "Picker live refresh test should pass the current file path")
		deferred_detect = {
			on_done = on_done,
			commands = {
				build = "go build",
				env = "go env",
				fmt = "go fmt",
			},
		}
	end

	reset_job_results()
	init.select_build_command("float")

	local initial_render = table.concat(rendered_lines, "\n")
	assert(initial_render:match("cmd:%s+go build"), "Initial picker render should keep selected command preview")
	assert(not initial_render:match("go env"), "Initial picker render should not include deferred detected commands")
	assert(deferred_detect and type(deferred_detect.on_done) == "function", "Detect response should be deferred")

	deferred_detect.on_done(deferred_detect.commands)
	local refreshed_render = table.concat(rendered_lines, "\n")
	assert(refreshed_render:match("go env"), "Live refresh should merge detected commands into picker")
	assert(refreshed_render:match("cmd:%s+go build"), "Live refresh should preserve selected command preview")

	vim.fn.expand = original_expand
	vim.api.nvim_buf_set_lines = original_buf_set_lines
	targets_module.detect_tool_commands_for_filetype_async = original_detect_async

	print("✓ Picker async live-merge refresh test passed")
end

-- Test picker detection cache invalidation uses TTL and mtime signature.
---@return nil
local function test_picker_detection_cache_ttl_and_mtime()
	init.setup({
		build_commands = {},
		detect_runtime = {
			async_picker = true,
			cache_ttl_ms = 15000,
			live_merge = false,
		},
	})

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_exepath = vim.fn.exepath
	local original_hrtime = vim.loop.hrtime
	local original_fs_stat = vim.loop.fs_stat
	local fake_now_ms = 1000
	local signature_version = 1

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/cachettl/main.go"
		end
		return original_expand(expr)
	end
	vim.fn.exepath = function(name)
		if name == "go" then
			return "/tmp/fake-go"
		end
		if original_exepath then
			return original_exepath(name)
		end
		return ""
	end
	vim.loop.hrtime = function()
		return fake_now_ms * 1e6
	end
	vim.loop.fs_stat = function(path)
		if path == "/tmp/fake-go" then
			return {
				size = 1,
				mtime = {
					sec = signature_version,
					nsec = 0,
				},
			}
		end
		if original_fs_stat then
			return original_fs_stat(path)
		end
		return nil
	end

	reset_job_results()
	init.select_build_command("float")
	local first = count_detect_backend_jobs()
	assert(first > 0, "First picker open should trigger detection")

	init.select_build_command("float")
	local second = count_detect_backend_jobs()
	assert(second == first, "Second picker open within TTL should reuse cache")

	fake_now_ms = fake_now_ms + 20000
	init.select_build_command("float")
	local third = count_detect_backend_jobs()
	assert(third > second, "TTL expiry should trigger new detection")

	fake_now_ms = fake_now_ms + 10
	signature_version = signature_version + 1
	init.select_build_command("float")
	local fourth = count_detect_backend_jobs()
	assert(fourth > third, "Mtime signature change should trigger new detection")

	vim.fn.expand = original_expand
	vim.fn.exepath = original_exepath
	vim.loop.hrtime = original_hrtime
	vim.loop.fs_stat = original_fs_stat

	print("✓ Picker detection cache TTL+mtime test passed")
end

-- Test failed detection retries sooner than the normal success TTL.
---@return nil
local function test_picker_detection_failed_cache_retries_early()
	init.setup({
		build_commands = {},
		detect_runtime = {
			async_picker = true,
			cache_ttl_ms = 15000,
			live_merge = false,
		},
	})

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_hrtime = vim.loop.hrtime
	local original_next_exit_code = state.next_exit_code
	local fake_now_ms = 1000

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/cachefail/main.go"
		end
		return original_expand(expr)
	end
	vim.loop.hrtime = function()
		return fake_now_ms * 1e6
	end

	reset_job_results()
	state.next_detect_backend_exit_code = 1
	state.next_exit_code = 1
	init.select_build_command("float")
	local first = count_detect_backend_requests()
	assert(first > 0, "First picker open should issue a detect request")

	fake_now_ms = fake_now_ms + 2000
	init.select_build_command("float")
	local second = count_detect_backend_requests()
	assert(second > first, "Failed detection cache should retry before normal TTL expiry")

	state.next_detect_backend_exit_code = 0
	state.next_exit_code = original_next_exit_code
	vim.fn.expand = original_expand
	vim.loop.hrtime = original_hrtime

	print("✓ Picker failed-detection retry test passed")
end

-- Test shebang cache remains bounded across many unique files.
---@return nil
local function test_shebang_cache_is_bounded()
	init.setup({})

	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local debug_state = runtime_module._debug_state()
	local shebang_cache = debug_state.shebang_filetype_cache
	local shebang_cache_order = debug_state.shebang_filetype_cache_order

	vim.fn.filereadable = function(path)
		if type(path) == "string" and path:match("^/tmp/shebang%-cache/") then
			return 1
		end
		if type(original_filereadable) == "function" then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path, mode, max_lines)
		if type(path) == "string" and path:match("^/tmp/shebang%-cache/") then
			return { "#!/usr/bin/env python" }
		end
		if type(original_readfile) == "function" then
			return original_readfile(path, mode, max_lines)
		end
		return {}
	end

	for index = 1, 300 do
		local filepath = string.format("/tmp/shebang-cache/%03d/script", index)
		init.get_command(filepath, "")
	end

	assert(type(shebang_cache) == "table", "Shebang cache upvalue should be available")
	assert(type(shebang_cache_order) == "table", "Shebang cache order upvalue should be available")
	assert(#shebang_cache_order <= 256, "Shebang cache should respect max size")
	assert(shebang_cache["/tmp/shebang-cache/001/script"] == nil, "Oldest shebang cache entry should be evicted")

	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile

	print("✓ Shebang cache bound test passed")
end

-- Test detect runtime cache remains bounded across many unique projects.
---@return nil
local function test_detect_runtime_cache_is_bounded()
	init.setup({
		build_commands = {},
		detect_runtime = {
			async_picker = true,
			cache_ttl_ms = 15000,
			live_merge = false,
		},
	})

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local debug_state = build_module._debug_state()
	local detect_cache = debug_state.detect_runtime_cache
	local detect_cache_order = debug_state.detect_runtime_cache_order

	for index = 1, 300 do
		vim.fn.expand = function(expr)
			if expr == "%:p" then
				return string.format("/tmp/detect-cache/%03d/main.go", index)
			end
			return original_expand(expr)
		end
		init.get_build_commands_for_completion("go")
	end

	assert(type(detect_cache) == "table", "Detect runtime cache upvalue should be available")
	assert(type(detect_cache_order) == "table", "Detect runtime cache order upvalue should be available")
	assert(#detect_cache_order <= 256, "Detect runtime cache should respect max size")
	assert(detect_cache["go::/tmp/detect-cache/001"] == nil, "Oldest detect runtime cache entry should be evicted")

	vim.fn.expand = original_expand

	print("✓ Detect runtime cache bound test passed")
end

test_picker_async_path_without_wait()
test_run_build_async_detect_without_wait()
test_run_build_completion_nonblocking_prefix()
test_picker_async_live_merge_refresh()
test_picker_detection_cache_ttl_and_mtime()
test_picker_detection_failed_cache_retries_early()
test_shebang_cache_is_bounded()
test_detect_runtime_cache_is_bounded()
