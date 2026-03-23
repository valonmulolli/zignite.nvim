-- luacheck: globals config init job_results command_to_string reset_job_results
-- luacheck: globals make_expand_override with_overrides

local function make_filereadable_override(readable_paths)
	local original_filereadable = vim.fn.filereadable
	local readable = {}
	for _, path in ipairs(readable_paths or {}) do
		readable[path] = true
	end
	return function(path)
		if readable[path] then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
end

local function make_bazel_systemlist_override(outputs)
	local original_systemlist = vim.fn.systemlist
	return function(cmd)
		vim.v.shell_error = 0
		if type(cmd) ~= "table" then
			if original_systemlist then
				return original_systemlist(cmd)
			end
			return {}
		end
		if cmd[2] ~= "--project-parse" or cmd[3] ~= "--kind=bazel-workspace" then
			if original_systemlist then
				return original_systemlist(cmd)
			end
			return {}
		end
		return outputs[cmd[4]] or {}
	end
end

local function capture_picker_lines(run_fn)
	local original_open_win = vim.api.nvim_open_win
	local original_buf_set_lines = vim.api.nvim_buf_set_lines
	local picker_opened = false
	local rendered_lines = {}

	with_overrides({
		{
			tbl = vim.api,
			key = "nvim_open_win",
			value = function(...)
				picker_opened = true
				return original_open_win(...)
			end,
		},
		{
			tbl = vim.api,
			key = "nvim_buf_set_lines",
			value = function(buf, start_idx, end_idx, strict, lines)
				if type(lines) == "table" and #lines > 0 then
					rendered_lines = lines
				end
				if original_buf_set_lines then
					return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
				end
			end,
		},
	}, run_fn)

	return picker_opened, rendered_lines
end

local function with_bazel_context(opts, fn)
	local overrides = {
		{ tbl = vim.bo, key = "filetype", value = opts.filetype or "cpp" },
		{ tbl = vim.fn, key = "expand", value = make_expand_override(opts.filepath) },
		{
			tbl = vim.fn,
			key = "filereadable",
			value = make_filereadable_override(opts.readable_paths),
		},
	}

	if opts.systemlist then
		overrides[#overrides + 1] = { tbl = vim.fn, key = "systemlist", value = opts.systemlist }
	end
	if opts.readfile then
		overrides[#overrides + 1] = { tbl = vim.fn, key = "readfile", value = opts.readfile }
	end
	if opts.input then
		overrides[#overrides + 1] = { tbl = vim.fn, key = "input", value = opts.input }
	end

	with_overrides(overrides, fn)
end

local function test_bazel_project_commands_in_picker()
	init.setup({ build_commands = {} })

	local picker_opened = false
	local rendered_lines = {}
	local commands = {}
	with_bazel_context({
		filepath = "/tmp/bazelapp/app/main.cc",
		readable_paths = {
			"/tmp/bazelapp/MODULE.bazel",
			"/tmp/bazelapp/app/BUILD.bazel",
		},
		systemlist = make_bazel_systemlist_override({
			["--path=/tmp/bazelapp"] = {
				"COMMAND\tbazel-query\tbazel query $zignite_args",
				"COMMAND\tbazel-clean\tbazel clean",
				"COMMAND\tbazel-build-all\tbazel build //...",
				"COMMAND\tbazel-test-all\tbazel test //...",
				"COMMAND\tbazel-build-main\tbazel build //app:main",
				"COMMAND\tbazel-run-main\tbazel run //app:main",
				"COMMAND\tbazel-build\tbazel build //app:main",
				"COMMAND\tbazel-run\tbazel run //app:main",
				"COMMAND\tbuild\tbazel build //app:main",
				"COMMAND\trun\tbazel run //app:main",
				"PRIMARY_BUILD\tbazel build //app:main",
				"PRIMARY_RUN\tbazel run //app:main",
				"PREFERRED\tbuild\tbazel build //app:main",
				"PREFERRED\trun\tbazel run //app:main",
			},
		}),
		readfile = function()
			error("Lua Bazel fallback parser should not read BUILD files")
		end,
	}, function()
		commands = require("zignite.build.project_backend").detect_bazel_project_commands(
			"/tmp/bazelapp/app/main.cc"
		)
		picker_opened, rendered_lines = capture_picker_lines(function()
			init.select_build_command("float")
		end)
	end)

	assert(picker_opened, "Picker should open for Bazel workspace commands")
	assert(commands["bazel-query"] == "bazel query $zignite_args", "Backend Bazel query command should be exposed")
	assert(commands["bazel-clean"] == "bazel clean", "Backend Bazel clean command should be exposed")
	local rendered = table.concat(rendered_lines, "\n")
	assert(rendered:match("bazel%-build"), "Picker should include bazel-build command")
	assert(rendered:match("bazel%-run"), "Picker should include bazel-run command")
	assert(
		not rendered:match("bazel build <%a+>"),
		"Backend Bazel build should use inferred labels instead of placeholder args"
	)

	print("✓ Bazel project commands in picker test passed")
end

local function test_run_build_command_with_detected_bazel_command()
	init.setup({ build_commands = {} })

	local prompts = {}
	with_bazel_context({
		filepath = "/tmp/bazelapp/app/main.cc",
		readable_paths = {
			"/tmp/bazelapp/MODULE.bazel",
			"/tmp/bazelapp/app/BUILD.bazel",
		},
		systemlist = make_bazel_systemlist_override({
			["--path=/tmp/bazelapp"] = {
				"COMMAND\tbazel-query\tbazel query $zignite_args",
				"COMMAND\tbazel-clean\tbazel clean",
				"COMMAND\tbazel-build-all\tbazel build //...",
				"COMMAND\tbazel-test-all\tbazel test //...",
				"COMMAND\tbazel-build-main\tbazel build //app:main",
				"COMMAND\tbazel-run-main\tbazel run //app:main",
				"COMMAND\tbazel-build\tbazel build //app:main",
				"COMMAND\tbazel-run\tbazel run //app:main",
				"COMMAND\tbuild\tbazel build //app:main",
				"COMMAND\trun\tbazel run //app:main",
				"PRIMARY_BUILD\tbazel build //app:main",
				"PRIMARY_RUN\tbazel run //app:main",
				"PREFERRED\tbuild\tbazel build //app:main",
				"PREFERRED\trun\tbazel run //app:main",
			},
		}),
		readfile = function()
			error("Lua Bazel fallback parser should not read BUILD files")
		end,
		input = function(prompt, _default)
			prompts[#prompts + 1] = prompt
			return "//app:main"
		end,
	}, function()
		reset_job_results()
		init.run_build_command("bazel-build", "float")
	end)

	assert(#job_results > 0, "Backend Bazel build should start a job")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel build"), "Generic Bazel command should execute via bazel build")
	assert(command:match("//app:main"), "Backend Bazel command should include inferred target label")
	assert(#prompts == 0, "Backend Bazel command should not prompt when Zig inferred the label")
	reset_job_results()

	print("✓ RunBuild with detected Bazel command test passed")
end

local function test_bazel_targets_use_zig_project_parser()
	init.setup({ build_commands = {} })

	local rendered_lines = {}
	with_bazel_context({
		filepath = "/tmp/bazelzig/app/main.cc",
		readable_paths = {
			"/tmp/bazelzig/MODULE.bazel",
			"/tmp/bazelzig/app/BUILD.bazel",
		},
		systemlist = make_bazel_systemlist_override({
			["--path=/tmp/bazelzig"] = {
				"COMMAND\tbazel-query\tbazel query $zignite_args",
				"COMMAND\tbazel-clean\tbazel clean",
				"COMMAND\tbazel-build-all\tbazel build //...",
				"COMMAND\tbazel-test-all\tbazel test //...",
				"COMMAND\tbazel-build-main\tbazel build //app:main",
				"COMMAND\tbazel-run-main\tbazel run //app:main",
				"COMMAND\tbazel-build\tbazel build //app:main",
				"COMMAND\tbazel-run\tbazel run //app:main",
				"COMMAND\tbuild\tbazel build //app:main",
				"COMMAND\trun\tbazel run //app:main",
				"COMMAND\tbazel-build-main_test\tbazel build //app:main_test",
				"COMMAND\tbazel-test-main_test\tbazel test //app:main_test",
				"PRIMARY_BUILD\tbazel build //app:main",
				"PRIMARY_RUN\tbazel run //app:main",
				"PREFERRED\tbuild\tbazel build //app:main",
				"PREFERRED\trun\tbazel run //app:main",
			},
		}),
		readfile = function()
			error("Lua Bazel parser should not be used when Zig parser succeeds")
		end,
	}, function()
		local commands = require("zignite.build.project_backend").detect_bazel_project_commands("/tmp/bazelzig/app/main.cc")
		assert(commands.build == "bazel build //app:main", "Zig Bazel parser should expose preferred generic build")
		assert(commands.run == "bazel run //app:main", "Zig Bazel parser should expose preferred generic run")
		local picker_opened
		picker_opened, rendered_lines = capture_picker_lines(function()
			init.select_build_command("float")
		end)
		assert(picker_opened, "Picker should open for Zig Bazel parser commands")
	end)

	local rendered = table.concat(rendered_lines, "\n")
	assert(rendered:match("bazel%-build%-main"), "Zig Bazel parser should expose target-specific build command")
	assert(rendered:match("bazel%-run%-main"), "Zig Bazel parser should expose target-specific run command")
	assert(rendered:match("bazel test //app:main_test"), "Zig Bazel parser should expose target-specific test command")
	assert(rendered:match("bazel run //app:main"), "Zig Bazel parser should infer the primary run target")
	assert(not rendered:match("bazel run <%a+>"), "Inferred Zig Bazel run should not render placeholder args")

	print("✓ Zig Bazel parser test passed")
end

local function test_run_build_command_with_inferred_bazel_target()
	init.setup({ build_commands = {} })

	local prompts = {}
	with_bazel_context({
		filepath = "/tmp/bazelzig/app/main.cc",
		readable_paths = {
			"/tmp/bazelzig/MODULE.bazel",
			"/tmp/bazelzig/app/BUILD.bazel",
		},
		systemlist = make_bazel_systemlist_override({
			["--path=/tmp/bazelzig"] = {
				"COMMAND\tbazel-query\tbazel query $zignite_args",
				"COMMAND\tbazel-clean\tbazel clean",
				"COMMAND\tbazel-build-all\tbazel build //...",
				"COMMAND\tbazel-test-all\tbazel test //...",
				"COMMAND\tbazel-build-main\tbazel build //app:main",
				"COMMAND\tbazel-run-main\tbazel run //app:main",
				"COMMAND\tbazel-build\tbazel build //app:main",
				"COMMAND\tbazel-run\tbazel run //app:main",
				"COMMAND\tbuild\tbazel build //app:main",
				"COMMAND\trun\tbazel run //app:main",
				"PRIMARY_BUILD\tbazel build //app:main",
				"PRIMARY_RUN\tbazel run //app:main",
				"PREFERRED\tbuild\tbazel build //app:main",
				"PREFERRED\trun\tbazel run //app:main",
			},
		}),
		input = function(prompt, default_value)
			prompts[#prompts + 1] = prompt
			return default_value or ""
		end,
	}, function()
		reset_job_results()
		init.run_build_command("bazel-run", "float")
	end)

	assert(#job_results > 0, "Inferred Zig Bazel run should start a job")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel run //app:main"), "Inferred Zig Bazel run should execute concrete label")
	assert(#prompts == 0, "Inferred Zig Bazel run should not prompt for args")
	reset_job_results()

	print("✓ Inferred Bazel run command test passed")
end

local function test_detected_bazel_preferred_run_alias()
	init.setup({ build_commands = {} })

	with_bazel_context({
		filepath = "/tmp/bazelzig/app/main.cc",
		readable_paths = {
			"/tmp/bazelzig/MODULE.bazel",
			"/tmp/bazelzig/app/BUILD.bazel",
		},
		systemlist = make_bazel_systemlist_override({
			["--path=/tmp/bazelzig"] = {
				"COMMAND\tbazel-query\tbazel query $zignite_args",
				"COMMAND\tbazel-clean\tbazel clean",
				"COMMAND\tbazel-build-all\tbazel build //...",
				"COMMAND\tbazel-test-all\tbazel test //...",
				"COMMAND\tbazel-build-main\tbazel build //app:main",
				"COMMAND\tbazel-run-main\tbazel run //app:main",
				"COMMAND\tbazel-build\tbazel build //app:main",
				"COMMAND\tbazel-run\tbazel run //app:main",
				"COMMAND\tbuild\tbazel build //app:main",
				"COMMAND\trun\tbazel run //app:main",
				"PREFERRED\tbuild\tbazel build //app:main",
				"PREFERRED\trun\tbazel run //app:main",
			},
		}),
	}, function()
		local build = require("zignite.build")
		local commands = build.get_build_commands_for_filetype("cpp", "/tmp/bazelzig/app/main.cc")
		assert(commands.run == "bazel run //app:main", "Generic Bazel run should follow Zig-preferred run command")
	end)

	reset_job_results()

	print("✓ Generic Bazel run alias test passed")
end

local function test_bazel_related_test_inference()
	init.setup({ build_commands = {} })

	local prompts = {}
	with_bazel_context({
		filepath = "/tmp/bazeltests/app/foo.cc",
		readable_paths = {
			"/tmp/bazeltests/MODULE.bazel",
			"/tmp/bazeltests/app/BUILD.bazel",
		},
		systemlist = make_bazel_systemlist_override({
			["--path=/tmp/bazeltests"] = {
				"COMMAND\tbazel-query\tbazel query $zignite_args",
				"COMMAND\tbazel-clean\tbazel clean",
				"COMMAND\tbazel-build-all\tbazel build //...",
				"COMMAND\tbazel-test-all\tbazel test //...",
				"COMMAND\tbazel-build-foo_lib\tbazel build //app:foo_lib",
				"COMMAND\tbazel-build-foo_test\tbazel build //app:foo_test",
				"COMMAND\tbazel-test-foo_test\tbazel test //app:foo_test",
				"COMMAND\tbazel-test\tbazel test //app:foo_test",
				"COMMAND\ttest\tbazel test //app:foo_test",
				"PRIMARY_TEST\tbazel test //app:foo_test",
				"PREFERRED\ttest\tbazel test //app:foo_test",
			},
		}),
		input = function(prompt, default_value)
			prompts[#prompts + 1] = prompt
			return default_value or ""
		end,
	}, function()
		reset_job_results()
		init.run_build_command("bazel-test", "float")
	end)

	assert(#job_results > 0, "Related Zig Bazel test should start a job")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel test //app:foo_test"), "Related Zig Bazel test should infer test target")
	assert(#prompts == 0, "Related Zig Bazel test should not prompt for args")
	reset_job_results()

	print("✓ Bazel related test inference test passed")
end

local function test_bazel_parent_package_inference()
	init.setup({ build_commands = {} })

	local prompts = {}
	with_bazel_context({
		filepath = "/tmp/bazelparent/app/main.cc",
		readable_paths = {
			"/tmp/bazelparent/MODULE.bazel",
			"/tmp/bazelparent/app/BUILD.bazel",
			"/tmp/bazelparent/BUILD.bazel",
		},
		systemlist = make_bazel_systemlist_override({
			["--path=/tmp/bazelparent"] = {
				"COMMAND\tbazel-query\tbazel query $zignite_args",
				"COMMAND\tbazel-clean\tbazel clean",
				"COMMAND\tbazel-build-all\tbazel build //...",
				"COMMAND\tbazel-test-all\tbazel test //...",
				"COMMAND\tbazel-build-root_app\tbazel build //:root_app",
				"COMMAND\tbazel-run-root_app\tbazel run //:root_app",
				"COMMAND\tbazel-build\tbazel build //:root_app",
				"COMMAND\tbazel-run\tbazel run //:root_app",
				"COMMAND\tbuild\tbazel build //:root_app",
				"COMMAND\trun\tbazel run //:root_app",
				"PRIMARY_BUILD\tbazel build //:root_app",
				"PRIMARY_RUN\tbazel run //:root_app",
				"PREFERRED\tbuild\tbazel build //:root_app",
				"PREFERRED\trun\tbazel run //:root_app",
			},
		}),
		input = function(prompt, default_value)
			prompts[#prompts + 1] = prompt
			return default_value or ""
		end,
	}, function()
		reset_job_results()
		init.run_build_command("bazel-run", "float")
	end)

	assert(#job_results > 0, "Parent-package Zig Bazel run should start a job")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel run //:root_app"), "Parent-package Zig Bazel run should infer root package target")
	assert(#prompts == 0, "Parent-package Zig Bazel run should not prompt for args")
	reset_job_results()

	print("✓ Bazel parent package inference test passed")
end

test_bazel_project_commands_in_picker()
test_run_build_command_with_detected_bazel_command()
test_bazel_targets_use_zig_project_parser()
test_run_build_command_with_inferred_bazel_target()
test_detected_bazel_preferred_run_alias()
test_bazel_related_test_inference()
test_bazel_parent_package_inference()
