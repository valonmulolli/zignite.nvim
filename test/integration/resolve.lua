-- luacheck: globals project_root config reset_job_results

local build_resolve = require("zignite.backend.build_resolve")
local run_resolve = require("zignite.backend.run_resolve")

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
	assert(resolved.commands.fetch == "zig fetch $zignite_args", "build_resolve should include configured command")
	assert(type(resolved.command_meta) == "table" and type(resolved.command_meta.fetch) == "table",
		"build_resolve should include command metadata")
	assert(resolved.command_meta.fetch.display_command == "zig fetch <args>",
		"build_resolve should expose display command metadata")
	assert(resolved.command_meta.fetch.requires_arguments == true,
		"build_resolve should mark placeholder commands as requiring arguments")
	assert(resolved.command_meta.fetch.argument_prompt == "zig fetch url/path",
		"build_resolve should expose backend prompt text")
	assert(resolved.config_revision == config.revision, "build_resolve should report the synced config revision")

	reset_job_results()
	print("✓ Build resolve metadata test passed")
end

local function test_build_resolve_selected_command_materializes_execution()
	config.setup({
		build_commands = {
			zig = {
				fetch = "zig fetch $zignite_args",
			},
		},
	})

	local resolved = build_resolve.resolve_command_sync(
		"/tmp/zignite-build/build.zig",
		"zig",
		"fetch",
		"owner/repo"
	)
	assert(type(resolved) == "table", "resolve_command_sync should return a table")
	assert(
		resolved.exec_command == "zig fetch --save git+https://github.com/owner/repo",
		"resolve_command_sync should materialize the backend command"
	)
	assert(resolved.name == "zig: fetch", "resolve_command_sync should expose execution display name")
	assert(resolved.cwd == "/tmp/zignite-build", "resolve_command_sync should expose backend cwd")

	reset_job_results()
	print("✓ Build resolve command materialization test passed")
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
	assert(resolved.source == "filetype", "run_resolve should report the runner source")
	assert(resolved.filetype == "python", "run_resolve should report the resolved filetype")
	assert(resolved.name == "python", "run_resolve should expose backend runner name")

	reset_job_results()
	print("✓ Run resolve payload test passed")
end

test_build_resolve_returns_command_metadata()
test_build_resolve_selected_command_materializes_execution()
test_run_resolve_returns_backend_runner_payload()
