-- luacheck: globals project_root config init ui state job_results quickfix_results notify_results mock_jobs
-- luacheck: globals command_to_string reset_job_results reset_quickfix_results reset_notify_results
-- luacheck: globals count_quickfix_backend_jobs count_quickfix_daemon_jobs
-- luacheck: globals count_detect_backend_jobs count_detect_backend_requests
-- luacheck: globals get_upvalue_by_name detect_backend_tool_commands

local build_module = require("zignite.build")
local runtime_module = require("zignite.runtime")

---@param tbl table
---@return table
local function shallow_copy(tbl)
	local copied = {}
	for key, value in pairs(tbl or {}) do
		if type(value) == "table" then
			local nested = {}
			for nested_key, nested_value in pairs(value) do
				nested[nested_key] = nested_value
			end
			copied[key] = nested
		else
			copied[key] = value
		end
	end
	return copied
end

---@param query string
---@param filepath string
---@param project_root string|nil
---@param result table
---@return nil
local function seed_system_runtime_cache(query, filepath, project_root, result)
	local build_state = require("zignite.build.state")
	local cache_key = table.concat({
		tostring(query or ""),
		tostring(project_root or ""),
		vim.fs.normalize(tostring(filepath or "")),
	}, "::")
	build_state.set_bounded_cache_entry(
		build_state.system_runtime_cache,
		build_state.system_runtime_cache_order,
		build_state.SYSTEM_RUNTIME_CACHE_MAX,
		cache_key,
		{
			result = shallow_copy(result),
			updated_at_ms = build_state.now_ms(),
		}
	)
end

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

		local commands_module = require("zignite.build.command_policy")
		local original_detect_async = commands_module.detect_tool_commands_for_filetype_async
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
		commands_module.detect_tool_commands_for_filetype_async = function(filetype, filepath, on_done)
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
		commands_module.detect_tool_commands_for_filetype_async = original_detect_async

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

-- Test warmed Zig system cache wins over local fallback heuristics.
---@return nil
local function test_cached_zig_system_results_take_precedence()
	init.setup({
		build_commands = {},
	})

	local systems = require("zignite.build.system_runtime")
	local utils_module = require("zignite.utils")
	local original_get_project_root = utils_module.get_project_root
	local original_filereadable = vim.fn.filereadable

	build_module.reset()

	utils_module.get_project_root = function(path)
		if type(path) ~= "string" then
			return nil
		end
		if path:match("^/tmp/cached%-cfamily/") then
			return "/tmp/cached-cfamily"
		end
		if path:match("^/tmp/cached%-bazel/") then
			return "/tmp/cached-bazel/app"
		end
		if path:match("^/tmp/cached%-jvm/") then
			return "/tmp/cached-jvm/src"
		end
		if original_get_project_root then
			return original_get_project_root(path)
		end
		return nil
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/cached-cfamily/CMakeLists.txt" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end

	seed_system_runtime_cache("c-family", "/tmp/cached-cfamily/src/main.cpp", "/tmp/cached-cfamily", {
		root = "/tmp/zig-cfamily",
		system = "meson",
		build_ready = true,
		commands = {
			["meson-setup"] = "meson setup build",
			["meson-build"] = "meson compile -C build",
			["meson-clean"] = "meson compile -C build --clean",
			["meson-test"] = "meson test -C build",
			setup = "meson setup build",
			build = "meson compile -C build",
			clean = "meson compile -C build --clean",
			test = "meson test -C build",
		},
	})
	seed_system_runtime_cache("bazel-root", "/tmp/cached-bazel/app/main.cc", "/tmp/cached-bazel/app", {
		root = "/tmp/zig-bazel",
		system = "bazel",
		commands = {
			["bazel-query"] = "bazel query $zignite_args",
			["bazel-clean"] = "bazel clean",
			["bazel-build-all"] = "bazel build //...",
			["bazel-test-all"] = "bazel test //...",
			build = "bazel build //...",
			test = "bazel test //...",
		},
	})
	seed_system_runtime_cache("jvm-root", "/tmp/cached-jvm/src/Main.kt", "/tmp/cached-jvm/src", {
		root = "/tmp/zig-jvm",
		system = "gradle",
		commands = {
			["gradle-build"] = "./gradlew build",
			["gradle-test"] = "./gradlew test",
			["gradle-clean"] = "./gradlew clean",
			build = "./gradlew build",
			test = "./gradlew test",
			clean = "./gradlew clean",
		},
	})

	local c_family_system, c_family_root = systems.detect_c_family_build_system("/tmp/cached-cfamily/src/main.cpp")
	assert(c_family_system == "meson", "Cached Zig c-family result should beat local marker fallback")
	assert(c_family_root == "/tmp/zig-cfamily", "Cached Zig c-family root should be returned")

	local bazel_root = systems.resolve_bazel_root("/tmp/cached-bazel/app/main.cc")
	assert(bazel_root == "/tmp/zig-bazel", "Cached Zig Bazel root should beat local fallback")

	local jvm_root, jvm_system = systems.resolve_jvm_root("/tmp/cached-jvm/src/Main.kt")
	assert(jvm_root == "/tmp/zig-jvm", "Cached Zig JVM root should beat local fallback")
	assert(jvm_system == "gradle", "Cached Zig JVM system should beat local fallback")

	local cached_build_commands = build_module.get_build_commands_for_cached_lookup(
		"cpp",
		"/tmp/cached-cfamily/src/main.cpp",
		nil
	)
	assert(
		cached_build_commands["meson-build"] == "meson compile -C build",
		"Cached Zig c-family system commands should feed immediate build lookup"
	)
	assert(
		cached_build_commands.build == "meson compile -C build",
		"Cached Zig c-family generic aliases should feed immediate build lookup"
	)

	local cached_java_commands = build_module.get_build_commands_for_cached_lookup(
		"java",
		"/tmp/cached-jvm/src/Main.kt",
		nil
	)
	assert(
		cached_java_commands["gradle-build"] == "./gradlew build",
		"Cached Zig JVM system commands should feed immediate Java build lookup"
	)

	local cached_bazel_commands = build_module.get_build_commands_for_cached_lookup(
		"cpp",
		"/tmp/cached-bazel/app/main.cc",
		nil
	)
	assert(
		cached_bazel_commands["bazel-build-all"] == "bazel build //...",
		"Cached Zig Bazel system commands should feed immediate Bazel build lookup"
	)

	utils_module.get_project_root = original_get_project_root
	vim.fn.filereadable = original_filereadable
	build_module.reset()

	print("✓ Cached Zig system precedence test passed")
end

-- Test async system prewarm still asks Zig even when local markers already identify the project.
---@return nil
local function test_async_system_prewarm_prefers_zig_queries_over_local_gating()
	init.setup({
		build_commands = {},
		detect_runtime = {
			async_picker = true,
			cache_ttl_ms = 15000,
			live_merge = false,
		},
	})

	local systems = require("zignite.build.system_runtime")
	local detect_backend = require("zignite.build.detect.backend")
	local utils_module = require("zignite.utils")
	local original_get_project_root = utils_module.get_project_root
	local original_parse_project_lines_async = detect_backend.parse_project_lines_async
	local original_filereadable = vim.fn.filereadable
	local queries = {}

	build_module.reset()

	utils_module.get_project_root = function(path)
		if type(path) ~= "string" then
			return nil
		end
		if path:match("^/tmp/warm%-make/") then
			return "/tmp/warm-make"
		end
		if path:match("^/tmp/warm%-jvm/") then
			return "/tmp/warm-jvm"
		end
		if original_get_project_root then
			return original_get_project_root(path)
		end
		return nil
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/warm-make/Makefile" then
			return 1
		end
		if path == "/tmp/warm-jvm/gradlew" or path == "/tmp/warm-jvm/build.gradle.kts" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	detect_backend.parse_project_lines_async = function(kind, path, extra_args, on_done)
		assert(kind == "system", "System prewarm should use the system backend kind")
		local query = nil
		for _, arg in ipairs(extra_args or {}) do
			query = arg:match("^%-%-query=(.+)$") or query
		end
		queries[#queries + 1] = string.format("%s::%s", tostring(path), tostring(query))
		on_done({})
		return true
	end

	local always_enabled = function()
		return true
	end
	local finished = 0

	systems.prime_system_detection_async("cpp", "/tmp/warm-make/src/main.cpp", always_enabled, function()
		finished = finished + 1
	end)
	systems.prime_system_detection_async("java", "/tmp/warm-jvm/src/Main.kt", always_enabled, function()
		finished = finished + 1
	end)

	assert(finished == 2, "Immediate backend callbacks should complete both prewarm requests")
	assert(
		vim.tbl_contains(queries, "/tmp/warm-make/src/main.cpp::c-family"),
		"C/C++ prewarm should request the Zig c-family query"
	)
	assert(
		vim.tbl_contains(queries, "/tmp/warm-jvm/src/Main.kt::jvm-root"),
		"JVM prewarm should request the Zig jvm-root query"
	)

	detect_backend.parse_project_lines_async = original_parse_project_lines_async
	utils_module.get_project_root = original_get_project_root
	vim.fn.filereadable = original_filereadable
	build_module.reset()

	print("✓ Async system prewarm Zig query test passed")
end

-- Test cached C/C++ lookup returns local fallback immediately, then upgrades from warmed Zig project records.
---@return nil
local function test_async_c_family_project_prewarm_avoids_sync_parse()
	init.setup({
		build_commands = {},
		detect_runtime = {
			async_picker = true,
			cache_ttl_ms = 15000,
			live_merge = false,
		},
	})

	local detect_backend = require("zignite.build.detect.backend")
	local utils_module = require("zignite.utils")
	local original_get_project_root = utils_module.get_project_root
	local original_parse_project_lines_async = detect_backend.parse_project_lines_async
	local original_parse_project_lines_once = detect_backend.parse_project_lines_once
	local original_filereadable = vim.fn.filereadable
	local async_queries = {}
	local sync_c_family_auto_called = false
	local refreshed_commands = nil

	build_module.reset()

	utils_module.get_project_root = function(path)
		if type(path) == "string" and path:match("^/tmp/warm%-cfamily/") then
			return "/tmp/warm-cfamily"
		end
		if original_get_project_root then
			return original_get_project_root(path)
		end
		return nil
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/warm-cfamily/CMakeLists.txt" then
			return 1
		end
		if path == "/tmp/warm-cfamily/build/CMakeCache.txt" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	detect_backend.parse_project_lines_once = function(kind, path, extra_args)
		if kind == "c-family-auto" then
			sync_c_family_auto_called = true
			error("cached lookup should not sync-parse c-family-auto")
		end
		if original_parse_project_lines_once then
			return original_parse_project_lines_once(kind, path, extra_args)
		end
		return {}
	end
	detect_backend.parse_project_lines_async = function(kind, path, _extra_args, on_done)
		async_queries[#async_queries + 1] = string.format("%s::%s", tostring(kind), tostring(path))
		if kind == "system" then
			on_done({
				"ROOT\t/tmp/warm-cfamily",
				"SYSTEM\tcmake",
				"BUILD_READY\t1",
			})
			return true
		end
		if kind == "c-family-auto" then
			on_done({
				"ROOT\t/tmp/warm-cfamily",
				"SYSTEM\tcmake",
				"BUILD_READY\t1",
				"COMMAND\tcmake-build\tcmake --build build",
				"COMMAND\tcmake-run\tcmake --build build --target app && ./build/app",
				"COMMAND\tbuild\tcmake --build build",
				"COMMAND\trun\tcmake --build build --target app && ./build/app",
				"COMMAND\tcmake-build-app\tcmake --build build --target app",
				"COMMAND\tcmake-run-app\tcmake --build build --target app && ./build/app",
			})
			return true
		end
		return false
	end

	local immediate_commands, refresh_started = build_module.get_build_commands_for_cached_lookup(
		"cpp",
		"/tmp/warm-cfamily/src/main.cpp",
		function(updated_commands)
			refreshed_commands = updated_commands
		end
	)

	assert(refresh_started, "Cached C/C++ lookup should start async refresh")
	assert(
		type(immediate_commands["cmake-build"]) == "string",
		"Immediate cached C/C++ lookup should still expose fallback CMake commands"
	)
	assert(
		immediate_commands["cmake-build-app"] == nil,
		"Immediate cached C/C++ lookup should not invent target-specific commands before Zig warms the cache"
	)
	assert(
		type(refreshed_commands) == "table" and refreshed_commands["cmake-build-app"] == "cmake --build build --target app",
		"Async refresh should merge warmed Zig C/C++ project commands"
	)
	assert(
		vim.tbl_contains(async_queries, "system::/tmp/warm-cfamily/src/main.cpp"),
		"C/C++ cached lookup should prewarm the Zig system query"
	)
	assert(
		vim.tbl_contains(async_queries, "c-family-auto::/tmp/warm-cfamily/src/main.cpp"),
		"C/C++ cached lookup should prewarm the Zig c-family project query"
	)
	assert(not sync_c_family_auto_called, "Cached C/C++ lookup should not fall back to sync c-family-auto parsing")

	detect_backend.parse_project_lines_async = original_parse_project_lines_async
	detect_backend.parse_project_lines_once = original_parse_project_lines_once
	utils_module.get_project_root = original_get_project_root
	vim.fn.filereadable = original_filereadable
	build_module.reset()

	print("✓ Async C/C++ project prewarm test passed")
end

test_picker_async_path_without_wait()
test_run_build_async_detect_without_wait()
test_run_build_completion_nonblocking_prefix()
test_picker_async_live_merge_refresh()
test_picker_detection_cache_ttl_and_mtime()
test_picker_detection_failed_cache_retries_early()
test_shebang_cache_is_bounded()
test_detect_runtime_cache_is_bounded()
test_cached_zig_system_results_take_precedence()
test_async_system_prewarm_prefers_zig_queries_over_local_gating()
test_async_c_family_project_prewarm_avoids_sync_parse()
