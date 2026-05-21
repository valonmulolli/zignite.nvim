-- luacheck: globals project_root config reset_job_results get_upvalue_by_name

local build_resolve = require("zignite.rpc.build_resolve")
local config_sync = require("zignite.rpc.config_sync")
local run_resolve = require("zignite.rpc.run_resolve")

local function encode_json(payload)
	local encode = vim.json and vim.json.encode or vim.fn.json_encode
	return encode(payload)
end

local function test_build_resolve_returns_command_metadata()
	config.setup({
		build_commands = {
			zig = {
				fetch = "zig fetch $zignite_args",
			},
		},
	})

	local resolved = build_resolve.resolve_sync("/tmp/zignite-build/build.zig", "zig")
	assert(type(resolved) == "table", "build_resolve.resolve_sync should return a table")
	assert(resolved.ok == true, "build_resolve.resolve_sync should mark backend success explicitly")
	assert(resolved.commands.fetch == "zig fetch $zignite_args", "build_resolve should include configured command")
	assert(type(resolved.command_meta) == "table" and type(resolved.command_meta.fetch) == "table",
		"build_resolve should include command metadata")
	assert(type(resolved.command_entries) == "table" and #resolved.command_entries == 1,
		"build_resolve should expose backend picker entries")
	assert(resolved.command_entries[1].name == "fetch",
		"build_resolve should keep picker entry ordering in backend output")
	assert(type(resolved.completion_names) == "table" and resolved.completion_names[1] == "fetch",
		"build_resolve should expose backend completion names")
	assert(resolved.command_meta.fetch.display_command == "zig fetch <args>",
		"build_resolve should expose display command metadata")
	assert(resolved.command_meta.fetch.picker_section == "common",
		"build_resolve should expose backend picker section metadata")
	assert(type(resolved.command_meta.fetch.picker_rank) == "number",
		"build_resolve should expose backend picker rank metadata")
	assert(resolved.command_meta.fetch.requires_arguments == true,
		"build_resolve should mark placeholder commands as requiring arguments")
	assert(resolved.command_meta.fetch.argument_prompt == "zig fetch url/path",
		"build_resolve should expose backend prompt text")
	assert(resolved.config_revision == config.revision, "build_resolve should report the synced config revision")

	reset_job_results()
	print("✓ Build resolve metadata test passed")
end

local function test_build_resolve_reports_backend_no_build_commands()
	config.setup({
		build_commands = {},
	})

	local resolved = build_resolve.resolve_sync("/tmp/zignite-build/main.unknown", "unknownft")
	assert(type(resolved) == "table", "build_resolve should return a structured table when no commands exist")
	assert(resolved.ok == false, "build_resolve should mark no-command results as ok=false")
	assert(resolved.reason == "no_build_commands", "build_resolve should expose backend no-command reason")
	assert(type(resolved.message) == "string" and resolved.message:match("No build commands available"),
		"build_resolve should expose backend no-command message")

	reset_job_results()
	print("✓ Build resolve backend no-build-commands test passed")
end

local function test_build_resolve_selected_command_materializes_execution()
	config.setup({
		build_commands = {
			zig = {
				fetch = "zig fetch $zignite_args",
			},
		},
	})

	local resolved = build_resolve.resolve_action_sync(
		"/tmp/zignite-build/build.zig",
		"zig",
		"named",
		"fetch",
		"owner/repo"
	)
	assert(type(resolved) == "table", "resolve_action_sync should return a table")
	assert(
		resolved.exec_command == "zig fetch --save git+https://github.com/owner/repo",
		"resolve_action_sync should materialize the backend command"
	)
	assert(type(resolved.exec_argv) == "table" and resolved.exec_argv[1] == "zig",
		"resolve_action_sync should return argv tokens for the resolved build command")
	assert(resolved.exec_argv[2] == "fetch", "resolve_action_sync argv should preserve the subcommand")
	assert(resolved.exec_argv[3] == "--save", "resolve_action_sync argv should preserve normalized flags")
	assert(resolved.exec_argv[4] == "git+https://github.com/owner/repo",
		"resolve_action_sync argv should preserve the normalized repository value")
	assert(resolved.name == "zig: fetch", "resolve_action_sync should expose execution display name")
	assert(resolved.cwd == "/tmp/zignite-build", "resolve_action_sync should expose backend cwd")

	reset_job_results()
	print("✓ Build resolve command materialization test passed")
end

local function test_build_resolve_exposes_preferred_live_name()
	local root = "/tmp/zignite-live-name"
	os.execute("mkdir -p " .. root .. " >/dev/null 2>&1")
	local package_json = assert(io.open(root .. "/package.json", "w"))
	package_json:write(table.concat({
		"{",
		'  "scripts": {',
		'    "dev": "vite",',
		'    "build": "vite build"',
		"  }",
		"}",
	}, "\n"))
	package_json:write("\n")
	package_json:close()

	local filepath = root .. "/main.ts"
	local source = assert(io.open(filepath, "w"))
	source:write("console.log('hi')\n")
	source:close()

	local resolved = build_resolve.resolve_sync(filepath, "typescript")
	assert(type(resolved) == "table", "expected build resolve result")
	assert(type(resolved.preferred_names) == "table", "expected preferred_names table")
	assert(resolved.preferred_names.live == "live", "expected preferred live name from backend")

	os.remove(filepath)
	os.remove(root .. "/package.json")
	os.execute("rmdir " .. root .. " >/dev/null 2>&1")
	reset_job_results()
	print("✓ Build resolve preferred live name test passed")
end

local function test_run_resolve_returns_backend_runner_payload()
	config.setup({
		runners = {
			python = "python3 -u $file",
		},
	})

	local resolved = run_resolve.resolve_sync("/tmp/zignite-run/main.py", "python")
	assert(type(resolved) == "table", "run_resolve.resolve_sync should return a table")
	assert(resolved.command == "python3 -u '/tmp/zignite-run/main.py'",
		"run_resolve should return the substituted backend command")
	assert(type(resolved.argv) == "table" and resolved.argv[1] == "python3",
		"run_resolve should return argv tokens from the backend")
	assert(resolved.argv[2] == "-u", "run_resolve argv should preserve flags")
	assert(resolved.argv[3] == "/tmp/zignite-run/main.py", "run_resolve argv should preserve file path")
	assert(resolved.execution_path == "/tmp/zignite-run/main.py",
		"run_resolve should expose the backend-owned execution path")
	assert(resolved.source == "filetype", "run_resolve should report the runner source")
	assert(resolved.filetype == "python", "run_resolve should report the resolved filetype")
	assert(resolved.name == "python", "run_resolve should expose backend runner name")

	reset_job_results()
	print("✓ Run resolve payload test passed")
end

local function test_run_code_uses_backend_execution_path_for_file_runs()
	config.setup({})

	local init = require("zignite.init")
	local original_expand = vim.fn.expand
	local original_execute_command = init.execute_command
	local original_run_resolve_sync_request = run_resolve.resolve_sync_request
	local captured_command = nil

	vim.bo.filetype = "python"
	vim.fn.expand = function(expr)
		if expr == "%:p" then return "/tmp/zignite-run/original.py" end
		return original_expand(expr)
	end
	run_resolve.resolve_sync_request = function(request)
		assert(type(request) == "table", "expected run request table")
		assert(request.path == "/tmp/zignite-run/original.py", "expected source filepath passed to backend")
		assert(request.filetype == "python", "expected filetype passed to backend")
		assert(request.context_path == "/tmp/zignite-run/original.py", "expected context path passed to backend")
		assert(request.input_kind == nil, "expected file runs to omit frontend input kind classification")
		assert(request.selection_text == nil, "expected file runs to omit inline source payload")
		return {
			execution_path = "/tmp/zignite-run/backend-owned.py",
			system_argv = { "zig/zig-out/bin/zignite", "--argv", "python3", "-u", "/tmp/zignite-run/backend-owned.py" },
			filetype = "python",
			name = "python",
		}
	end
	init.execute_command = function(system_command)
		captured_command = type(system_command) == "table" and table.concat(system_command, " ") or tostring(system_command)
	end

	init.run_code(0, "float")

	init.execute_command = original_execute_command
	run_resolve.resolve_sync_request = original_run_resolve_sync_request
	vim.fn.expand = original_expand

	assert(type(captured_command) == "string" and captured_command:match("/tmp/zignite%-run/backend%-owned%.py"),
		"run_code should trust backend execution_path for file runs")

	reset_job_results()
	print("✓ Run code backend execution path test passed")
end

local function test_run_resolve_request_supports_selection_payload()
	config.setup({})

	local resolved = run_resolve.resolve_sync_request({
		path = "/tmp/zignite-run/main.zig",
		filetype = "zig",
		context_path = "/tmp/zignite-run/main.zig",
		selection_text = "pub fn main() void {}\n",
	})

	assert(type(resolved) == "table", "selection resolve should return a table")
	assert(type(resolved.execution_path) == "string" and resolved.execution_path ~= "",
		"selection resolve should expose an execution path")
	assert(resolved.execution_path ~= "/tmp/zignite-run/main.zig",
		"selection resolve should use a backend-managed scratch path")
	assert(resolved.execution_path:match("%.zig$"),
		"selection resolve should preserve the Zig extension")
	assert(type(resolved.argv) == "table" and resolved.argv[3] == resolved.execution_path,
		"selection resolve argv should point at the backend-managed execution path")

	os.remove(resolved.execution_path)
	reset_job_results()
	print("✓ Run resolve selection payload test passed")
end

local function test_run_resolve_selection_supports_unsaved_buffers()
	config.setup({})

	local resolved = run_resolve.resolve_sync_request({
		path = "",
		filetype = "zig",
		context_path = nil,
		buffer_id = 77,
		selection_text = "pub fn main() void {}\n",
	})

	assert(type(resolved) == "table", "unsaved selection resolve should return a table")
	assert(type(resolved.execution_path) == "string" and resolved.execution_path:match("%.zig$"),
		"unsaved selection resolve should still derive a Zig scratch path")
	assert(type(resolved.argv) == "table" and resolved.argv[3] == resolved.execution_path,
		"unsaved selection argv should point at the backend-managed scratch path")

	os.remove(resolved.execution_path)
	reset_job_results()
	print("✓ Run resolve unsaved selection test passed")
end

local function test_run_resolve_buffer_supports_unsaved_full_buffers()
	config.setup({})

	local resolved = run_resolve.resolve_sync_request({
		path = "",
		filetype = "zig",
		context_path = nil,
		buffer_id = 88,
		selection_text = "pub fn main() void {}\n",
	})

	assert(type(resolved) == "table", "unsaved full-buffer resolve should return a table")
	assert(type(resolved.execution_path) == "string" and resolved.execution_path:match("%.zig$"),
		"unsaved full-buffer resolve should derive a Zig scratch path")
	assert(type(resolved.argv) == "table" and resolved.argv[3] == resolved.execution_path,
		"unsaved full-buffer argv should point at the backend-managed scratch path")

	os.remove(resolved.execution_path)
	reset_job_results()
	print("✓ Run resolve unsaved full-buffer test passed")
end

local function test_run_code_supports_unsaved_buffers_via_backend_buffer()
	config.setup({})

	local init = require("zignite.init")
	local original_expand = vim.fn.expand
	local original_buf_get_lines = vim.api.nvim_buf_get_lines
	local original_execute_command = init.execute_command
	local original_run_resolve_sync_request = run_resolve.resolve_sync_request
	local captured_command = nil
	local captured_request = nil

	vim.bo.filetype = "zig"
	vim.fn.expand = function(expr)
		if expr == "%:p" then return "" end
		return original_expand(expr)
	end
	vim.api.nvim_buf_get_lines = function(_, start_idx, end_idx, strict)
		if start_idx == 0 and end_idx == -1 and strict == false then
			return { "pub fn main() void {}", "" }
		end
		return original_buf_get_lines(_, start_idx, end_idx, strict)
	end
	run_resolve.resolve_sync_request = function(request)
		captured_request = request
		return {
			execution_path = "/tmp/zignite-run/backend-buffer.zig",
			system_argv = { "zig/zig-out/bin/zignite", "--argv", "zig", "run", "/tmp/zignite-run/backend-buffer.zig" },
			filetype = "zig",
			name = "zig",
		}
	end
	init.execute_command = function(system_command)
		captured_command = type(system_command) == "table" and table.concat(system_command, " ") or tostring(system_command)
	end

	init.run_code(0, "float")

	init.execute_command = original_execute_command
	run_resolve.resolve_sync_request = original_run_resolve_sync_request
	vim.api.nvim_buf_get_lines = original_buf_get_lines
	vim.fn.expand = original_expand

	assert(type(captured_request) == "table", "unsaved RunFile should build a backend request")
	assert(captured_request.input_kind == nil, "unsaved RunFile should leave input kind inference to the backend")
	assert(captured_request.path == "", "unsaved RunFile should report an empty source path")
	assert(captured_request.buffer_id == 1, "unsaved RunFile should include the current buffer id")
	assert(captured_request.selection_text == "pub fn main() void {}\n",
		"unsaved RunFile should send full buffer contents to the backend")
	assert(type(captured_command) == "string" and captured_command:match("/tmp/zignite%-run/backend%-buffer%.zig"),
		"unsaved RunFile should trust the backend-managed execution path")

	reset_job_results()
	print("✓ Run code unsaved buffer backend buffer test passed")
end

local function test_run_resolve_saved_zig_file_with_wrong_extension_uses_backend_materialized_path()
	config.setup({})

	local source_path = "/tmp/zignite-run/not-zig.txt"
	os.execute("mkdir -p /tmp/zignite-run >/dev/null 2>&1")
	local handle = assert(io.open(source_path, "w"))
	handle:write("pub fn main() void {}\n")
	handle:close()

	local resolved = run_resolve.resolve_sync_request({
		path = source_path,
		filetype = "zig",
		context_path = source_path,
	})

	assert(type(resolved) == "table", "saved zig resolve should return a table")
	assert(type(resolved.execution_path) == "string" and resolved.execution_path:match("%.zig$"),
		"saved zig buffers with a wrong extension should use a backend-managed .zig path")
	assert(resolved.execution_path ~= source_path,
		"saved zig buffers with a wrong extension should no longer run the original non-.zig path")
	assert(type(resolved.argv) == "table" and resolved.argv[3] == resolved.execution_path,
		"saved zig argv should target the backend-managed .zig path")

	os.remove(source_path)
	os.remove(resolved.execution_path)
	reset_job_results()
	print("✓ Run resolve saved zig wrong-extension backend materialization test passed")
end

local function test_run_code_saved_zig_buffer_with_wrong_extension_accepts_backend_path()
	config.setup({})

	local init = require("zignite.init")
	local original_expand = vim.fn.expand
	local original_execute_command = init.execute_command
	local original_run_resolve_sync_request = run_resolve.resolve_sync_request
	local captured_command = nil

	vim.bo.filetype = "zig"
	vim.fn.expand = function(expr)
		if expr == "%:p" then return "/tmp/zignite-run/not-zig.txt" end
		return original_expand(expr)
	end
	run_resolve.resolve_sync_request = function(request)
		assert(request.path == "/tmp/zignite-run/not-zig.txt",
			"saved zig RunFile should forward the original editor path to the backend")
		return {
			execution_path = "/tmp/zignite-run/backend-materialized.zig",
			system_argv = { "zig/zig-out/bin/zignite", "--argv", "zig", "run", "/tmp/zignite-run/backend-materialized.zig" },
			filetype = "zig",
			name = "zig",
		}
	end
	init.execute_command = function(system_command)
		captured_command = type(system_command) == "table" and table.concat(system_command, " ") or tostring(system_command)
	end

	init.run_code(0, "float")

	init.execute_command = original_execute_command
	run_resolve.resolve_sync_request = original_run_resolve_sync_request
	vim.fn.expand = original_expand

	assert(type(captured_command) == "string" and captured_command:match("/tmp/zignite%-run/backend%-materialized%.zig"),
		"saved zig RunFile should trust the backend-managed .zig path")

	reset_job_results()
	print("✓ Run code saved zig wrong-extension backend path test passed")
end

local function test_build_resolve_requires_completed_config_sync()
	config.setup({
		build_commands = {
			zig = {
				fetch = "zig fetch $zignite_args",
			},
		},
	})

	local original_ensure_synced = config_sync.ensure_synced
	config_sync.ensure_synced = function()
		return false
	end

	local resolved = build_resolve.resolve_sync("/tmp/zignite-build/build.zig", "zig")
	assert(type(resolved) == "table", "build_resolve.resolve_sync should return a structured failure table")
	assert(resolved.ok == false, "build_resolve.resolve_sync should report config sync failure as ok=false")
	assert(resolved.reason == "config_sync_failed",
		"build_resolve.resolve_sync should expose bridge failure reason when config sync is unavailable")
	assert(type(resolved.message) == "string" and resolved.message:match("Failed to resolve build commands"),
		"build_resolve.resolve_sync should expose a bridge failure message")

	local command_resolved = build_resolve.resolve_action_sync(
		"/tmp/zignite-build/build.zig",
		"zig",
		"named",
		"fetch",
		"owner/repo"
	)
	assert(type(command_resolved) == "table", "resolve_action_sync should return a structured failure table")
	assert(command_resolved.ok == false, "resolve_action_sync should report config sync failure as ok=false")
	assert(command_resolved.reason == "config_sync_failed",
		"resolve_action_sync should expose bridge failure reason when config sync is unavailable")
	assert(type(command_resolved.message) == "string" and command_resolved.message:match("Failed to resolve build action"),
		"resolve_action_sync should expose a bridge failure message")

	local callback_result = "unset"
	local started = build_resolve.resolve_async("/tmp/zignite-build/build.zig", "zig", function(result)
		callback_result = result
	end)
	assert(started == false, "resolve_async should not start when config sync is unavailable")
	assert(type(callback_result) == "table", "resolve_async should report a structured failure to the callback")
	assert(callback_result.ok == false and callback_result.reason == "config_sync_failed",
		"resolve_async should expose config sync failure details to the callback")

	config_sync.ensure_synced = original_ensure_synced
	reset_job_results()
	print("✓ Build resolve config sync gate test passed")
end

local function test_config_sync_request_includes_timeout()
	local ensure_synced_impl = get_upvalue_by_name(config_sync.ensure_synced, "ensure_synced")
	assert(type(ensure_synced_impl) == "function", "expected local ensure_synced function")
	local sync_sync_impl = get_upvalue_by_name(ensure_synced_impl, "sync_sync")
	assert(type(sync_sync_impl) == "function", "expected local sync_sync function")
	local build_sync_request = get_upvalue_by_name(sync_sync_impl, "build_sync_request")
	assert(type(build_sync_request) == "function", "expected local build_sync_request function")

	local request = build_sync_request({
		build_commands = {},
		detect = {},
		runners = {},
		project = {},
		timeout = 1200,
	}, 17)
	assert(type(request) == "table" and type(request.json) == "string", "expected encoded config sync request")

	local decode = vim.json and vim.json.decode or vim.fn.json_decode
	local payload = decode(request.json)
	assert(payload.timeout == 1200, "config sync payload should include timeout")

	reset_job_results()
	print("✓ Config sync timeout payload test passed")
end

local function test_config_sync_falls_back_to_one_shot_mode()
	local ensure_synced_impl = get_upvalue_by_name(config_sync.ensure_synced, "ensure_synced")
	assert(type(ensure_synced_impl) == "function", "expected local ensure_synced function")
	local sync_sync_impl = get_upvalue_by_name(ensure_synced_impl, "sync_sync")
	local sync_once_impl = get_upvalue_by_name(ensure_synced_impl, "sync_once")
	local config_client = get_upvalue_by_name(sync_sync_impl, "config_client")
	assert(type(config_client) == "table", "expected config client upvalue")
	assert(type(sync_once_impl) == "function", "expected sync_once upvalue")

	local original_sync_request = config_client.sync_request
	local original_systemlist = vim.fn.systemlist
	local original_shell_error = vim.v.shell_error
	config_client.sync_request = function()
		return nil
	end
	vim.fn.systemlist = function(argv, input)
		assert(argv[2] == "--config-sync", "expected one-shot config-sync fallback")
		assert(type(input) == "string" and input ~= "", "expected config payload on stdin")
		return { "REVISION\t23" }
	end
	vim.v.shell_error = 0

	local ok = config_sync.ensure_synced({
		build_commands = {},
		detect = {},
		runners = {},
		project = {},
		timeout = 1200,
	}, 23)

	config_client.sync_request = original_sync_request
	vim.fn.systemlist = original_systemlist
	vim.v.shell_error = original_shell_error

	assert(ok == true, "config sync should fall back to one-shot mode")

	reset_job_results()
	print("✓ Config sync one-shot fallback test passed")
end

local function test_config_sync_surfaces_backend_validation_warnings()
	local ensure_synced_impl = get_upvalue_by_name(config_sync.ensure_synced, "ensure_synced")
	assert(type(ensure_synced_impl) == "function", "expected local ensure_synced function")
	local sync_sync_impl = get_upvalue_by_name(ensure_synced_impl, "sync_sync")
	local config_client = get_upvalue_by_name(sync_sync_impl, "config_client")
	assert(type(config_client) == "table", "expected config client upvalue")

	local original_sync_request = config_client.sync_request
	local original_systemlist = vim.fn.systemlist
	local original_shell_error = vim.v.shell_error
	config_client.sync_request = function()
		return nil
	end
	vim.fn.systemlist = function()
		return {
			"WARN\tInvalid config detect.zig: expected boolean, got string",
			"REVISION\t24",
		}
	end
	vim.v.shell_error = 0
	reset_notify_results()

	local ok = config_sync.ensure_synced({
		build_commands = {},
		detect = {
			zig = "yes",
		},
		runners = {},
		project = {},
		timeout = nil,
	}, 24)

	config_client.sync_request = original_sync_request
	vim.fn.systemlist = original_systemlist
	vim.v.shell_error = original_shell_error

	assert(ok == true, "config sync should still succeed when backend reports validation warnings")
	assert(#notify_results >= 1, "backend config warnings should surface through vim.notify")
	assert(type(notify_results[#notify_results].msg) == "string"
		and notify_results[#notify_results].msg:match("detect%.zig"),
		"config warning notify should come from backend warning lines")

	reset_job_results()
	reset_notify_results()
	print("✓ Config sync backend validation warning test passed")
end

local function test_build_resolve_sync_falls_back_to_once_request()
	config.setup({})

	local resolve_client = get_upvalue_by_name(build_resolve.resolve_sync, "resolve_client")
	assert(type(resolve_client) == "table", "expected build resolve client upvalue")

	local original_sync_request = resolve_client.sync_request
	local original_once_request = resolve_client.once_request
	resolve_client.sync_request = function()
		return nil
	end
	resolve_client.once_request = function()
		return {
			"RESULT_JSON\t" .. encode_json({
				ok = true,
				commands = { build = "echo fallback-build" },
				command_meta = {},
				preferred_commands = {},
				preferred_names = {},
				config_revision = config.revision,
			}),
		}
	end

	local ok, resolved = pcall(build_resolve.resolve_sync, "/tmp/zignite-fallback/build.zig", "zig")

	resolve_client.sync_request = original_sync_request
	resolve_client.once_request = original_once_request

	assert(ok, resolved)
	assert(type(resolved) == "table", "expected fallback build resolve result")
	assert(resolved.commands.build == "echo fallback-build", "build resolve should fall back to once_request in sync mode")

	reset_job_results()
	print("✓ Build resolve sync fallback test passed")
end

local function test_run_resolve_reports_backend_no_runner_failure()
	config.setup({
		runners = {},
	})

	local resolved = run_resolve.resolve_sync("/tmp/zignite-run/main.unknown", "unknownft")
	assert(type(resolved) == "table", "run_resolve should return a table for backend failures")
	assert(resolved.ok == false, "run_resolve should surface backend no-runner as ok=false")
	assert(resolved.reason == "no_runner", "run_resolve should expose backend failure reason")
	assert(type(resolved.message) == "string" and resolved.message:match("No runner configured"),
		"run_resolve should expose backend failure message")

	reset_job_results()
	print("✓ Run resolve backend no-runner failure test passed")
end

local function test_build_action_sync_falls_back_to_once_request()
	config.setup({})

	local action_client = get_upvalue_by_name(build_resolve.resolve_action_sync, "action_client")
	assert(type(action_client) == "table", "expected build action client upvalue")

	local original_sync_request = action_client.sync_request
	local original_once_request = action_client.once_request
	action_client.sync_request = function()
		return nil
	end
	action_client.once_request = function()
		return {
			"RESULT_JSON\t" .. encode_json({
				ok = true,
				exec_command = "echo fallback-action",
				exec_argv = { "echo", "fallback-action" },
				system_argv = { "zig/zig-out/bin/zignite", "--argv", "echo", "fallback-action" },
				config_revision = config.revision,
			}),
		}
	end

	local ok, resolved = pcall(
		build_resolve.resolve_action_sync,
		"/tmp/zignite-fallback/build.zig",
		"zig",
		"named",
		"build",
		nil,
		nil
	)

	action_client.sync_request = original_sync_request
	action_client.once_request = original_once_request

	assert(ok, resolved)
	assert(type(resolved) == "table", "expected fallback build action result")
	assert(resolved.exec_command == "echo fallback-action",
		"build action resolve should fall back to once_request in sync mode")
	assert(type(resolved.system_argv) == "table" and resolved.system_argv[2] == "--argv",
		"build action fallback should preserve system argv")

	reset_job_results()
	print("✓ Build action sync fallback test passed")
end

local function test_build_action_interactive_retries_with_prompted_arguments()
	config.setup({
		build_commands = {
			zig = {
				fetch = "zig fetch $zignite_args",
			},
		},
	})

	local build_rpc = require("zignite.rpc.build_resolve")
	local prompted = nil
	local plan = build_rpc.resolve_action_interactive(
		"/tmp/zignite-build/build.zig",
		"zig",
		"named",
		"fetch",
		nil,
		function(prompt_plan, current_args)
			assert(type(prompt_plan) == "table" and prompt_plan.requires_arguments == true,
				"interactive build action should surface backend prompt metadata")
			assert(current_args == nil, "first interactive build prompt should not invent arguments")
			prompted = true
			return "owner/repo"
		end
	)

	assert(prompted == true, "interactive build action should call the prompt callback when arguments are required")
	assert(type(plan) == "table" and plan.ok == true, "interactive build action should return a resolved plan after prompting")
	assert(plan.exec_command == "zig fetch --save git+https://github.com/owner/repo",
		"interactive build action should retry resolution with the prompted arguments")

	reset_job_results()
	print("✓ Build action interactive retry test passed")
end

local function test_build_action_interactive_reports_structured_cancellation()
	config.setup({
		build_commands = {
			zig = {
				fetch = "zig fetch $zignite_args",
			},
		},
	})

	local build_rpc = require("zignite.rpc.build_resolve")
	local plan = build_rpc.resolve_action_interactive(
		"/tmp/zignite-build/build.zig",
		"zig",
		"named",
		"fetch",
		nil,
		function(prompt_plan, current_args)
			assert(type(prompt_plan) == "table" and prompt_plan.requires_arguments == true,
				"interactive build action should still surface backend prompt metadata before cancellation")
			assert(current_args == nil, "cancelled prompt should not invent arguments")
			return false
		end
	)

	assert(type(plan) == "table", "interactive build action cancellation should return a structured result")
	assert(plan.ok == false, "cancelled interactive build action should report ok=false")
	assert(plan.reason == "cancelled", "cancelled interactive build action should use structured cancellation reason")

	reset_job_results()
	print("✓ Build action interactive cancellation test passed")
end

local function test_run_resolve_typescript_without_package_json_uses_configured_runner()
	config.setup({
		runners = {
			typescript = "bun $file",
		},
	})

	os.execute("mkdir -p /tmp/zignite-run >/dev/null 2>&1")
	local handle = assert(io.open("/tmp/zignite-run/demo.ts", "w"))
	handle:write("console.log(1)\n")
	handle:close()

	local resolved = run_resolve.resolve_sync("/tmp/zignite-run/demo.ts", "typescript")
	assert(
		type(resolved) == "table",
		"run_resolve should still return a configured TypeScript runner without package.json"
	)
	assert(resolved.command == "bun '/tmp/zignite-run/demo.ts'",
		"run_resolve should use the configured TypeScript runner when no package.json is present")
	assert(type(resolved.argv) == "table" and resolved.argv[1] == "bun",
		"run_resolve should still materialize argv for the configured TypeScript runner")
	assert(resolved.argv[2] == "/tmp/zignite-run/demo.ts",
		"run_resolve should preserve the TypeScript file path in argv")

	os.remove("/tmp/zignite-run/demo.ts")
	os.execute("rmdir /tmp/zignite-run >/dev/null 2>&1")
	reset_job_results()
	print("✓ Run resolve TypeScript fallback test passed")
end

local function test_run_resolve_python_conda_without_env_name_uses_project_runner()
	config.setup({
		runners = {
			python = "python3 -u $file",
		},
	})

	local root = "/tmp/zignite-conda-run"
	os.execute("mkdir -p " .. root .. "/app >/dev/null 2>&1")

	local env_file = assert(io.open(root .. "/environment.yml", "w"))
	env_file:write(table.concat({
		"dependencies:",
		"  - python=3.12",
		"  - pytest",
	}, "\n"))
	env_file:write("\n")
	env_file:close()

	local source = assert(io.open(root .. "/app/main.py", "w"))
	source:write("print('hi')\n")
	source:close()

	local resolved = run_resolve.resolve_sync(root .. "/app/main.py", "python")
	assert(type(resolved) == "table", "expected run resolve result for conda python source")
	assert(resolved.command == "conda run python -m main",
		"run_resolve should prefer the unnamed conda project command over the generic python runner")
	assert(type(resolved.argv) == "table" and resolved.argv[1] == "conda",
		"run_resolve should materialize argv for the conda project runner")
	assert(resolved.argv[2] == "run", "run_resolve should preserve conda run in argv")
	assert(resolved.argv[3] == "python", "run_resolve should preserve python invocation in argv")

	os.remove(root .. "/app/main.py")
	os.remove(root .. "/environment.yml")
	os.execute("rmdir " .. root .. "/app >/dev/null 2>&1")
	os.execute("rmdir " .. root .. " >/dev/null 2>&1")

	reset_job_results()
	print("✓ Run resolve unnamed conda fallback test passed")
end

local function test_run_resolve_go_keeps_single_file_runner_inside_module()
	config.setup({
		runners = {
			go = "go run $file",
		},
	})

	local root = "/tmp/zignite-go-run"
	os.execute("mkdir -p " .. root .. "/cmd/api >/dev/null 2>&1")

	local mod = assert(io.open(root .. "/go.mod", "w"))
	mod:write("module github.com/example/demo\n\ngo 1.23\n")
	mod:close()

	local source = assert(io.open(root .. "/cmd/api/main.go", "w"))
	source:write(table.concat({
		"package main",
		"",
		'import "fmt"',
		"",
		"func main() {",
		'    fmt.Println("hi")',
		"}",
	}, "\n"))
	source:write("\n")
	source:close()

	local path = root .. "/cmd/api/main.go"
	local resolved = run_resolve.resolve_sync(path, "go")
	assert(type(resolved) == "table", "expected run resolve result for go source")
	assert(resolved.command == "go run '" .. path .. "'",
		"run_resolve should keep the configured single-file go runner inside go modules")
	assert(type(resolved.argv) == "table" and resolved.argv[1] == "go",
		"run_resolve should materialize argv for the single-file go runner")
	assert(resolved.argv[2] == "run", "run_resolve should preserve the go run argv")
	assert(resolved.argv[3] == path, "run_resolve should preserve the source path in argv")

	os.remove(root .. "/cmd/api/main.go")
	os.remove(root .. "/go.mod")
	os.execute("rmdir " .. root .. "/cmd/api >/dev/null 2>&1")
	os.execute("rmdir " .. root .. "/cmd >/dev/null 2>&1")
	os.execute("rmdir " .. root .. " >/dev/null 2>&1")

	reset_job_results()
	print("✓ Run resolve Go single-file runner test passed")
end

local function test_run_resolve_zig_keeps_single_file_runner_inside_project()
	config.setup({
		runners = {
			zig = "zig run $file",
		},
	})

	local root = "/tmp/zignite-zig-run"
	os.execute("mkdir -p " .. root .. "/src >/dev/null 2>&1")

	local build_file = assert(io.open(root .. "/build.zig", "w"))
	build_file:write("pub fn build(b: *std.Build) void { _ = b; }\n")
	build_file:close()

	local source = assert(io.open(root .. "/src/main.zig", "w"))
	source:write("pub fn main() void {}\n")
	source:close()

	local path = root .. "/src/main.zig"
	local resolved = run_resolve.resolve_sync(path, "zig")
	assert(type(resolved) == "table", "expected run resolve result for zig source")
	assert(resolved.command == "zig run '" .. path .. "'",
		"run_resolve should keep the configured single-file zig runner inside zig projects")
	assert(type(resolved.argv) == "table" and resolved.argv[1] == "zig",
		"run_resolve should materialize argv for the single-file zig runner")
	assert(resolved.argv[2] == "run", "run_resolve should preserve the zig run argv")
	assert(resolved.argv[3] == path, "run_resolve should preserve the source path in argv")

	os.remove(root .. "/src/main.zig")
	os.remove(root .. "/build.zig")
	os.execute("rmdir " .. root .. "/src >/dev/null 2>&1")
	os.execute("rmdir " .. root .. " >/dev/null 2>&1")

	reset_job_results()
	print("✓ Run resolve Zig single-file runner test passed")
end

local function test_run_resolve_zig_prefers_project_runner_for_build_modules()
	config.setup({
		runners = {
			zig = "zig run $file",
		},
	})

	local root = "/tmp/zignite-zig-project-run"
	os.execute("mkdir -p " .. root .. "/src >/dev/null 2>&1")

	local build_file = assert(io.open(root .. "/build.zig", "w"))
	build_file:write("pub fn build(b: *std.Build) void { _ = b; }\n")
	build_file:close()

	local source = assert(io.open(root .. "/src/main.zig", "w"))
	source:write(table.concat({
		'const zig = @import("zig");',
		"pub fn main() void {",
		"    _ = zig;",
		"}",
	}, "\n"))
	source:write("\n")
	source:close()

	local path = root .. "/src/main.zig"
	local resolved = run_resolve.resolve_sync(path, "zig")
	assert(type(resolved) == "table", "expected run resolve result for zig project source")
	assert(resolved.command == "zig build run",
		"run_resolve should prefer the project zig runner when the source imports build-defined modules")
	assert(type(resolved.argv) == "table" and resolved.argv[1] == "zig",
		"run_resolve should materialize argv for the zig project runner")
	assert(resolved.argv[2] == "build", "run_resolve should preserve zig build argv")
	assert(resolved.argv[3] == "run", "run_resolve should preserve the zig project run step")
	assert(resolved.cwd == root, "run_resolve should use the zig project root as cwd")

	os.remove(root .. "/src/main.zig")
	os.remove(root .. "/build.zig")
	os.execute("rmdir " .. root .. "/src >/dev/null 2>&1")
	os.execute("rmdir " .. root .. " >/dev/null 2>&1")

	reset_job_results()
	print("✓ Run resolve Zig project-module runner test passed")
end

local function test_run_resolve_zig_ignores_quoted_build_module_imports()
	config.setup({
		runners = {
			zig = "zig run $file",
		},
	})

	local root = "/tmp/zignite-zig-commented-import"
	os.execute("mkdir -p " .. root .. "/src >/dev/null 2>&1")

	local build_file = assert(io.open(root .. "/build.zig", "w"))
	build_file:write("pub fn build(b: *std.Build) void { _ = b; }\n")
	build_file:close()

	local source = assert(io.open(root .. "/src/main.zig", "w"))
	source:write(table.concat({
		'// @import("zig")',
		'const text = "@import(\\"zig\\")";',
		"const multi =",
		'    \\\\@import("zig")',
		";",
		"pub fn main() void {",
		"    _ = text;",
		"    _ = multi;",
		"}",
	}, "\n"))
	source:write("\n")
	source:close()

	local path = root .. "/src/main.zig"
	local resolved = run_resolve.resolve_sync(path, "zig")
	assert(type(resolved) == "table", "expected run resolve result for zig source with quoted import markers")
	assert(resolved.command == "zig run '" .. path .. "'",
		"run_resolve should keep the single-file zig runner when build-module imports only appear in comments or strings")
	assert(type(resolved.argv) == "table" and resolved.argv[1] == "zig",
		"run_resolve should materialize argv for the single-file zig runner")
	assert(resolved.argv[2] == "run", "run_resolve should preserve the zig run argv")
	assert(resolved.argv[3] == path, "run_resolve should preserve the source path in argv")

	os.remove(root .. "/src/main.zig")
	os.remove(root .. "/build.zig")
	os.execute("rmdir " .. root .. "/src >/dev/null 2>&1")
	os.execute("rmdir " .. root .. " >/dev/null 2>&1")

	reset_job_results()
	print("✓ Run resolve Zig false-positive import test passed")
end

local function test_build_resolve_cpp_in_bazel_workspace_uses_bazel_commands()
	local root = "/tmp/zignite-bazel-cpp"
	os.execute("mkdir -p " .. root .. "/app >/dev/null 2>&1")

	local module_file = assert(io.open(root .. "/MODULE.bazel", "w"))
	module_file:write("\n")
	module_file:close()

	local build_file = assert(io.open(root .. "/app/BUILD.bazel", "w"))
	build_file:write(table.concat({
		"cc_binary(",
		'    name = "main",',
		'    srcs = ["main.cc"],',
		")",
	}, "\n"))
	build_file:write("\n")
	build_file:close()

	local source = assert(io.open(root .. "/app/main.cc", "w"))
	source:write("int main() { return 0; }\n")
	source:close()

	local resolved = build_resolve.resolve_sync(root .. "/app/main.cc", "cpp")
	assert(type(resolved) == "table", "expected build resolve result for bazel cpp source")
	assert(resolved.system == "bazel", "expected bazel system for cpp file inside bazel workspace")
	assert(type(resolved.commands) == "table", "expected command map for bazel cpp source")
	assert(type(resolved.commands.build) == "string" and resolved.commands.build:match("^bazel build //"),
		"expected primary bazel build command for cpp source in bazel workspace")
	assert(
		type(resolved.commands["bazel-build"]) == "string"
			or type(resolved.commands["bazel-build-app-main"]) == "string"
			or type(resolved.commands["bazel-build-app"]) == "string",
		"expected at least one target-aware bazel build command for cpp source in bazel workspace"
	)
	for command_name, _ in pairs(resolved.commands) do
		assert(not command_name:match("^cmake%-"),
			"did not expect cmake commands for cpp source in bazel workspace")
		assert(not command_name:match("^meson%-"),
			"did not expect meson commands for cpp source in bazel workspace")
	end

	os.remove(root .. "/app/main.cc")
	os.remove(root .. "/app/BUILD.bazel")
	os.remove(root .. "/MODULE.bazel")
	os.execute("rmdir " .. root .. "/app >/dev/null 2>&1")
	os.execute("rmdir " .. root .. " >/dev/null 2>&1")

	reset_job_results()
	print("✓ Build resolve Bazel C++ detection test passed")
end

test_build_resolve_returns_command_metadata()
test_build_resolve_reports_backend_no_build_commands()
test_build_resolve_selected_command_materializes_execution()
test_build_resolve_exposes_preferred_live_name()
test_run_resolve_returns_backend_runner_payload()
test_run_code_uses_backend_execution_path_for_file_runs()
test_run_resolve_request_supports_selection_payload()
test_run_resolve_selection_supports_unsaved_buffers()
test_run_resolve_buffer_supports_unsaved_full_buffers()
test_run_code_supports_unsaved_buffers_via_backend_buffer()
test_run_resolve_saved_zig_file_with_wrong_extension_uses_backend_materialized_path()
test_run_code_saved_zig_buffer_with_wrong_extension_accepts_backend_path()
test_build_resolve_requires_completed_config_sync()
test_config_sync_request_includes_timeout()
test_config_sync_falls_back_to_one_shot_mode()
test_config_sync_surfaces_backend_validation_warnings()
test_build_resolve_sync_falls_back_to_once_request()
test_build_action_sync_falls_back_to_once_request()
test_build_action_interactive_retries_with_prompted_arguments()
test_build_action_interactive_reports_structured_cancellation()
test_run_resolve_reports_backend_no_runner_failure()
test_run_resolve_typescript_without_package_json_uses_configured_runner()
test_run_resolve_python_conda_without_env_name_uses_project_runner()
test_run_resolve_go_keeps_single_file_runner_inside_module()
test_run_resolve_zig_keeps_single_file_runner_inside_project()
test_run_resolve_zig_prefers_project_runner_for_build_modules()
test_run_resolve_zig_ignores_quoted_build_module_imports()
test_build_resolve_cpp_in_bazel_workspace_uses_bazel_commands()
