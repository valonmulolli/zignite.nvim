-- luacheck: globals project_root config init ui state job_results quickfix_results notify_results mock_jobs
-- luacheck: globals command_to_string reset_job_results reset_quickfix_results reset_notify_results
-- luacheck: globals count_quickfix_backend_jobs count_quickfix_daemon_jobs
-- luacheck: globals count_detect_backend_jobs count_detect_backend_requests
-- luacheck: globals get_upvalue_by_name detect_backend_tool_commands is_detect_daemon_cmd parse_detect_daemon_request

-- Test Lua quickfix generation on non-zero exits strips ANSI and tails lines.
local function test_quickfix_on_error_lua_processor()
    config.setup({
        mode = "float",
        quickfix = {
            enabled = true,
            processor = "lua",
            max_lines = 2,
            max_bytes = 1024,
            strip_ansi = true,
            strip_ansi_max_lines = 2,
            async_strip = true,
            strip_chunk_size = 1,
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    local original_line_count = vim.api.nvim_buf_line_count
    local original_get_lines = vim.api.nvim_buf_get_lines
    local test_lines = {
        "line-1",
        "\27[31merror-2\27[0m",
        "\27[33merror-3\27[0m",
    }

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/qf/main.py" end
        return original_expand(expr)
    end
    vim.api.nvim_buf_line_count = function() return #test_lines end
    vim.api.nvim_buf_get_lines = function(_, start_idx, _, _)
        local out = {}
        for i = start_idx + 1, #test_lines do
            table.insert(out, test_lines[i])
        end
        return out
    end

    state.next_exit_code = 1
    init.run_code(0, "float")

    assert(#quickfix_results > 0, "Quickfix should be populated on non-zero exit")
    local qf = quickfix_results[#quickfix_results]
    assert(#qf.lines == 3, "Quickfix should include truncation notice plus tailed lines")
    assert(qf.lines[1] == "[zignite] quickfix output truncated", "Quickfix should include truncation notice")
    assert(not qf.lines[2]:match("\27"), "Quickfix line should be ANSI-stripped")
    assert(not qf.lines[3]:match("\27"), "Quickfix line should be ANSI-stripped")
    assert(count_quickfix_backend_jobs() == 0, "Lua processor should not spawn zig quickfix backend")

    state.next_exit_code = 0
    vim.fn.expand = original_expand
    vim.api.nvim_buf_line_count = original_line_count
    vim.api.nvim_buf_get_lines = original_get_lines
    reset_job_results()
    reset_quickfix_results()

    print("✓ Quickfix Lua processor test passed")
end

-- Test explicit zig processor path is used for quickfix generation.
local function test_quickfix_zig_processor()
    config.setup({
        mode = "float",
        quickfix = {
            enabled = true,
            processor = "zig",
            max_lines = 2,
            max_bytes = 1024,
            strip_ansi = true,
            strip_ansi_max_lines = 2,
            parse_diagnostics = false,
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    local original_line_count = vim.api.nvim_buf_line_count
    local original_get_lines = vim.api.nvim_buf_get_lines
    local test_lines = {
        "line-1",
        "\27[31merror-2\27[0m",
        "\27[33merror-3\27[0m",
    }

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/qf/main.py" end
        return original_expand(expr)
    end
    vim.api.nvim_buf_line_count = function() return #test_lines end
    vim.api.nvim_buf_get_lines = function(_, start_idx, _, _)
        local out = {}
        for i = start_idx + 1, #test_lines do
            table.insert(out, test_lines[i])
        end
        return out
    end

    state.next_exit_code = 1
    init.run_code(0, "float")

    assert(count_quickfix_daemon_jobs() > 0, "Zig processor should start quickfix daemon worker")
    assert(count_quickfix_backend_jobs() > 0, "Zig processor should spawn quickfix backend")
    assert(#quickfix_results > 0, "Quickfix should be populated on zig processor path")
    local qf = quickfix_results[#quickfix_results]
    assert(qf.lines[1] == "[zignite] quickfix output truncated", "Zig quickfix should include truncation notice")
    assert(qf.lines[2] == "error-2", "Zig processor should strip ANSI from retained lines")
    assert(qf.lines[3] == "error-3", "Zig processor should strip ANSI from retained lines")

    state.next_exit_code = 0
    vim.fn.expand = original_expand
    vim.api.nvim_buf_line_count = original_line_count
    vim.api.nvim_buf_get_lines = original_get_lines
    reset_job_results()
    reset_quickfix_results()

    print("✓ Quickfix zig processor test passed")
end

-- Test explicit zig one-shot quickfix path works when the daemon worker is disabled.
local function test_quickfix_zig_one_shot_processor()
    config.setup({
        mode = "float",
        quickfix = {
            enabled = true,
            processor = "zig",
            zig_worker = false,
            max_lines = 2,
            max_bytes = 1024,
            strip_ansi = true,
            strip_ansi_max_lines = 2,
            parse_diagnostics = false,
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    local original_line_count = vim.api.nvim_buf_line_count
    local original_get_lines = vim.api.nvim_buf_get_lines
    local test_lines = {
        "line-1",
        "\27[31merror-2\27[0m",
        "\27[33merror-3\27[0m",
    }

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/qf/main.py" end
        return original_expand(expr)
    end
    vim.api.nvim_buf_line_count = function() return #test_lines end
    vim.api.nvim_buf_get_lines = function(_, start_idx, _, _)
        local out = {}
        for i = start_idx + 1, #test_lines do
            table.insert(out, test_lines[i])
        end
        return out
    end

    state.next_exit_code = 1
    init.run_code(0, "float")

    assert(count_quickfix_daemon_jobs() == 0, "One-shot quickfix path should not start the quickfix daemon")
    assert(count_quickfix_backend_jobs() > 0, "One-shot quickfix path should still execute the Zig backend")
    assert(#quickfix_results > 0, "One-shot quickfix path should populate quickfix output")
    local qf = quickfix_results[#quickfix_results]
    assert(qf.lines[1] == "[zignite] quickfix output truncated", "One-shot quickfix should include truncation notice")
    assert(qf.lines[2] == "error-2", "One-shot quickfix should strip ANSI from retained lines")
    assert(qf.lines[3] == "error-3", "One-shot quickfix should strip ANSI from retained lines")

    state.next_exit_code = 0
    vim.fn.expand = original_expand
    vim.api.nvim_buf_line_count = original_line_count
    vim.api.nvim_buf_get_lines = original_get_lines
    reset_job_results()
    reset_quickfix_results()

    print("✓ Quickfix zig one-shot processor test passed")
end

-- Test setup resets cached quickfix backend availability after the Zig binary becomes available.
local function test_quickfix_backend_availability_resets_on_setup()
    local quickfix_config = {
        mode = "float",
        quickfix = {
            enabled = true,
            processor = "zig",
            max_lines = 2,
            max_bytes = 1024,
            strip_ansi = true,
            strip_ansi_max_lines = 2,
            parse_diagnostics = false,
        },
    }

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    local original_executable = vim.fn.executable
    local original_line_count = vim.api.nvim_buf_line_count
    local original_get_lines = vim.api.nvim_buf_get_lines
    local test_lines = {
        "line-1",
        "\27[31merror-2\27[0m",
        "\27[33merror-3\27[0m",
    }

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/qf/main.py" end
        return original_expand(expr)
    end
    vim.fn.executable = function(path)
        if type(path) == "string" and path:match("zig/zig%-out/bin/zignite$") then
            return 0
        end
        if original_executable then
            return original_executable(path)
        end
        return 0
    end
    vim.api.nvim_buf_line_count = function() return #test_lines end
    vim.api.nvim_buf_get_lines = function(_, start_idx, _, _)
        local out = {}
        for i = start_idx + 1, #test_lines do
            table.insert(out, test_lines[i])
        end
        return out
    end

    init.setup(quickfix_config)
    state.next_exit_code = 1
    init.run_code(0, "float")
    assert(count_quickfix_backend_jobs() == 0, "Quickfix should fall back when backend is unavailable")

    reset_job_results()
    reset_quickfix_results()
    vim.fn.executable = function(path)
        if type(path) == "string" and path:match("zig/zig%-out/bin/zignite$") then
            return 1
        end
        if original_executable then
            return original_executable(path)
        end
        return 1
    end

    init.setup(quickfix_config)
    init.run_code(0, "float")
    assert(count_quickfix_backend_jobs() > 0, "Setup should reset cached quickfix backend availability")

    state.next_exit_code = 0
    vim.fn.expand = original_expand
    vim.fn.executable = original_executable
    vim.api.nvim_buf_line_count = original_line_count
    vim.api.nvim_buf_get_lines = original_get_lines
    reset_job_results()
    reset_quickfix_results()

    print("✓ Quickfix backend reset test passed")
end

-- Test zig quickfix processor keeps newest lines when max_bytes truncates input.
local function test_quickfix_zig_processor_keeps_tail_on_byte_cap()
    config.setup({
        mode = "float",
        quickfix = {
            enabled = true,
            processor = "zig",
            max_lines = 10,
            max_bytes = 12,
            strip_ansi = false,
            strip_ansi_max_lines = 10,
            parse_diagnostics = false,
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    local original_line_count = vim.api.nvim_buf_line_count
    local original_get_lines = vim.api.nvim_buf_get_lines
    local test_lines = {
        "first-line",
        "second-line",
        "newest-line",
    }

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/qf/main.py" end
        return original_expand(expr)
    end
    vim.api.nvim_buf_line_count = function() return #test_lines end
    vim.api.nvim_buf_get_lines = function(_, start_idx, _, _)
        local out = {}
        for i = start_idx + 1, #test_lines do
            table.insert(out, test_lines[i])
        end
        return out
    end

    state.next_exit_code = 1
    init.run_code(0, "float")

    assert(#quickfix_results > 0, "Zig quickfix should populate results under byte cap")
    local qf = quickfix_results[#quickfix_results]
    assert(qf.lines[1] == "[zignite] quickfix output truncated", "Zig quickfix should include truncation notice")
    assert(qf.lines[2] == "newest-line", "Zig quickfix should keep newest line under byte cap")
    assert(qf.lines[3] == nil, "Zig quickfix should drop older lines once byte cap is reached")

    state.next_exit_code = 0
    vim.fn.expand = original_expand
    vim.api.nvim_buf_line_count = original_line_count
    vim.api.nvim_buf_get_lines = original_get_lines
    reset_job_results()
    reset_quickfix_results()

    print("✓ Quickfix zig byte-tail test passed")
end

-- Test auto processor routes to Lua below threshold and Zig above threshold.
local function test_quickfix_auto_threshold_behavior()
    require("zignite.ui.quickfix").reset()
    local quickfix_module = require("zignite.ui.quickfix")
    local choose_quickfix_processor =
        get_upvalue_by_name(quickfix_module.populate_from_buffer, "choose_quickfix_processor")
    local original_expand = vim.fn.expand
    local original_line_count = vim.api.nvim_buf_line_count
    local original_get_lines = vim.api.nvim_buf_get_lines

    vim.bo.filetype = "python"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/qf/main.py" end
        return original_expand(expr)
    end

    config.setup({
        mode = "float",
        quickfix = {
            enabled = true,
            processor = "auto",
            zig_min_lines = 5,
            max_lines = 5,
            strip_ansi = true,
            strip_ansi_max_lines = 5,
            parse_diagnostics = false,
        },
    })
    reset_job_results()
    reset_quickfix_results()

    local small_lines = {
        "line-1",
        "\27[31mline-2\27[0m",
        "line-3",
    }
    vim.api.nvim_buf_line_count = function() return #small_lines end
    vim.api.nvim_buf_get_lines = function(_, start_idx, _, _)
        local out = {}
        for i = start_idx + 1, #small_lines do
            table.insert(out, small_lines[i])
        end
        return out
    end

    assert(type(choose_quickfix_processor) == "function", "Quickfix test should be able to inspect processor selection")
    assert(
        choose_quickfix_processor(config.options.quickfix, #small_lines) == "lua",
        "Auto mode should select the Lua quickfix processor below threshold"
    )

    state.next_exit_code = 1
    reset_job_results()
    reset_quickfix_results()

    local large_lines = {}
    for i = 1, 8 do
        large_lines[i] = string.format("\27[31mline-%d\27[0m", i)
    end
    vim.api.nvim_buf_line_count = function() return #large_lines end
    vim.api.nvim_buf_get_lines = function(_, start_idx, _, _)
        local out = {}
        for i = start_idx + 1, #large_lines do
            table.insert(out, large_lines[i])
        end
        return out
    end

    assert(
        choose_quickfix_processor(config.options.quickfix, #large_lines) == "zig",
        "Auto mode should select the Zig quickfix processor above threshold"
    )

    init.run_code(0, "float")
    assert(count_quickfix_backend_jobs() > 0, "Auto mode should use zig processor above threshold")

    state.next_exit_code = 0
    vim.fn.expand = original_expand
    vim.api.nvim_buf_line_count = original_line_count
    vim.api.nvim_buf_get_lines = original_get_lines
    reset_job_results()
    reset_quickfix_results()

    print("✓ Quickfix auto threshold test passed")
end

-- Test zig quickfix processor falls back to Lua when zig backend fails.
local function test_quickfix_zig_fallback()
    config.setup({
        mode = "float",
        quickfix = {
            enabled = true,
            processor = "zig",
            max_lines = 2,
            strip_ansi = true,
            strip_ansi_max_lines = 2,
            parse_diagnostics = false,
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    local original_line_count = vim.api.nvim_buf_line_count
    local original_get_lines = vim.api.nvim_buf_get_lines
    local test_lines = {
        "line-1",
        "\27[31merror-2\27[0m",
        "\27[33merror-3\27[0m",
    }

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/qf/main.py" end
        return original_expand(expr)
    end
    vim.api.nvim_buf_line_count = function() return #test_lines end
    vim.api.nvim_buf_get_lines = function(_, start_idx, _, _)
        local out = {}
        for i = start_idx + 1, #test_lines do
            table.insert(out, test_lines[i])
        end
        return out
    end

    state.next_quickfix_backend_exit_code = 1
    state.next_exit_code = 1
    init.run_code(0, "float")

    assert(#quickfix_results > 0, "Lua fallback should populate quickfix after zig failure")
    local qf = quickfix_results[#quickfix_results]
    assert(not qf.lines[1]:match("\27"), "Lua fallback should still strip ANSI codes")

    state.next_exit_code = 0
    vim.fn.expand = original_expand
    vim.api.nvim_buf_line_count = original_line_count
    vim.api.nvim_buf_get_lines = original_get_lines
    reset_job_results()
    reset_quickfix_results()

    print("✓ Quickfix zig fallback test passed")
end

-- Test worker-mode protocol errors fall back cleanly to Lua quickfix generation.
local function test_quickfix_zig_protocol_error_fallback()
    config.setup({
        mode = "float",
        quickfix = {
            enabled = true,
            processor = "zig",
            max_lines = 2,
            max_bytes = 1024,
            strip_ansi = true,
            strip_ansi_max_lines = 2,
            parse_diagnostics = false,
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    local original_line_count = vim.api.nvim_buf_line_count
    local original_get_lines = vim.api.nvim_buf_get_lines
    local test_lines = {
        "line-1",
        "\27[31merror-2\27[0m",
        "\27[33merror-3\27[0m",
    }

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/qf/main.py" end
        return original_expand(expr)
    end
    vim.api.nvim_buf_line_count = function() return #test_lines end
    vim.api.nvim_buf_get_lines = function(_, start_idx, _, _)
        local out = {}
        for i = start_idx + 1, #test_lines do
            table.insert(out, test_lines[i])
        end
        return out
    end

    state.next_quickfix_backend_error = "QuickfixBoom"
    state.next_exit_code = 1
    init.run_code(0, "float")

    assert(count_quickfix_daemon_jobs() > 0, "Worker quickfix path should still use the daemon")
    assert(count_quickfix_backend_jobs() > 0, "Worker quickfix path should receive a backend response")
    assert(#quickfix_results > 0, "Lua fallback should populate quickfix after protocol error")
    local qf = quickfix_results[#quickfix_results]
    assert(not qf.lines[1]:match("\27"), "Lua fallback should still strip ANSI codes")

    state.next_exit_code = 0
    vim.fn.expand = original_expand
    vim.api.nvim_buf_line_count = original_line_count
    vim.api.nvim_buf_get_lines = original_get_lines
    reset_job_results()
    reset_quickfix_results()

    print("✓ Quickfix zig protocol error fallback test passed")
end

-- Test zig diagnostic parser canonicalizes common compiler formats.
local function test_quickfix_zig_diagnostic_parser()
    config.setup({
        mode = "float",
        quickfix = {
            enabled = true,
            processor = "zig",
            max_lines = 5,
            strip_ansi = false,
            parse_diagnostics = true,
        },
    })

    vim.bo.filetype = "python"
    local original_expand = vim.fn.expand
    local original_line_count = vim.api.nvim_buf_line_count
    local original_get_lines = vim.api.nvim_buf_get_lines
    local test_lines = {
        "src/main.c:10:5: error: expected ';' after expression",
        " --> src/lib.rs:7:3",
        "/tmp/sample.odin(8:1) Error: Redeclaration of 'main'",
    }

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/qf/main.py" end
        return original_expand(expr)
    end
    vim.api.nvim_buf_line_count = function() return #test_lines end
    vim.api.nvim_buf_get_lines = function(_, start_idx, _, _)
        local out = {}
        for i = start_idx + 1, #test_lines do
            table.insert(out, test_lines[i])
        end
        return out
    end

    state.next_exit_code = 1
    init.run_code(0, "float")

    assert(#quickfix_results > 0, "Zig diagnostic parser should populate quickfix lines")
    local qf = quickfix_results[#quickfix_results]
    assert(qf.lines[1]:match("^src/main%.c:10:5:"), "GCC/Clang diagnostic should be canonicalized")
    assert(qf.lines[2]:match("^src/lib%.rs:7:3:"), "Rust arrow diagnostic should be canonicalized")
    assert(qf.lines[3]:match("^/tmp/sample%.odin:8:1:"), "Paren diagnostics should be canonicalized")

    state.next_exit_code = 0
    vim.fn.expand = original_expand
    vim.api.nvim_buf_line_count = original_line_count
    vim.api.nvim_buf_get_lines = original_get_lines
    reset_job_results()
    reset_quickfix_results()

	print("✓ Quickfix zig diagnostic parser test passed")
end

test_quickfix_on_error_lua_processor()
test_quickfix_zig_processor()
test_quickfix_zig_one_shot_processor()
test_quickfix_backend_availability_resets_on_setup()
test_quickfix_zig_processor_keeps_tail_on_byte_cap()
test_quickfix_auto_threshold_behavior()
test_quickfix_zig_fallback()
test_quickfix_zig_protocol_error_fallback()
test_quickfix_zig_diagnostic_parser()
