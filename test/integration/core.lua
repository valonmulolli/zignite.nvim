-- luacheck: globals project_root config init ui state job_results quickfix_results notify_results mock_jobs
-- luacheck: globals command_to_string reset_job_results reset_quickfix_results reset_notify_results
-- luacheck: globals count_quickfix_backend_jobs count_quickfix_daemon_jobs
-- luacheck: globals count_detect_backend_jobs count_detect_backend_requests
-- luacheck: globals get_upvalue_by_name detect_backend_tool_commands is_detect_daemon_cmd parse_detect_daemon_request

-- Test basic command execution
local function test_basic_execution()
    config.setup({ mode = "float" })

    -- Mock vim.bo.filetype and vim.fn.expand
    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/test.py" end
        return original_expand(expr)
    end

    -- Run the code
    init.run_code(0, "float")

    -- Check that job was started
    assert(#job_results > 0, "Job was not started")
    local last_job = job_results[#job_results]
    local command = command_to_string(last_job.cmd)
    assert(command:match("%-%-argv"), "Expected argv mode for simple runner command")
    assert(command:match("python3"), "Python command not executed")

    -- Restore
    vim.fn.expand = original_expand
    reset_job_results()

    print("✓ Basic execution test passed")
end

-- Test interpreted default runner uses argv mode (no shell chaining).
local function test_interpreted_runner_uses_argv_mode()
    config.setup({ mode = "float" })

    local original_expand = vim.fn.expand
    local cases = {
        { filetype = "javascript", path = "/tmp/js/main.js", token = "node" },
        { filetype = "typescript", path = "/tmp/ts/main.ts", token = "bun" },
        { filetype = "lua", path = "/tmp/lua/main.lua", token = "lua" },
        { filetype = "sh", path = "/tmp/sh/main.sh", token = "bash" },
        { filetype = "zsh", path = "/tmp/zsh/main.zsh", token = "zsh" },
    }

    for _, case in ipairs(cases) do
        vim.bo.filetype = case.filetype
        vim.fn.expand = function(expr)
            if expr == "%:p" then return case.path end
            return original_expand(expr)
        end

        init.run_code(0, "float")

        assert(#job_results > 0, case.filetype .. " job was not started")
        local command = command_to_string(job_results[#job_results].cmd)
        assert(command:match("%-%-argv"), case.filetype .. " default runner should use argv mode")
        assert(command:match(case.token), "Expected " .. case.token .. " in " .. case.filetype .. " runner command")
        assert(not command:match("&&"), case.filetype .. " runner should not use shell command chains by default")
        reset_job_results()
    end

    vim.fn.expand = original_expand

    print("✓ Interpreted runner argv-mode test passed")
end

-- Test visual RunCode temp files preserve a useful source extension.
local function test_visual_run_code_preserves_extension()
    config.setup({ mode = "float" })

    vim.bo.filetype = "typescript"
    local original_expand = vim.fn.expand
    local original_getpos = vim.fn.getpos
    local original_tempname = vim.fn.tempname
    local original_get_text = vim.api.nvim_buf_get_text

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/visual/main.ts" end
        return original_expand(expr)
    end
    vim.fn.tempname = function()
        return "/tmp/zignite-visual"
    end
    vim.fn.getpos = function()
        return { 0, 1, 0, 0 }
    end
    vim.api.nvim_buf_get_text = function()
        return { "console.log('ok')" }
    end

    reset_job_results()
    init.run_code(1, "float")

    assert(#job_results > 0, "Visual RunCode should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("/tmp/zignite%-visual%.ts"), "Visual RunCode temp file should preserve .ts extension")

    vim.fn.expand = original_expand
    vim.fn.getpos = original_getpos
    vim.fn.tempname = original_tempname
    vim.api.nvim_buf_get_text = original_get_text
    reset_job_results()

    print("✓ Visual RunCode temp extension test passed")
end

-- Test timeout-enabled runs go through zig wrapper (`--timeout` + `--argv`).
local function test_timeout_uses_zig_wrapper()
    config.setup({
        mode = "float",
        timeout = 5000,
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/timeout/main.py" end
        return original_expand(expr)
    end

    reset_job_results()
    init.run_code(0, "float")

    assert(#job_results > 0, "Timeout run job was not started")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("%-%-timeout=5000"), "Timeout run should include --timeout wrapper flag")
    assert(command:match("%-%-argv"), "Timeout run should include --argv wrapper mode")
    assert(command:match("python3"), "Timeout run should include python command payload")

    vim.fn.expand = original_expand
    reset_job_results()

    print("✓ Timeout wrapper runtime test passed")
end

-- Test Python RunFile prefers uv when the project is uv-managed.
local function test_uv_python_runner_uses_uv()
    config.setup({ mode = "float" })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/uvapp/main.py" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/uvapp/pyproject.toml" or path == "/tmp/uvapp/uv.lock" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/uvapp/pyproject.toml" then
            return {
                "[project]",
                'name = "uvapp"',
                "",
                "[tool.uv]",
            }
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end

    reset_job_results()
    init.run_code(0, "float")

    assert(#job_results > 0, "uv-managed Python RunFile should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("%-%-argv"), "uv-managed Python runner should stay in argv mode")
    assert(command:match("uv"), "uv-managed Python runner should execute via uv")
    assert(command:match("python"), "uv-managed Python runner should still invoke python explicitly")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    reset_job_results()

    print("✓ uv Python RunFile test passed")
end

-- Test filetype fallback by extension when vim.bo.filetype is empty.
local function test_language_detected_from_extension()
    config.setup({ mode = "float" })

    local original_expand = vim.fn.expand
    vim.bo.filetype = ""
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/fallback/main.rs" end
        return original_expand(expr)
    end

    init.run_code(0, "float")

    assert(#job_results > 0, "Extension-based detection should start a job")
    local has_rust = false
    local commands = {}
    for _, job in ipairs(job_results) do
        local command = command_to_string(job.cmd)
        commands[#commands + 1] = command
        if command:match("rustc") then
            has_rust = true
        end
    end
    assert(has_rust, "Expected rust runner for .rs fallback, got: " .. table.concat(commands, " | "))

    vim.fn.expand = original_expand
    reset_job_results()

    print("✓ Extension-based language detection test passed")
end

-- Test filetype fallback by shebang when extension and vim.bo.filetype are missing.
local function test_language_detected_from_shebang()
    config.setup({ mode = "float" })

    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile
    vim.bo.filetype = ""
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/fallback/script" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/fallback/script" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/fallback/script" then
            return { "#!/usr/bin/env python3" }
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end

    init.run_code(0, "float")

    assert(#job_results > 0, "Shebang-based detection should start a job")
    local has_python = false
    local commands = {}
    for _, job in ipairs(job_results) do
        local command = command_to_string(job.cmd)
        commands[#commands + 1] = command
        if command:match("python3") then
            has_python = true
        end
    end
    assert(has_python, "Expected python runner for python shebang fallback, got: " .. table.concat(commands, " | "))

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
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

    vim.bo.filetype = "plain"
    local original_expand = vim.fn.expand
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/test/main.unknown" end
        return original_expand(expr)
    end

    init.run_code(0, "float")

    assert(#job_results > 0, "Project job was not started")
    local last_job = job_results[#job_results]
    local command = command_to_string(last_job.cmd)
    assert(command:match("echo hello"), "Project command not executed")
    assert(command:match("%-%-argv"), "Project command should use argv mode for simple commands")
    assert(not command:match("cd "), "Project command should not rely on shell cd chaining")
    assert(last_job.opts and last_job.opts.cwd == "/tmp/test", "Project command should execute with project cwd")

    -- Restore
    vim.fn.expand = original_expand
    reset_job_results()

    print("✓ Project fallback execution test passed")
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

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/buildproj/main.py" end
        return original_expand(expr)
    end

    init.run_build_command("run", "float")

    assert(#job_results > 0, "Build command job was not started")
    local last_job = job_results[#job_results]
    local command = command_to_string(last_job.cmd)
    assert(command:match("%-%-argv"), "Build command should use argv mode for simple commands")
    assert(command:match("python3"), "Build command should include python3")
    assert(not command:match("cd "), "Build command should not rely on shell cd chaining")
    assert(
        last_job.opts and last_job.opts.cwd == "/tmp/buildproj",
        "Build command should execute in file directory cwd"
    )

    vim.fn.expand = original_expand
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

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/uvbuild/main.py" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/uvbuild/pyproject.toml" or path == "/tmp/uvbuild/uv.lock" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/uvbuild/pyproject.toml" then
            return {
                "[project]",
                'name = "uvbuild"',
                "",
                "[tool.uv]",
            }
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end

    reset_job_results()
    init.run_build_command("test", "float")

    assert(#job_results > 0, "uv-managed Python build command should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("uv run pytest"), "uv-managed Python test should execute via uv run pytest")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    reset_job_results()

    print("✓ uv Python build defaults test passed")
end

-- Test build command detection maps related filetypes (e.g. typescriptreact -> typescript).
local function test_build_command_filetype_alias()
    config.setup({ mode = "float" })

    local original_expand = vim.fn.expand
    vim.bo.filetype = "typescriptreact"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/alias/main.tsx" end
        return original_expand(expr)
    end

    init.run_build_command("dev", "float")

    assert(#job_results > 0, "Alias filetype build command should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("npm run dev"), "typescriptreact should reuse typescript build commands")

    vim.fn.expand = original_expand
    reset_job_results()

	print("✓ Build command filetype alias test passed")
end

test_basic_execution()
test_interpreted_runner_uses_argv_mode()
test_visual_run_code_preserves_extension()
test_timeout_uses_zig_wrapper()
test_uv_python_runner_uses_uv()
test_language_detected_from_extension()
test_language_detected_from_shebang()
test_project_execution()
test_build_command_uses_cwd()
test_uv_python_build_defaults()
test_build_command_filetype_alias()
