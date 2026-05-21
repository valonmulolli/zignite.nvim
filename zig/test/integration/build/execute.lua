-- luacheck: globals project_root config init ui state job_results quickfix_results notify_results mock_jobs
-- luacheck: globals command_to_string reset_job_results reset_quickfix_results reset_notify_results
-- luacheck: globals count_quickfix_backend_jobs count_quickfix_daemon_jobs
-- luacheck: globals count_detect_backend_jobs count_detect_backend_requests
-- luacheck: globals get_upvalue_by_name detect_backend_tool_commands is_detect_daemon_cmd parse_detect_daemon_request

-- Test :RunBuildLast behavior (warn before first run, then repeat latest command).
local function test_run_build_last_behavior()
    config.setup({
        build_commands = {
            lastft = {
                run = "echo run-last",
                test = "pytest -q",
            },
        },
    })

    vim.bo.filetype = "lastft"
    local original_expand = vim.fn.expand
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local output_messages = {}
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/last/main.py" end
        return original_expand(expr)
    end
    vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
        if type(lines) == "table" and #lines > 0 then
            table.insert(output_messages, table.concat(lines, "\n"))
        end
        if original_buf_set_lines then
            return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
        end
    end

    reset_job_results()
    init.run_last_build_command("float")
    assert(#job_results == 0, "RunBuildLast should not start job before any build command")
    assert(#output_messages > 0, "RunBuildLast should surface guidance before first selection")

    reset_job_results()
    init.run_build_command("test", "float")
    assert(#job_results > 0, "run_build_command(test) should start a job")

    reset_job_results()
    init.run_last_build_command("float")
    assert(#job_results > 0, "RunBuildLast should repeat previous build command")
    local repeated = command_to_string(job_results[#job_results].cmd)
    assert(repeated:match("pytest"), "RunBuildLast should repeat the latest command for filetype")

    vim.fn.expand = original_expand
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    reset_job_results()

    print("✓ RunBuildLast behavior test passed")
end

local function test_run_build_last_ignores_stale_command()
    config.setup({
        build_commands = {
            staleft = {
                run = "echo run-stale",
                test = "pytest -q",
            },
        },
    })

    vim.bo.filetype = "staleft"
    local original_expand = vim.fn.expand
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local output_messages = {}
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/stale/main.py" end
        return original_expand(expr)
    end
    vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
        if type(lines) == "table" and #lines > 0 then
            table.insert(output_messages, table.concat(lines, "\n"))
        end
        if original_buf_set_lines then
            return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
        end
    end

    reset_job_results()
    init.run_build_command("run", "float")
    assert(#job_results > 0, "run_build_command(run) should start a job before command goes stale")

    config.setup({
        build_commands = {
            staleft = {
                test = "pytest -q",
            },
        },
    })

    reset_job_results()
    init.run_last_build_command("float")
    assert(#job_results == 0, "RunBuildLast should not execute a stale missing command")
    assert(#output_messages > 0, "RunBuildLast should explain when the last command is no longer available")
    assert(
        output_messages[#output_messages]:match("Command 'run' not found"),
        "RunBuildLast should report that the stale command is no longer available"
    )

    vim.fn.expand = original_expand
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    reset_job_results()

    print("✓ RunBuildLast stale command test passed")
end

local function test_build_resolve_exposes_backend_last_command_name()
    config.setup({
        build_commands = {
            pickerft = {
                run = "echo picker-run",
                test = "echo picker-test",
            },
        },
    })

    vim.bo.filetype = "pickerft"
    local original_expand = vim.fn.expand
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/picker/main.py" end
        return original_expand(expr)
    end

    reset_job_results()
    init.run_build_command("test", "float")
    assert(#job_results > 0, "run_build_command(test) should start a job before resolving picker state")

    local resolved = require("zignite.rpc.build_resolve").resolve_sync("/tmp/picker/main.py", "pickerft")
    assert(type(resolved) == "table", "build_resolve.resolve_sync should return a table")
    assert(resolved.last_command_name == "test",
        "build resolve should expose the backend-owned last command name for picker state")

    vim.fn.expand = original_expand
    reset_job_results()

    print("✓ Build resolve backend last-command test passed")
end

-- Test RunLive picks command by live/dev/watch priority.
local function test_run_live_priority_selection()
    config.setup({
        build_commands = {
            webft = {
                start = "npm start",
                dev = "npm run dev",
                live = "npm run live",
            },
        },
    })

    vim.bo.filetype = "webft"
    local original_expand = vim.fn.expand
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/webft/main.ts" end
        return original_expand(expr)
    end

    reset_job_results()
    init.run_live("float")

    assert(#job_results > 0, "RunLive should start a job when a live command exists")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("live"), "RunLive should prioritize 'live' command")
    assert(not command:match("run dev"), "RunLive should not fallback to 'dev' when 'live' exists")

    vim.fn.expand = original_expand
    reset_job_results()

    print("✓ RunLive priority selection test passed")
end

-- Test RunLive shows guidance when no live/watch command exists.
local function test_run_live_missing_command()
    config.setup({
        build_commands = {
            nolive = {
                build = "echo build",
                test = "echo test",
            },
        },
    })

    vim.bo.filetype = "nolive"
    local original_expand = vim.fn.expand
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local output_messages = {}
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/nolive/main.txt" end
        return original_expand(expr)
    end
    vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
        if type(lines) == "table" and #lines > 0 then
            table.insert(output_messages, table.concat(lines, "\n"))
        end
        if original_buf_set_lines then
            return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
        end
    end

    reset_job_results()
    init.run_live("float")
    assert(#job_results == 0, "RunLive should not start job when no live/watch command exists")
    assert(#output_messages > 0, "RunLive should show guidance when no live/watch command exists")
    assert(
        output_messages[#output_messages]:match("No live command resolved"),
        "RunLive missing-command message should come from the backend-driven controller path"
    )

    vim.fn.expand = original_expand
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    reset_job_results()

	print("✓ RunLive missing command test passed")
end

-- Test RunLive does not use shipped JS defaults when package.json lacks live scripts.
local function test_run_live_javascript_ignores_missing_default_scripts()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "javascript"
    local original_expand = vim.fn.expand
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local output_messages = {}

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/jslive/src/main.js" end
        return original_expand(expr)
    end
    vim.fn.executable = function(path)
        if tostring(path):match("zignite$") then
            return 1
        end
        if original_executable then
            return original_executable(path)
        end
        return 0
    end
    vim.fn.systemlist = function(cmd)
        if type(cmd) == "table" and cmd[2] == "--project-parse" and cmd[3] == "--kind=package-json-auto" then
            vim.v.shell_error = 0
            return {
                "COMMAND\tinstall\tnpm install",
                "COMMAND\tbuild\tnpm run build",
            }
        end
        if original_systemlist then
            return original_systemlist(cmd)
        end
        return {}
    end
    vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
        if type(lines) == "table" and #lines > 0 then
            table.insert(output_messages, table.concat(lines, "\n"))
        end
        if original_buf_set_lines then
            return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
        end
    end

    os.execute("mkdir -p /tmp/jslive >/dev/null 2>&1")
    local package_json = assert(io.open("/tmp/jslive/package.json", "w"))
    package_json:write("{}\n")
    package_json:close()

    reset_job_results()
    init.run_live("float")
    local execution_jobs = 0
    for _, job in ipairs(job_results) do
        local command = command_to_string(job.cmd)
        if not command:match("%-%-daemon") and not command:match("%-%-project%-parse") then
            execution_jobs = execution_jobs + 1
        end
    end
    assert(execution_jobs == 0, "RunLive should not use shipped JS defaults when package.json lacks live scripts")
    assert(#output_messages > 0, "RunLive should show guidance when no real JS live script exists")
    assert(
        output_messages[#output_messages]:match("No live command resolved"),
        "RunLive missing-command message should come from the backend-driven controller path for JS projects too"
    )

    vim.fn.expand = original_expand
    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.v.shell_error = 0
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    os.remove("/tmp/jslive/package.json")
    os.execute("rmdir /tmp/jslive >/dev/null 2>&1")
    reset_job_results()

    print("✓ RunLive JavaScript missing-script test passed")
end

local function test_run_live_javascript_uses_detected_live_alias()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "javascript"
    local original_expand = vim.fn.expand
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/jsliveok/src/main.js" end
        return original_expand(expr)
    end
    vim.fn.executable = function(path)
        if tostring(path):match("zignite$") then
            return 1
        end
        if original_executable then
            return original_executable(path)
        end
        return 0
    end
    os.execute("mkdir -p /tmp/jsliveok >/dev/null 2>&1")
    local package_json = assert(io.open("/tmp/jsliveok/package.json", "w"))
    package_json:write('{ "scripts": { "dev": "vite" } }\n')
    package_json:close()

    reset_job_results()
    init.run_live("float")
    assert(#job_results > 0, "RunLive should start a job when Zig emits a live alias")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("npm run dev"), "RunLive should execute the Zig live alias command")

    vim.fn.expand = original_expand
    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.v.shell_error = 0
    os.remove("/tmp/jsliveok/package.json")
    os.execute("rmdir /tmp/jsliveok >/dev/null 2>&1")
    reset_job_results()

    print("✓ RunLive JavaScript live-alias test passed")
end

local function test_run_code_visual_uses_backend_managed_execution_path()
    config.setup({})

    vim.bo.filetype = "zig"
    local original_expand = vim.fn.expand
    local original_tempname = vim.fn.tempname
    local original_execute_command = init.execute_command
    local tempname_calls = 0
    local execution_paths = {}

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/visual-zig/main.zig" end
        return original_expand(expr)
    end
    vim.fn.tempname = function()
        tempname_calls = tempname_calls + 1
        return string.format("/tmp/zignite-visual-%d", tempname_calls)
    end
    init.execute_command = function(system_command)
        local command = command_to_string(system_command)
        local execution_path = command:match("(/[^%s'\"]+%.zig)")
        execution_paths[#execution_paths + 1] = execution_path
    end

    init.run_code(1, "float")
    init.run_code(1, "float")

    init.execute_command = original_execute_command
    vim.fn.expand = original_expand
    vim.fn.tempname = original_tempname

    assert(#execution_paths == 2, "visual runs should reach execute_command twice")
    assert(execution_paths[1] == execution_paths[2], "visual runs should reuse the backend-managed execution path")
    assert(execution_paths[1]:match("%.zig$"), "backend-managed visual execution path should keep the Zig extension")
    assert(tempname_calls == 0, "visual runs should no longer allocate temp paths in Lua")

    os.remove(execution_paths[1])
    reset_job_results()

    print("✓ RunCode visual backend execution path test passed")
end

test_run_build_last_behavior()
test_run_build_last_ignores_stale_command()
test_build_resolve_exposes_backend_last_command_name()
test_run_live_priority_selection()
test_run_live_missing_command()
test_run_live_javascript_ignores_missing_default_scripts()
test_run_live_javascript_uses_detected_live_alias()
test_run_code_visual_uses_backend_managed_execution_path()
