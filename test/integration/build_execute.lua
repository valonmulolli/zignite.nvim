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
        output_messages[#output_messages]:match("No live/watch command found"),
        "RunLive missing-command message should mention live/watch command"
    )

    vim.fn.expand = original_expand
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    reset_job_results()

	print("✓ RunLive missing command test passed")
end

test_run_build_last_behavior()
test_run_live_priority_selection()
test_run_live_missing_command()
