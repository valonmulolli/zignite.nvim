-- luacheck: globals project_root config init ui state job_results quickfix_results notify_results mock_jobs
-- luacheck: globals command_to_string reset_job_results reset_quickfix_results reset_notify_results
-- luacheck: globals count_quickfix_backend_jobs count_quickfix_daemon_jobs
-- luacheck: globals count_detect_backend_jobs count_detect_backend_requests
-- luacheck: globals get_upvalue_by_name detect_backend_tool_commands is_detect_daemon_cmd parse_detect_daemon_request
-- luacheck: globals make_expand_override with_overrides

local build = require("zignite.build.runtime_lookup")
local build_detect = require("zignite.build.tooling.query")
local project_utils = require("zignite.utils.project")

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

local function make_readfile_override(path_to_lines)
    local original_readfile = vim.fn.readfile
    return function(path, ...)
        if path_to_lines[path] ~= nil then
            return path_to_lines[path]
        end
        if original_readfile then
            return original_readfile(path, ...)
        end
        return {}
    end
end

local function with_file_context(filetype, filepath, overrides, fn)
    local merged = {
        { tbl = vim.bo, key = "filetype", value = filetype },
        { tbl = vim.fn, key = "expand", value = make_expand_override(filepath) },
    }
    for _, override in ipairs(overrides or {}) do
        merged[#merged + 1] = override
    end
    with_overrides(merged, fn)
end

local function assert_last_job_matches(started_msg, pattern, pattern_msg)
    assert(#job_results > 0, started_msg)
    local last_job = job_results[#job_results]
    local command = command_to_string(last_job.cmd)
    assert(command:match(pattern), pattern_msg)
    return command, last_job
end

local function assert_any_job_matches(pattern, failure_msg)
    local commands = {}
    for _, job in ipairs(job_results) do
        local command = command_to_string(job.cmd)
        commands[#commands + 1] = command
        if command:match(pattern) then
            return command
        end
    end
    assert(false, failure_msg .. ": " .. table.concat(commands, " | "))
end

-- Test basic command execution
local function test_basic_execution()
    config.setup({ mode = "float" })

    with_file_context("python", "/tmp/test.py", nil, function()
        init.run_code(0, "float")
    end)

    local command = assert_last_job_matches(
        "Job was not started",
        "%-%-argv",
        "Expected argv mode for simple runner command"
    )
    assert(command:match("python3"), "Python command not executed")

    reset_job_results()

    print("✓ Basic execution test passed")
end

-- Test interpreted default runner uses argv mode (no shell chaining).
local function test_interpreted_runner_uses_argv_mode()
    config.setup({ mode = "float" })

    local cases = {
        { filetype = "javascript", path = "/tmp/js/main.js", token = "node" },
        { filetype = "typescript", path = "/tmp/ts/main.ts", token = "bun" },
        { filetype = "lua", path = "/tmp/lua/main.lua", token = "lua" },
        { filetype = "sh", path = "/tmp/sh/main.sh", token = "bash" },
        { filetype = "zsh", path = "/tmp/zsh/main.zsh", token = "zsh" },
    }

    for _, case in ipairs(cases) do
        with_file_context(case.filetype, case.path, nil, function()
            init.run_code(0, "float")
        end)

        local command = assert_last_job_matches(
            case.filetype .. " job was not started",
            "%-%-argv",
            case.filetype .. " default runner should use argv mode"
        )
        assert(command:match(case.token), "Expected " .. case.token .. " in " .. case.filetype .. " runner command")
        assert(not command:match("&&"), case.filetype .. " runner should not use shell command chains by default")
        reset_job_results()
    end

    print("✓ Interpreted runner argv-mode test passed")
end

-- Test visual RunCode temp files preserve a useful source extension.
local function test_visual_run_code_preserves_extension()
    config.setup({ mode = "float" })

    reset_job_results()
    with_file_context("typescript", "/tmp/visual/main.ts", {
        { tbl = vim.fn, key = "tempname", value = function() return "/tmp/zignite-visual" end },
        { tbl = vim.fn, key = "getpos", value = function() return { 0, 1, 0, 0 } end },
        { tbl = vim.api, key = "nvim_buf_get_text", value = function() return { "console.log('ok')" } end },
    }, function()
        init.run_code(1, "float")
    end)

    assert_last_job_matches(
        "Visual RunCode should start a job",
        "/tmp/zignite%-visual%.ts",
        "Visual RunCode temp file should preserve .ts extension"
    )
    reset_job_results()

    print("✓ Visual RunCode temp extension test passed")
end

-- Test timeout-enabled runs go through zig wrapper (`--timeout` + `--argv`).
local function test_timeout_uses_zig_wrapper()
    config.setup({
        mode = "float",
        timeout = 5000,
    })

    reset_job_results()
    with_file_context("python", "/tmp/timeout/main.py", nil, function()
        init.run_code(0, "float")
    end)

    local command = assert_last_job_matches(
        "Timeout run job was not started",
        "%-%-timeout=5000",
        "Timeout run should include --timeout wrapper flag"
    )
    assert(command:match("%-%-argv"), "Timeout run should include --argv wrapper mode")
    assert(command:match("python3"), "Timeout run should include python command payload")
    reset_job_results()

    print("✓ Timeout wrapper runtime test passed")
end

-- Test Python RunFile prefers uv when the project is uv-managed.
local function test_uv_python_runner_uses_uv()
    config.setup({ mode = "float" })

    reset_job_results()
    with_file_context("python", "/tmp/uvapp/main.py", {
        {
            tbl = vim.fn,
            key = "filereadable",
            value = make_filereadable_override({
                "/tmp/uvapp/pyproject.toml",
                "/tmp/uvapp/uv.lock",
            }),
        },
        {
            tbl = vim.fn,
            key = "readfile",
            value = make_readfile_override({
                ["/tmp/uvapp/pyproject.toml"] = {
                    "[project]",
                    'name = "uvapp"',
                    "",
                    "[tool.uv]",
                },
            }),
        },
    }, function()
        init.run_code(0, "float")
    end)

    local command = assert_last_job_matches(
        "uv-managed Python RunFile should start a job",
        "uv",
        "uv-managed Python runner should execute via uv"
    )
    assert(command:match("%-%-argv"), "uv-managed Python runner should stay in argv mode")
    assert(command:match("python"), "uv-managed Python runner should still invoke python explicitly")
    reset_job_results()

    print("✓ uv Python RunFile test passed")
end

-- Test Python RunFile prefers a warmed Zig python-root cache before falling back to local pyproject reads.
local function test_uv_python_runner_uses_warmed_system_cache()
	config.setup({ mode = "float" })

		local build_state = require("zignite.build.cache_state")
		build_detect.reset()
	build.reset()

	build_state.set_bounded_cache_entry(
		build_state.system_runtime_cache,
		build_state.system_runtime_cache_order,
		build_state.SYSTEM_RUNTIME_CACHE_MAX,
		table.concat({ "python-root", "/tmp/warmpy", vim.fs.normalize("/tmp/warmpy/main.py") }, "::"),
		{
			result = {
				root = "/tmp/warmpy",
				system = "python",
				commands = {
					run = "uv run -m main",
					test = "uv run pytest",
					install = "uv sync",
				},
			},
			updated_at_ms = build_state.now_ms(),
		}
	)

	reset_job_results()
	with_file_context("python", "/tmp/warmpy/main.py", {
		{
			tbl = project_utils,
			key = "get_project_root",
			value = function(path)
				if path == "/tmp/warmpy/main.py" then
					return "/tmp/warmpy"
				end
				return nil
			end,
		},
		{
			tbl = vim.fn,
			key = "readfile",
			value = function(path)
				error("RunFile should not hit local pyproject reads when python-root cache is warm: " .. tostring(path))
			end,
		},
	}, function()
		init.run_code(0, "float")
	end)

	local command = assert_last_job_matches(
		"warmed Zig Python cache should start a job",
		"uv",
		"warmed Zig python-root cache should drive uv Python runner selection"
	)
	assert(command:match("%-%-argv"), "warmed Zig Python runner should stay in argv mode")
	build_detect.reset()
	build.reset()
	reset_job_results()

	print("✓ uv Python warmed system cache test passed")
end

-- Test filetype runners do not eagerly trigger build-project resolution.
local function test_get_command_avoids_eager_project_resolution_for_filetype_runner()
    config.setup({ mode = "float" })

        local original_get_preferred_project_command = build.get_preferred_project_command
    local calls = 0

    build.get_preferred_project_command = function(...)
        calls = calls + 1
        return original_get_preferred_project_command(...)
    end

    local runner, source, filetype = init.get_command("/tmp/no-project/main.py", "python")

    build.get_preferred_project_command = original_get_preferred_project_command

    assert(source == "filetype", "Expected filetype runner source, got: " .. tostring(source))
    assert(filetype == "python", "Expected python filetype, got: " .. tostring(filetype))
    assert(type(runner) == "string", "Expected python runner string")
    assert(calls == 0, "Filetype runner should not eagerly resolve project build commands")

    print("✓ get_command lazy project resolution test passed")
end

-- Test filetype fallback by extension when vim.bo.filetype is empty.
local function test_language_detected_from_extension()
    config.setup({ mode = "float" })

    with_file_context("", "/tmp/fallback/main.rs", nil, function()
        init.run_code(0, "float")
    end)

    assert(#job_results > 0, "Extension-based detection should start a job")
    assert_any_job_matches("rustc", "Expected rust runner for .rs fallback, got")
    reset_job_results()

    print("✓ Extension-based language detection test passed")
end

-- Test filetype fallback by shebang when extension and vim.bo.filetype are missing.
local function test_language_detected_from_shebang()
    config.setup({ mode = "float" })

    with_file_context("", "/tmp/fallback/script", {
        {
            tbl = vim.fn,
            key = "filereadable",
            value = make_filereadable_override({ "/tmp/fallback/script" }),
        },
        {
            tbl = vim.fn,
            key = "readfile",
            value = make_readfile_override({
                ["/tmp/fallback/script"] = { "#!/usr/bin/env python3" },
            }),
        },
    }, function()
        init.run_code(0, "float")
    end)

    assert(#job_results > 0, "Shebang-based detection should start a job")
    assert_any_job_matches("python3", "Expected python runner for python shebang fallback, got")
    reset_job_results()

    print("✓ Shebang-based language detection test passed")
end

-- Test project detection still works as a RunFile fallback when no filetype runner exists.
local function test_project_execution()
    config.setup({
        project = {
            ["/tmp/test/.*"] = { name = "Test Project", command = "echo hello" }
        }
    })

    with_file_context("plain", "/tmp/test/main.unknown", nil, function()
        init.run_code(0, "float")
    end)

    local command, last_job = assert_last_job_matches(
        "Project job was not started",
        "echo hello",
        "Project command not executed"
    )
    assert(command:match("%-%-argv"), "Project command should use argv mode for simple commands")
    assert(not command:match("cd "), "Project command should not rely on shell cd chaining")
    assert(last_job.opts and last_job.opts.cwd == "/tmp/test", "Project command should execute with project cwd")
    reset_job_results()

    print("✓ Project fallback execution test passed")
end

-- Test marker-only Node projects keep root detection without inventing a fallback command.
local function test_marker_project_without_command_does_not_run()
    config.setup({})

    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local output_messages = {}

    reset_job_results()
    with_file_context("plain", "/tmp/nodefallback/main.txt", {
        {
            tbl = vim.fn,
            key = "filereadable",
            value = make_filereadable_override({ "/tmp/nodefallback/package.json" }),
        },
        {
            tbl = vim.api,
            key = "nvim_buf_set_lines",
            value = function(buf, start_idx, end_idx, strict, lines)
                if type(lines) == "table" and #lines > 0 then
                    table.insert(output_messages, table.concat(lines, "\n"))
                end
                if original_buf_set_lines then
                    return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
                end
            end,
        },
    }, function()
        init.run_code(0, "float")
    end)

    assert(#job_results == 0, "Marker-only Node project should not run an invented fallback command")
    assert(#output_messages > 0, "Marker-only Node project should surface a missing-runner message")
    assert(
        output_messages[#output_messages]:match("No runner configured"),
        "Marker-only Node project should report that no runner exists"
    )
    reset_job_results()

    print("✓ Marker-only project fallback test passed")
end

-- Test build command execution uses cwd and argv mode for simple commands.
local function test_build_command_uses_cwd()
    config.setup({
        build_commands = {
            python = {
                run = "python3 $file",
            },
        },
    })

    with_file_context("python", "/tmp/buildproj/main.py", nil, function()
        init.run_build_command("run", "float")
    end)

    local command, last_job = assert_last_job_matches(
        "Build command job was not started",
        "%-%-argv",
        "Build command should use argv mode for simple commands"
    )
    assert(command:match("python3"), "Build command should include python3")
    assert(not command:match("cd "), "Build command should not rely on shell cd chaining")
    assert(
        last_job.opts and last_job.opts.cwd == "/tmp/buildproj",
        "Build command should execute in file directory cwd"
    )
    reset_job_results()

    print("✓ Build command cwd test passed")
end

-- Test Python build defaults switch to uv in uv-managed projects.
local function test_uv_python_build_defaults()
    config.setup({
        build_commands = {
            python = {
                run = "python -m main",
                test = "pytest",
                install = "pip install -r requirements.txt",
            },
        },
    })

	reset_job_results()
	with_file_context("python", "/tmp/uvbuild/main.py", {
		{
			tbl = vim.fn,
			key = "executable",
			value = function(path)
				if tostring(path):match("zignite$") then
					return 1
				end
				return 0
			end,
		},
		{
			tbl = vim.fn,
			key = "systemlist",
			value = function(cmd)
				if type(cmd) == "table" and cmd[2] == "--project-parse" and cmd[3] == "--kind=python-auto" then
					vim.v.shell_error = 0
					return {
						"COMMAND\trun\tuv run -m main",
						"COMMAND\ttest\tuv run pytest",
						"COMMAND\tinstall\tuv sync",
					}
				end
				return {}
			end,
		},
	}, function()
		init.run_build_command("test", "float")
	end)

    assert_last_job_matches(
        "uv-managed Python build command should start a job",
        "uv run pytest",
        "uv-managed Python test should execute via uv run pytest"
    )
    reset_job_results()

    print("✓ uv Python build defaults test passed")
end

-- Test Python RunFile uses the fast local pyproject scan and still selects uv.
local function test_uv_python_runner_uses_fast_pyproject_scan()
    config.setup({ mode = "float" })

    local readfile_calls = 0

    reset_job_results()
    with_file_context("python", "/tmp/uvzig/main.py", {
        {
            tbl = vim.fn,
            key = "filereadable",
            value = make_filereadable_override({ "/tmp/uvzig/pyproject.toml" }),
        },
        {
            tbl = vim.fn,
            key = "executable",
            value = function(path)
                if tostring(path):match("zignite$") then
                    return 1
                end
                return 0
            end,
        },
        {
            tbl = vim.fn,
            key = "systemlist",
            value = function(cmd)
                vim.v.shell_error = 0
                if type(cmd) == "table" and cmd[2] == "--project-parse" and cmd[3] == "--kind=pyproject" then
                    return { "TOOL\tuv" }
                end
                return {}
            end,
        },
        {
            tbl = vim.fn,
            key = "readfile",
            value = function(path, _, _)
                if path == "/tmp/uvzig/pyproject.toml" then
                    readfile_calls = readfile_calls + 1
                    return {
                        "[project]",
                        'name = "uvzig"',
                        "",
                        "[tool.uv]",
                    }
                end
                return {}
            end,
        },
    }, function()
        init.run_code(0, "float")
    end)

    assert_last_job_matches(
        "uv-managed Python RunFile should start a job when local pyproject scan succeeds",
        "uv",
        "Fast pyproject scan should drive uv Python runner selection"
    )
    assert(readfile_calls == 1, "RunFile should use the local pyproject scan once for Python uv detection")
    vim.v.shell_error = 0
    reset_job_results()

    print("✓ uv Python fast pyproject scan test passed")
end

-- Test build command detection maps related filetypes (e.g. typescriptreact -> typescript).
local function test_build_command_filetype_alias()
    config.setup({ mode = "float" })

    with_file_context("typescriptreact", "/tmp/alias/main.tsx", nil, function()
        init.run_build_command("dev", "float")
    end)

    assert_last_job_matches(
        "Alias filetype build command should start a job",
        "npm run dev",
        "typescriptreact should reuse typescript build commands"
    )
    reset_job_results()

    print("✓ Build command filetype alias test passed")
end

test_basic_execution()
test_interpreted_runner_uses_argv_mode()
test_visual_run_code_preserves_extension()
test_timeout_uses_zig_wrapper()
test_uv_python_runner_uses_uv()
test_uv_python_runner_uses_warmed_system_cache()
test_uv_python_runner_uses_fast_pyproject_scan()
test_get_command_avoids_eager_project_resolution_for_filetype_runner()
test_language_detected_from_extension()
test_language_detected_from_shebang()
test_project_execution()
test_marker_project_without_command_does_not_run()
test_build_command_uses_cwd()
test_uv_python_build_defaults()
test_build_command_filetype_alias()
