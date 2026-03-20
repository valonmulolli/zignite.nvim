-- luacheck: globals project_root config init ui state job_results quickfix_results notify_results mock_jobs
-- luacheck: globals command_to_string reset_job_results reset_quickfix_results reset_notify_results
-- luacheck: globals count_quickfix_backend_jobs count_quickfix_daemon_jobs
-- luacheck: globals count_detect_backend_jobs count_detect_backend_requests
-- luacheck: globals get_upvalue_by_name detect_backend_tool_commands is_detect_daemon_cmd parse_detect_daemon_request

-- Test Bazel workspace commands appear in picker and prompt-aware commands render placeholders.
local function test_bazel_project_commands_in_picker()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "cpp"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_open_win = vim.api.nvim_open_win
	local original_buf_set_lines = vim.api.nvim_buf_set_lines
	local picker_opened = false
	local rendered_lines = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazelapp/src/main.cc"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazelapp/MODULE.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.api.nvim_open_win = function(...)
		picker_opened = true
		return original_open_win(...)
	end
	vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
		if type(lines) == "table" and #lines > 0 then
			rendered_lines = lines
		end
		if original_buf_set_lines then
			return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
		end
	end

	init.select_build_command("float")

	assert(picker_opened, "Picker should open for detected Bazel workspace commands")
	local rendered = table.concat(rendered_lines, "\n")
	assert(rendered:match("bazel%-build"), "Picker should include bazel-build command")
	assert(rendered:match("bazel%-run"), "Picker should include bazel-run command")
	assert(rendered:match("bazel build <%a+>"), "Bazel placeholder command should render <args>")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.api.nvim_open_win = original_open_win
	vim.api.nvim_buf_set_lines = original_buf_set_lines

	print("✓ Bazel project commands in picker test passed")
end

-- Test Bazel command execution prompts for target arguments.
local function test_run_build_command_with_detected_bazel_command()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "cpp"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_input = vim.fn.input
	local prompts = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazelapp/src/main.cc"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazelapp/MODULE.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.input = function(prompt, _default)
		prompts[#prompts + 1] = prompt
		return "//app:main"
	end

	reset_job_results()
	init.run_build_command("bazel-build", "float")
	assert(#job_results > 0, "Detected Bazel command should start a job after prompting for target")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel build"), "Detected Bazel command should execute via bazel build")
	assert(command:match("//app:main"), "Detected Bazel command should include provided target argument")
	assert(#prompts == 1 and prompts[1]:match("cpp bazel%-build args"), "Bazel command should prompt for target argument")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.input = original_input
	reset_job_results()

	print("✓ RunBuild with detected Bazel command test passed")
end

-- Test Bazel BUILD parsing infers a concrete target for the current file.
local function test_bazel_target_inference_in_picker()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "cpp"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local original_open_win = vim.api.nvim_open_win
	local original_buf_set_lines = vim.api.nvim_buf_set_lines
	local picker_opened = false
	local rendered_lines = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazelapp/app/main.cc"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazelapp/MODULE.bazel" or path == "/tmp/bazelapp/app/BUILD.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path)
		if path == "/tmp/bazelapp/app/BUILD.bazel" then
			return {
				'cc_binary(',
				'    name = "main",',
				'    srcs = ["main.cc"],',
				')',
			}
		end
		if original_readfile then
			return original_readfile(path)
		end
		return {}
	end
	vim.api.nvim_open_win = function(...)
		picker_opened = true
		return original_open_win(...)
	end
	vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
		if type(lines) == "table" and #lines > 0 then
			rendered_lines = lines
		end
		if original_buf_set_lines then
			return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
		end
	end

	init.select_build_command("float")

	assert(picker_opened, "Picker should open for inferred Bazel target commands")
	local rendered = table.concat(rendered_lines, "\n")
	assert(rendered:match("bazel%-run%-main"), "Picker should include target-specific Bazel run command")
	assert(rendered:match("bazel run //app:main"), "Picker should render inferred Bazel label")
	assert(not rendered:match("bazel run <%a+>"), "Inferred Bazel run command should not render placeholder args")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile
	vim.api.nvim_open_win = original_open_win
	vim.api.nvim_buf_set_lines = original_buf_set_lines

	print("✓ Bazel target inference in picker test passed")
end

-- Test Bazel run uses inferred target without prompting for args.
local function test_run_build_command_with_inferred_bazel_target()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "cpp"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local original_input = vim.fn.input
	local prompts = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazelapp/app/main.cc"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazelapp/MODULE.bazel" or path == "/tmp/bazelapp/app/BUILD.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path)
		if path == "/tmp/bazelapp/app/BUILD.bazel" then
			return {
				'cc_binary(',
				'    name = "main",',
				'    srcs = ["main.cc"],',
				')',
			}
		end
		if original_readfile then
			return original_readfile(path)
		end
		return {}
	end
	vim.fn.input = function(prompt, default_value)
		prompts[#prompts + 1] = prompt
		return default_value or ""
	end

	reset_job_results()
	init.run_build_command("bazel-run", "float")

	assert(#job_results > 0, "Inferred Bazel run should start a job")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel run //app:main"), "Inferred Bazel run should execute concrete label")
	assert(#prompts == 0, "Inferred Bazel run should not prompt for args")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile
	vim.fn.input = original_input
	reset_job_results()

	print("✓ Inferred Bazel run command test passed")
end

-- Test Bazel infers a target when BUILD uses glob() for sources.
local function test_bazel_glob_target_inference()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "cpp"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local original_input = vim.fn.input
	local prompts = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazelglob/app/main.cc"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazelglob/MODULE.bazel" or path == "/tmp/bazelglob/app/BUILD.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path)
		if path == "/tmp/bazelglob/app/BUILD.bazel" then
			return {
				'cc_binary(',
				'    name = "glob_app",',
				'    srcs = glob(["*.cc"]),',
				')',
			}
		end
		if original_readfile then
			return original_readfile(path)
		end
		return {}
	end
	vim.fn.input = function(prompt, default_value)
		prompts[#prompts + 1] = prompt
		return default_value or ""
	end

	reset_job_results()
	init.run_build_command("bazel-run", "float")

	assert(#job_results > 0, "Glob-based Bazel run should start a job")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel run //app:glob_app"), "Glob-based Bazel run should infer target label")
	assert(#prompts == 0, "Glob-based Bazel run should not prompt for args")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile
	vim.fn.input = original_input
	reset_job_results()

	print("✓ Bazel glob target inference test passed")
end

-- Test Bazel infers a related cc_test target for the current source file.
local function test_bazel_related_test_inference()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "cpp"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local original_input = vim.fn.input
	local prompts = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazeltests/app/foo.cc"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazeltests/MODULE.bazel" or path == "/tmp/bazeltests/app/BUILD.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path)
		if path == "/tmp/bazeltests/app/BUILD.bazel" then
			return {
				'cc_library(',
				'    name = "foo_lib",',
				'    srcs = ["foo.cc"],',
				')',
				'cc_test(',
				'    name = "foo_test",',
				'    srcs = ["foo_test.cc"],',
				')',
			}
		end
		if original_readfile then
			return original_readfile(path)
		end
		return {}
	end
	vim.fn.input = function(prompt, default_value)
		prompts[#prompts + 1] = prompt
		return default_value or ""
	end

	reset_job_results()
	init.run_build_command("bazel-test", "float")

	assert(#job_results > 0, "Related Bazel test should start a job")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel test //app:foo_test"), "Related Bazel test should infer test target")
	assert(#prompts == 0, "Related Bazel test should not prompt for args")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile
	vim.fn.input = original_input
	reset_job_results()

	print("✓ Bazel related test inference test passed")
end

-- Test Bazel can infer a target from a parent package BUILD file.
local function test_bazel_parent_package_inference()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "cpp"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local original_input = vim.fn.input
	local prompts = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazelparent/app/main.cc"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if
			path == "/tmp/bazelparent/MODULE.bazel"
			or path == "/tmp/bazelparent/BUILD.bazel"
			or path == "/tmp/bazelparent/app/BUILD.bazel"
		then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path)
		if path == "/tmp/bazelparent/app/BUILD.bazel" then
			return {
				'exports_files(["main.cc"])',
			}
		end
		if path == "/tmp/bazelparent/BUILD.bazel" then
			return {
				'cc_binary(',
				'    name = "root_app",',
				'    srcs = ["app/main.cc"],',
				')',
			}
		end
		if original_readfile then
			return original_readfile(path)
		end
		return {}
	end
	vim.fn.input = function(prompt, default_value)
		prompts[#prompts + 1] = prompt
		return default_value or ""
	end

	reset_job_results()
	init.run_build_command("bazel-run", "float")

	assert(#job_results > 0, "Parent-package Bazel run should start a job")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel run //:root_app"), "Parent-package Bazel run should infer root package target")
	assert(#prompts == 0, "Parent-package Bazel run should not prompt for args")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile
	vim.fn.input = original_input
	reset_job_results()

	print("✓ Bazel parent package inference test passed")
end

-- Test Bazel wrapper macro names still infer runnable targets.
local function test_bazel_wrapper_rule_inference()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "cpp"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local original_input = vim.fn.input
	local prompts = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazelmacro/app/main.cc"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazelmacro/MODULE.bazel" or path == "/tmp/bazelmacro/app/BUILD.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path)
		if path == "/tmp/bazelmacro/app/BUILD.bazel" then
			return {
				'wrapped_cc_binary(',
				'    name = "macro_app",',
				'    srcs = ["main.cc"],',
				')',
			}
		end
		if original_readfile then
			return original_readfile(path)
		end
		return {}
	end
	vim.fn.input = function(prompt, default_value)
		prompts[#prompts + 1] = prompt
		return default_value or ""
	end

	reset_job_results()
	init.run_build_command("bazel-run", "float")

	assert(#job_results > 0, "Wrapper-rule Bazel run should start a job")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel run //app:macro_app"), "Wrapper-rule Bazel run should infer wrapped binary target")
	assert(#prompts == 0, "Wrapper-rule Bazel run should not prompt for args")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile
	vim.fn.input = original_input
	reset_job_results()

	print("✓ Bazel wrapper rule inference test passed")
end

-- Test Bazel infers related Go test targets from *_test.go naming.
local function test_bazel_go_test_relationship_inference()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local original_input = vim.fn.input
	local prompts = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazelgo/app/foo.go"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazelgo/MODULE.bazel" or path == "/tmp/bazelgo/app/BUILD.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path)
		if path == "/tmp/bazelgo/app/BUILD.bazel" then
			return {
				'go_library(',
				'    name = "foo_lib",',
				'    srcs = ["foo.go"],',
				')',
				'go_test(',
				'    name = "foo_test",',
				'    srcs = ["foo_test.go"],',
				')',
			}
		end
		if original_readfile then
			return original_readfile(path)
		end
		return {}
	end
	vim.fn.input = function(prompt, default_value)
		prompts[#prompts + 1] = prompt
		return default_value or ""
	end

	reset_job_results()
	init.run_build_command("bazel-test", "float")

	assert(#job_results > 0, "Go-related Bazel test should start a job")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel test //app:foo_test"), "Go-related Bazel test should infer go_test target")
	assert(#prompts == 0, "Go-related Bazel test should not prompt for args")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile
	vim.fn.input = original_input
	reset_job_results()

	print("✓ Bazel Go test relationship inference test passed")
end

-- Test Bazel infers related Python test targets from test_*.py naming.
local function test_bazel_python_test_relationship_inference()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "python"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local original_input = vim.fn.input
	local prompts = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazelpy/app/main.py"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazelpy/MODULE.bazel" or path == "/tmp/bazelpy/app/BUILD.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path)
		if path == "/tmp/bazelpy/app/BUILD.bazel" then
			return {
				'py_binary(',
				'    name = "main",',
				'    srcs = ["main.py"],',
				'    main = "main.py",',
				')',
				'py_test(',
				'    name = "main_test",',
				'    srcs = ["test_main.py"],',
				')',
			}
		end
		if original_readfile then
			return original_readfile(path)
		end
		return {}
	end
	vim.fn.input = function(prompt, default_value)
		prompts[#prompts + 1] = prompt
		return default_value or ""
	end

	reset_job_results()
	init.run_build_command("bazel-test", "float")

	assert(#job_results > 0, "Python-related Bazel test should start a job")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel test //app:main_test"), "Python-related Bazel test should infer py_test target")
	assert(#prompts == 0, "Python-related Bazel test should not prompt for args")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile
	vim.fn.input = original_input
	reset_job_results()

	print("✓ Bazel Python test relationship inference test passed")
end

-- Test Bazel infers related JVM test targets from Foo.java -> FooTest.java naming.
local function test_bazel_jvm_test_relationship_inference()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "java"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local original_input = vim.fn.input
	local prompts = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazeljvm/app/Foo.java"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazeljvm/MODULE.bazel" or path == "/tmp/bazeljvm/app/BUILD.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path)
		if path == "/tmp/bazeljvm/app/BUILD.bazel" then
			return {
				'java_library(',
				'    name = "foo_lib",',
				'    srcs = ["Foo.java"],',
				')',
				'java_test(',
				'    name = "foo_test",',
				'    srcs = ["FooTest.java"],',
				')',
			}
		end
		if original_readfile then
			return original_readfile(path)
		end
		return {}
	end
	vim.fn.input = function(prompt, default_value)
		prompts[#prompts + 1] = prompt
		return default_value or ""
	end

	reset_job_results()
	init.run_build_command("bazel-test", "float")

	assert(#job_results > 0, "JVM-related Bazel test should start a job")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel test //app:foo_test"), "JVM-related Bazel test should infer java_test target")
	assert(#prompts == 0, "JVM-related Bazel test should not prompt for args")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile
	vim.fn.input = original_input
	reset_job_results()

	print("✓ Bazel JVM test relationship inference test passed")
end

-- Test parsed Bazel BUILD files are cached across repeated lookups.
local function test_bazel_build_file_cache_reuses_parsed_targets()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "cpp"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local build_read_count = 0

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazelcache/app/main.cc"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazelcache/MODULE.bazel" or path == "/tmp/bazelcache/app/BUILD.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path)
		if path == "/tmp/bazelcache/app/BUILD.bazel" then
			build_read_count = build_read_count + 1
			return {
				'cc_binary(',
				'    name = "main",',
				'    srcs = ["main.cc"],',
				')',
			}
		end
		if original_readfile then
			return original_readfile(path)
		end
		return {}
	end

	local first_commands = init.get_build_commands_for_filetype("cpp")
	local second_commands = init.get_build_commands_for_filetype("cpp")

	assert(
		first_commands["bazel-run"] == "bazel run //app:main",
		"First Bazel lookup should infer concrete run target"
	)
	assert(
		second_commands["bazel-run"] == "bazel run //app:main",
		"Second Bazel lookup should reuse inferred concrete run target"
	)
	assert(
		build_read_count == 1,
		"Repeated Bazel lookups should reuse cached parsed BUILD targets"
	)

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile

	print("✓ Bazel parsed BUILD cache reuse test passed")
end

test_bazel_target_inference_in_picker()
test_bazel_glob_target_inference()
test_bazel_parent_package_inference()
test_bazel_project_commands_in_picker()
test_bazel_wrapper_rule_inference()
test_bazel_go_test_relationship_inference()
test_bazel_python_test_relationship_inference()
test_bazel_jvm_test_relationship_inference()
test_bazel_build_file_cache_reuses_parsed_targets()
test_bazel_related_test_inference()
test_run_build_command_with_inferred_bazel_target()
test_run_build_command_with_detected_bazel_command()
