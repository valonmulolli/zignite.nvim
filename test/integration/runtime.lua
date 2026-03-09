-- luacheck: globals project_root config init ui state job_results quickfix_results notify_results mock_jobs
-- luacheck: globals command_to_string reset_job_results reset_quickfix_results reset_notify_results
-- luacheck: globals count_quickfix_backend_jobs count_quickfix_daemon_jobs
-- luacheck: globals count_detect_backend_jobs count_detect_backend_requests
-- luacheck: globals get_upvalue_by_name detect_backend_tool_commands is_detect_daemon_cmd parse_detect_daemon_request

-- Test run_build_command prompts for zig fetch URL/path and executes with provided argument.
local function test_run_build_command_with_detected_zig_fetch_prompt()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "zig"
    local original_expand = vim.fn.expand
    local original_systemlist = vim.fn.systemlist
    local original_input = vim.fn.input
    local prompts = {}

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/zigdetect/main.zig" end
        return original_expand(expr)
    end
    vim.fn.systemlist = function()
        vim.v.shell_error = 0
        return {
            "Usage: zig [command] [options]",
            "",
            "Commands:",
            "  fetch            Copy a package into global cache and print its hash",
            "",
            "General Options:",
        }
    end
    vim.fn.input = function(prompt, _default)
        prompts[#prompts + 1] = prompt
        return "https://example.com/pkg.tar.gz"
    end

    reset_job_results()
    init.run_build_command("fetch", "float")
    assert(#job_results > 0, "Detected zig fetch command should start a job after prompting for URL/path")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("zig fetch"), "Detected zig fetch should execute via zig fetch")
    assert(command:match("https://example%.com/pkg%.tar%.gz"), "zig fetch should include provided URL/path argument")
    assert(#prompts == 1 and prompts[1]:match("zig fetch"), "zig fetch should prompt for URL/path exactly once")

    vim.fn.expand = original_expand
    vim.fn.systemlist = original_systemlist
    vim.fn.input = original_input
    vim.v.shell_error = 0
    reset_job_results()

    print("✓ RunBuild with detected zig fetch prompt test passed")
end

-- Test show_output respects split mode and renders in-window (not notify fallback).
local function test_show_output_respects_mode()
    config.setup({
        mode = "split",
        term = {
            position = "top",
            focus = true,
        },
    })

    local original_cmd = vim.cmd
    local issued_cmds = {}
    vim.cmd = function(cmd)
        table.insert(issued_cmds, cmd)
    end
    reset_notify_results()

    ui.show_output("Error: split mode output", "split")

    assert(#issued_cmds > 0, "show_output(split) should open a split window")
    assert(issued_cmds[1] == "topleft split", "show_output(split) should honor top split position")
    assert(#notify_results == 0, "show_output(split) should not fallback to notify")

    vim.cmd = original_cmd
    reset_notify_results()

    print("✓ show_output mode behavior test passed")
end

-- Test vsplit mode honors term.position=left.
local function test_vsplit_respects_left_position()
    config.setup({
        mode = "vsplit",
        term = {
            position = "left",
            focus = true,
            startinsert = false,
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    local original_cmd = vim.cmd
    local issued_cmds = {}

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/vsplit/main.py" end
        return original_expand(expr)
    end
    vim.cmd = function(cmd)
        table.insert(issued_cmds, cmd)
    end

    init.run_code(0, "vsplit")

    assert(#issued_cmds > 0, "vsplit run should issue split command")
    assert(issued_cmds[1] == "topleft vsplit", "vsplit should honor term.position=left")

    vim.fn.expand = original_expand
    vim.cmd = original_cmd
    reset_job_results()

    print("✓ vsplit left-position test passed")
end

-- Test vsplit mode applies configured term.size as window width.
local function test_vsplit_respects_configured_width()
    config.setup({
        mode = "vsplit",
        term = {
            position = "right",
            size = 33,
            focus = true,
            startinsert = false,
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    local original_set_width = vim.api.nvim_win_set_width
    local captured_width = nil

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/vsplit-width/main.py" end
        return original_expand(expr)
    end
    vim.api.nvim_win_set_width = function(_, width)
        captured_width = width
    end

    init.run_code(0, "vsplit")

    assert(captured_width == 33, "vsplit should apply term.size as window width")

    vim.fn.expand = original_expand
    vim.api.nvim_win_set_width = original_set_width
    reset_job_results()

    print("✓ vsplit width test passed")
end

-- Test misconfigured runner command using reserved --argv fails fast with a clear error.
local function test_reserved_argv_runner_guard()
    config.setup({
        runners = {
            python = "--argv python3 $file",
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local output_messages = {}
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/argv_guard/main.py" end
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
    reset_notify_results()

    init.run_code(0, "float")

    assert(#job_results == 0, "Reserved --argv runner should not start a job")
    assert(#notify_results > 0 or #output_messages > 0, "Reserved --argv runner should surface an error")
    local msg = (#notify_results > 0 and notify_results[#notify_results].msg) or output_messages[#output_messages] or ""
    assert(msg:match("%-%-argv"), "Reserved --argv error should mention --argv")

    vim.fn.expand = original_expand
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    reset_notify_results()

    print("✓ Reserved argv runner guard test passed")
end

-- Test misconfigured build command using reserved --argv fails fast with a clear error.
local function test_reserved_argv_build_guard()
    config.setup({
        build_commands = {
            python = {
                run = "--argv python3 $file",
            },
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local output_messages = {}
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/argv_guard/main.py" end
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
    reset_notify_results()

    init.run_build_command("run", "float")

    assert(#job_results == 0, "Reserved --argv build command should not start a job")
    assert(#notify_results > 0 or #output_messages > 0, "Reserved --argv build command should surface an error")
    local msg = (#notify_results > 0 and notify_results[#notify_results].msg) or output_messages[#output_messages] or ""
    assert(msg:match("%-%-argv"), "Reserved --argv build error should mention --argv")

    vim.fn.expand = original_expand
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    reset_notify_results()

    print("✓ Reserved argv build guard test passed")
end

-- Test standalone Zig fallback (no build.zig -> zig run $file)
local function test_zig_standalone_fallback()
    config.setup({
        runners = {
            zig = "zig build run",
        },
    })

    vim.bo.filetype = "zig"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/standalone/main.zig" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function() return 0 end

    init.run_code(0, "float")

    assert(#job_results > 0, "Standalone Zig job was not started")
    local last_job = job_results[#job_results]
    local command = command_to_string(last_job.cmd)
    assert(command:match("zig run"), "Standalone Zig should use zig run")
    assert(not command:match("zig build run"), "Standalone Zig should not use zig build run")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    reset_job_results()

    print("✓ Zig standalone fallback test passed")
end

-- Test Zig project behavior for :RunFile (build-system should win)
local function test_zig_project_runfile()
    config.setup({ mode = "float" })

    vim.bo.filetype = "zig"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/build-system/src/main.zig" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        return path == "/tmp/build-system/build.zig" and 1 or 0
    end

    init.run_code(0, "float")

    assert(#job_results > 0, "Zig project job was not started")
    local last_job = job_results[#job_results]
    local command = command_to_string(last_job.cmd)
    assert(command:match("zig build run"), "Zig project :RunFile should use zig build run")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    reset_job_results()

    print("✓ Zig project RunFile test passed")
end

-- Test precedence: RunFile keeps filetype runner, RunProject uses project command.
local function test_runfile_vs_runproject_precedence()
    config.setup({
        project = {
            ["/tmp/app/.*"] = { name = "App Project", command = "echo project-cmd" },
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/app/src/main.py" end
        return original_expand(expr)
    end

    init.run_code(0, "float")
    assert(#job_results > 0, "RunFile job was not started")
    local runfile_cmd = command_to_string(job_results[#job_results].cmd)
    assert(runfile_cmd:match("python3"), "RunFile should prefer python filetype runner")
    assert(not runfile_cmd:match("project%-cmd"), "RunFile should not use project command in subdir when runner exists")

    reset_job_results()
    init.run_project("float")
    assert(#job_results > 0, "RunProject job was not started")
    local runproject_cmd = command_to_string(job_results[#job_results].cmd)
    assert(runproject_cmd:match("project%-cmd"), "RunProject should use project command")

    vim.fn.expand = original_expand
    reset_job_results()

	print("✓ RunFile vs RunProject precedence test passed")
end

-- Test Go RunFile in project root prefers filetype runner (single-file), not go run .
local function test_go_runfile_prefers_file_runner_at_root()
    config.setup({ mode = "float" })

    vim.bo.filetype = "go"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/goapp/main.go" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        return path == "/tmp/goapp/go.mod" and 1 or 0
    end

    init.run_code(0, "float")
    assert(#job_results > 0, "Go RunFile job was not started")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("go run /tmp/goapp/main%.go"), "Go RunFile should use single-file runner")
    assert(not command:match("go run %."), "Go RunFile should not use go run . at root")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    reset_job_results()

    print("✓ Go RunFile root-priority test passed")
end

-- Test Odin single-file mode uses -file to avoid package-wide main collisions.
local function test_odin_single_file_mode()
    config.setup({ mode = "float" })

    vim.bo.filetype = "odin"
    local original_expand = vim.fn.expand
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/odin/lesson.odin" end
        return original_expand(expr)
    end

    init.run_code(0, "float")
    assert(#job_results > 0, "Odin RunFile job was not started")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("odin run"), "Odin command should use odin run")
    assert(command:match("%-file"), "Odin RunFile should include -file flag")

    vim.fn.expand = original_expand
    reset_job_results()

	print("✓ Odin single-file mode test passed")
end

test_run_build_command_with_detected_zig_fetch_prompt()
test_show_output_respects_mode()
test_vsplit_respects_left_position()
test_vsplit_respects_configured_width()
test_reserved_argv_runner_guard()
test_reserved_argv_build_guard()
test_zig_standalone_fallback()
test_zig_project_runfile()
test_runfile_vs_runproject_precedence()
test_go_runfile_prefers_file_runner_at_root()
test_odin_single_file_mode()
