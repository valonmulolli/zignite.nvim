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

-- Test zig fetch expands a plain GitHub repo URL into the saved git form.
local function test_run_build_command_with_zig_fetch_github_url()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "zig"
    local original_expand = vim.fn.expand
    local original_systemlist = vim.fn.systemlist
    local original_input = vim.fn.input

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/zigfetch/main.zig" end
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
    vim.fn.input = function()
        return "https://github.com/raylib-zig/raylib-zig"
    end

    reset_job_results()
    init.run_build_command("fetch", "float")
    assert(#job_results > 0, "GitHub zig fetch should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(
        command:match("zig fetch %-%-save git%+https://github%.com/raylib%-zig/raylib%-zig"),
        "Plain GitHub URL should expand to --save git+https://github.com/<owner>/<repo>"
    )
    local runtime = require("zignite.runtime")
    local argv = runtime.command_to_argv(
        "zig fetch --save git+https://github.com/raylib-zig/raylib-zig",
        "/tmp/zigfetch/main.zig"
    )
    assert(
        type(argv) == "table" and #argv >= 4,
        "zig fetch GitHub URL should tokenize into separate argv items"
    )
    assert(argv[3] == "--save", "zig fetch should keep --save as a separate argv token")
    assert(
        argv[4] == "git+https://github.com/raylib-zig/raylib-zig",
        "zig fetch should keep the git URL as a separate argv token"
    )

    vim.fn.expand = original_expand
    vim.fn.systemlist = original_systemlist
    vim.fn.input = original_input
    vim.v.shell_error = 0
    reset_job_results()

    print("✓ Zig fetch GitHub URL expansion test passed")
end

-- Test zig fetch keeps a GitHub ref and converts /tree/<ref> URLs.
local function test_run_build_command_with_zig_fetch_github_ref()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "zig"
    local original_expand = vim.fn.expand
    local original_systemlist = vim.fn.systemlist
    local original_input = vim.fn.input

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/zigfetch-ref/main.zig" end
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
    vim.fn.input = function()
        return "https://github.com/raylib-zig/raylib-zig/tree/devel"
    end

    reset_job_results()
    init.run_build_command("fetch", "float")
    assert(#job_results > 0, "GitHub ref zig fetch should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(
        command:match("zig fetch %-%-save git%+https://github%.com/raylib%-zig/raylib%-zig#devel"),
        "GitHub tree URL should expand to a saved git dependency with #ref"
    )
    local runtime = require("zignite.runtime")
    local argv = runtime.command_to_argv(
        "zig fetch --save git+https://github.com/raylib-zig/raylib-zig#devel",
        "/tmp/zigfetch-ref/main.zig"
    )
    assert(
        type(argv) == "table" and #argv >= 4,
        "zig fetch GitHub ref should tokenize into separate argv items"
    )
    assert(argv[3] == "--save", "zig fetch ref should keep --save as a separate argv token")
    assert(
        argv[4] == "git+https://github.com/raylib-zig/raylib-zig#devel",
        "zig fetch ref should keep the git URL and ref as a separate argv token"
    )

    vim.fn.expand = original_expand
    vim.fn.systemlist = original_systemlist
    vim.fn.input = original_input
    vim.v.shell_error = 0
    reset_job_results()

    print("✓ Zig fetch GitHub ref expansion test passed")
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

-- Test Go RunFile in a Go project uses package execution from the file directory.
local function test_go_runfile_prefers_package_runner_at_root()
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
    local last_job = job_results[#job_results]
    local command = command_to_string(last_job.cmd)
    assert(command:match("go run %."), "Go RunFile should use package runner inside a Go project")
    assert(last_job.opts and last_job.opts.cwd == "/tmp/goapp", "Go RunFile should execute from the file directory")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    reset_job_results()

    print("✓ Go RunFile package runner test passed")
end

-- Test Rust RunBuild run prefers an inferred Cargo bin when using the default config.
local function test_rust_runbuild_prefers_inferred_cargo_bin()
    config.setup({ mode = "float" })

    vim.bo.filetype = "rust"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_systemlist = vim.fn.systemlist
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/rustproj/src/main.rs" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/rustproj/Cargo.toml" then
            return 1
        end
        return 0
    end
    vim.fn.systemlist = function(cmd)
        vim.v.shell_error = 0
        if type(cmd) == "table" and cmd[2] == "--project-parse" and cmd[3] == "--kind=cargo" then
            return { "BIN\tdemo\t1" }
        end
        return {}
    end

    init.run_build_command("run", "float")

    assert(#job_results > 0, "Rust RunBuild run job was not started")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("cargo run %-%-bin demo"), "Rust RunBuild run should prefer the inferred Cargo bin")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.systemlist = original_systemlist
    vim.v.shell_error = 0
    reset_job_results()

    print("✓ Rust RunBuild inferred Cargo bin test passed")
end

-- Test standalone Go files still use single-file execution outside a Go project.
local function test_go_runfile_standalone_single_file_mode()
    config.setup({ mode = "float" })

    vim.bo.filetype = "go"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/gostandalone/hello.go" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(_path)
        return 0
    end

    init.run_code(0, "float")
    assert(#job_results > 0, "Standalone Go RunFile job was not started")
    local last_job = job_results[#job_results]
    local command = command_to_string(last_job.cmd)
    assert(command:match("go run /tmp/gostandalone/hello%.go"), "Standalone Go RunFile should use single-file runner")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    reset_job_results()

    print("✓ Go RunFile standalone test passed")
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
test_run_build_command_with_zig_fetch_github_url()
test_run_build_command_with_zig_fetch_github_ref()
test_show_output_respects_mode()
test_vsplit_respects_left_position()
test_vsplit_respects_configured_width()
test_reserved_argv_runner_guard()
test_reserved_argv_build_guard()
test_zig_standalone_fallback()
test_zig_project_runfile()
test_go_runfile_prefers_package_runner_at_root()
test_rust_runbuild_prefers_inferred_cargo_bin()
test_go_runfile_standalone_single_file_mode()
test_odin_single_file_mode()
