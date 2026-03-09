-- luacheck: globals project_root config init ui state job_results quickfix_results notify_results mock_jobs
-- luacheck: globals command_to_string reset_job_results reset_quickfix_results reset_notify_results
-- luacheck: globals count_quickfix_backend_jobs count_quickfix_daemon_jobs
-- luacheck: globals count_detect_backend_jobs count_detect_backend_requests
-- luacheck: globals get_upvalue_by_name detect_backend_tool_commands is_detect_daemon_cmd parse_detect_daemon_request

-- Test float focus=false keeps cursor in current window and avoids startinsert.
local function test_float_focus_behavior()
    local original_expand = vim.fn.expand
    local original_open_win = vim.api.nvim_open_win
    local original_cmd = vim.cmd
    local opened_enter = nil
    local opened_footer = nil
    local startinsert_calls = 0

    config.setup({
        mode = "float",
        float = {
            focus = false,
            startinsert = true,
            close_key = "<Esc>",
        },
    })

    vim.bo.filetype = "python"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/focus/main.py" end
        return original_expand(expr)
    end
    vim.api.nvim_open_win = function(_, enter, opts)
        opened_enter = enter
        opened_footer = opts and opts.footer or ""
        return 1
    end
    vim.cmd = function(cmd)
        if cmd == "startinsert" then
            startinsert_calls = startinsert_calls + 1
        end
    end

    init.run_code(0, "float")

    assert(opened_enter == false, "Float runner should respect float.focus=false")
    assert(startinsert_calls == 0, "Float runner should not startinsert when not focused")
    assert(opened_footer:match("Esc: close"), "Float footer should show configured close key")

    vim.fn.expand = original_expand
    vim.api.nvim_open_win = original_open_win
    vim.cmd = original_cmd
    reset_job_results()

    print("✓ Float focus behavior test passed")
end

-- Test picker warns and exits when filtering removes all build commands.
local function test_build_picker_empty_state()
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_open_win = vim.api.nvim_open_win
    local open_win_calls = 0

    config.setup({
        build_commands = {
            testft = {
                ["meson-build"] = "meson compile -C build",
            },
        },
    })

    vim.bo.filetype = "testft"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/picker/main.testft" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        return path:match("CMakeLists.txt$") and 1 or 0
    end
    vim.api.nvim_open_win = function(...)
        open_win_calls = open_win_calls + 1
        return original_open_win(...)
    end
    reset_notify_results()

    init.select_build_command("float")

    assert(open_win_calls == 0, "Picker should not open when no commands are available")
    assert(#notify_results > 0, "Picker should notify when command list is empty")
    assert(
        notify_results[#notify_results].msg:match("No build commands available"),
        "Picker empty warning should mention no build commands"
    )

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.api.nvim_open_win = original_open_win
    reset_notify_results()

    print("✓ Build picker empty-state test passed")
end

-- Test non-C pickers keep generic commands visible even in mixed build-system repos.
local function test_build_picker_keeps_generic_commands_in_mixed_repo()
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local original_open_win = vim.api.nvim_open_win
    local rendered_lines = {}
    local open_win_calls = 0

    config.setup({
        build_commands = {
            testft = {
                run = "echo run",
                ["cmake-build"] = "cmake --build build",
            },
        },
    })

    vim.bo.filetype = "testft"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/mixed/main.testft" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        return path:match("CMakeLists.txt$") and 1 or 0
    end
    vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
        if type(lines) == "table" and #lines > 0 then
            rendered_lines = lines
        end
        if original_buf_set_lines then
            return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
        end
    end
    vim.api.nvim_open_win = function(...)
        open_win_calls = open_win_calls + 1
        return original_open_win(...)
    end

    init.select_build_command("float")

    local render = table.concat(rendered_lines, "\n")
    assert(open_win_calls > 0, "Picker should open when generic commands remain available")
    assert(render:match("run"), "Picker should keep generic commands visible in mixed repos")
    assert(render:match("cmake%-build"), "Picker should keep matching CMake commands visible")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    vim.api.nvim_open_win = original_open_win

    print("✓ Build picker mixed-repo generic command test passed")
end

-- Test picker window coordinates are clamped on very small editor sizes.
local function test_build_picker_window_clamped()
    local original_expand = vim.fn.expand
    local original_open_win = vim.api.nvim_open_win
    local original_columns = vim.o.columns
    local original_lines = vim.o.lines
    local captured_opts = nil

    config.setup({
        build_commands = {
            tinyft = {
                run = "echo tiny",
            },
        },
        float = {
            y = 0,
        },
    })

    vim.bo.filetype = "tinyft"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/picker/main.tinyft" end
        return original_expand(expr)
    end
    vim.o.columns = 2
    vim.o.lines = 4
    vim.api.nvim_open_win = function(_, _, opts)
        captured_opts = opts
        return 1
    end

    init.select_build_command("float")

    assert(captured_opts ~= nil, "Picker should open for available commands")
    assert(captured_opts.row >= 0, "Picker row should be clamped to non-negative values")
    assert(captured_opts.col >= 0, "Picker col should be clamped to non-negative values")

    vim.fn.expand = original_expand
    vim.api.nvim_open_win = original_open_win
    vim.o.columns = original_columns
    vim.o.lines = original_lines

    print("✓ Build picker clamp test passed")
end

-- Test build picker keeps focus by default (independent of float.focus).
local function test_build_picker_focus_behavior()
    local original_expand = vim.fn.expand
    local original_open_win = vim.api.nvim_open_win
    local opened_enter = nil

    config.setup({
        build_commands = {
            tinyft = {
                run = "echo tiny",
            },
        },
        float = {
            focus = false,
        },
    })

    vim.bo.filetype = "tinyft"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/picker/main.tinyft" end
        return original_expand(expr)
    end
    vim.api.nvim_open_win = function(_, enter, _)
        opened_enter = enter
        return 1
    end

    init.select_build_command("float")

    assert(opened_enter == true, "Build picker should focus by default even when float.focus=false")

    vim.fn.expand = original_expand
    vim.api.nvim_open_win = original_open_win

    print("✓ Build picker focus behavior test passed")
end

-- Test build picker can be explicitly unfocused via picker.focus=false.
local function test_build_picker_focus_override()
    local original_expand = vim.fn.expand
    local original_open_win = vim.api.nvim_open_win
    local opened_enter = nil

    config.setup({
        build_commands = {
            tinyft = {
                run = "echo tiny",
            },
        },
        picker = {
            focus = false,
        },
    })

    vim.bo.filetype = "tinyft"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/picker/main.tinyft" end
        return original_expand(expr)
    end
    vim.api.nvim_open_win = function(_, enter, _)
        opened_enter = enter
        return 1
    end

    init.select_build_command("float")

    assert(opened_enter == false, "Build picker should respect picker.focus=false")

    vim.fn.expand = original_expand
    vim.api.nvim_open_win = original_open_win

    print("✓ Build picker focus override test passed")
end

-- Test build picker supports filter prompt and full command preview line.
local function test_build_picker_filter_and_preview()
    local original_expand = vim.fn.expand
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local original_keymap = vim.keymap
    local original_input = vim.fn.input
    local mapped = {}
    local latest_lines = {}
    local next_input = "run"

    config.setup({
        build_commands = {
            tinyft = {
                ["aaa-long"] = "echo very-long-command-preview-segment-end",
                run = "echo run",
            },
        },
    })

    vim.bo.filetype = "tinyft"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/picker/main.tinyft" end
        return original_expand(expr)
    end
    vim.fn.input = function(_, default)
        return next_input or default
    end
    vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
        latest_lines = lines or {}
        if original_buf_set_lines then
            return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
        end
    end
    vim.keymap = {
        set = function(_, lhs, rhs, _opts)
            mapped[lhs] = rhs
        end,
    }

    init.select_build_command("float")

    assert(type(mapped["/"]) == "function", "Picker should map '/' for filtering")
    assert(#latest_lines > 0, "Picker should render lines")
    assert(latest_lines[#latest_lines]:match("segment%-end"), "Picker preview should include full command text")

    mapped["/"]()
    assert(latest_lines[1]:match("Filter:%s+run"), "Picker should update filter header after '/' input")

    vim.fn.expand = original_expand
    vim.fn.input = original_input
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    vim.keymap = original_keymap

    print("✓ Build picker filter/preview test passed")
end

-- Test picker can force filter prompt to command-line input even when vim.ui.input exists.
local function test_build_picker_filter_cmdline_mode()
    local original_expand = vim.fn.expand
    local original_keymap = vim.keymap
    local original_input = vim.fn.input
    local original_ui = vim.ui
    local mapped = {}
    local cmdline_calls = 0
    local ui_calls = 0

    config.setup({
        build_commands = {
            tinyft = {
                run = "echo run",
                test = "echo test",
            },
        },
        picker = {
            filter_input = "cmdline",
        },
    })

    vim.bo.filetype = "tinyft"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/picker/main.tinyft" end
        return original_expand(expr)
    end
    vim.fn.input = function(_, default)
        cmdline_calls = cmdline_calls + 1
        return default or ""
    end
    vim.ui = {
        input = function(_, cb)
            ui_calls = ui_calls + 1
            if cb then
                cb("")
            end
        end,
    }
    vim.keymap = {
        set = function(_, lhs, rhs, _opts)
            mapped[lhs] = rhs
        end,
    }

    init.select_build_command("float")

    assert(type(mapped["/"]) == "function", "Picker should map '/' for filtering")
    mapped["/"]()
    assert(cmdline_calls == 1, "Picker should use vim.fn.input when picker.filter_input='cmdline'")
    assert(ui_calls == 0, "Picker should not call vim.ui.input when picker.filter_input='cmdline'")

    vim.fn.expand = original_expand
    vim.fn.input = original_input
    vim.ui = original_ui
    vim.keymap = original_keymap

    print("✓ Build picker cmdline filter mode test passed")
end

-- Test picker inline filter mode captures text in-picker without ui/cmdline prompts.
local function test_build_picker_filter_inline_mode()
    local original_expand = vim.fn.expand
    local original_keymap = vim.keymap
    local original_getcharstr = vim.fn.getcharstr
    local original_input = vim.fn.input
    local original_ui = vim.ui
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local mapped = {}
    local latest_lines = {}
    local cmdline_calls = 0
    local ui_calls = 0
    local idx = 1
    local keys = { "r", "u", "n", "\r" }

    config.setup({
        build_commands = {
            tinyft = {
                run = "echo run",
                test = "echo test",
            },
        },
        picker = {
            filter_input = "inline",
        },
    })

    vim.bo.filetype = "tinyft"
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/picker/main.tinyft" end
        return original_expand(expr)
    end
    vim.fn.getcharstr = function()
        local key = keys[idx]
        idx = idx + 1
        return key
    end
    vim.fn.input = function(_, default)
        cmdline_calls = cmdline_calls + 1
        return default or ""
    end
    vim.ui = {
        input = function(_, cb)
            ui_calls = ui_calls + 1
            if cb then
                cb("")
            end
        end,
    }
    vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
        latest_lines = lines or {}
        if original_buf_set_lines then
            return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
        end
    end
    vim.keymap = {
        set = function(_, lhs, rhs, _opts)
            mapped[lhs] = rhs
        end,
    }

    init.select_build_command("float")

    assert(type(mapped["/"]) == "function", "Picker should map '/' for filtering")
    mapped["/"]()
    assert(latest_lines[1]:match("Filter:%s+run"), "Inline filter should update picker header query")
    assert(cmdline_calls == 0, "Inline filter should not use vim.fn.input")
    assert(ui_calls == 0, "Inline filter should not use vim.ui.input")

    vim.fn.expand = original_expand
    vim.fn.getcharstr = original_getcharstr
    vim.fn.input = original_input
    vim.ui = original_ui
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    vim.keymap = original_keymap

    print("✓ Build picker inline filter mode test passed")
end

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

-- Test picker path never relies on vim.wait when async picker mode is enabled.
---@return nil
local function test_picker_async_path_without_wait()
	init.setup({
		build_commands = {},
		detect_runtime = {
			async_picker = true,
			cache_ttl_ms = 15000,
			live_merge = true,
		},
	})

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_open_win = vim.api.nvim_open_win
	local original_wait = vim.wait
	local picker_opened = false
	local wait_called = false

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/asyncwait/main.go"
		end
		return original_expand(expr)
	end
	vim.api.nvim_open_win = function(...)
		picker_opened = true
		return original_open_win(...)
	end
	vim.wait = function()
		wait_called = true
		error("picker async path should not call vim.wait")
	end

	local ok, err = pcall(init.select_build_command, "float")
	assert(ok, "Picker should open without vim.wait dependency: " .. tostring(err))
	assert(picker_opened, "Picker should still open in async mode")
	assert(not wait_called, "Async picker path should never call vim.wait")

	vim.fn.expand = original_expand
	vim.api.nvim_open_win = original_open_win
	vim.wait = original_wait

	print("✓ Picker async no-wait test passed")
end

-- Test RunBuild uses async detection fallback instead of sync vim.wait when
-- a detected command is not yet cached.
---@return nil
local function test_run_build_async_detect_without_wait()
	init.setup({
		build_commands = {},
		detect_runtime = {
			async_picker = true,
			cache_ttl_ms = 15000,
			live_merge = true,
		},
	})

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_wait = vim.wait

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/async-build/main.go"
		end
		return original_expand(expr)
	end
	vim.wait = function()
		error("run_build_command should not call vim.wait")
	end

	reset_job_results()
	local ok, err = pcall(init.run_build_command, "fmt", "float")
	assert(ok, "RunBuild should resolve detected commands without vim.wait: " .. tostring(err))
	assert(#job_results > 0, "RunBuild should start a job for detected command")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("go fmt"), "RunBuild should execute detected go fmt command")

	vim.fn.expand = original_expand
	vim.wait = original_wait
	reset_job_results()

	print("✓ RunBuild async detect test passed")
end

-- Test RunBuild completion stays non-blocking and uses literal prefix matching.
---@return nil
local function test_run_build_completion_nonblocking_prefix()
	local original_create_user_command = vim.api.nvim_create_user_command
	local original_expand = vim.fn.expand
	local original_wait = vim.wait
	local commands = {}

	config.setup({
		build_commands = {
			cpp = {
				["c++"] = "zig c++",
				clean = "make clean",
			},
		},
	})

	vim.bo.filetype = "cpp"
	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/completion/main.cpp"
		end
		return original_expand(expr)
	end
	vim.wait = function()
		error("completion should not call vim.wait")
	end
	vim.api.nvim_create_user_command = function(name, fn, opts)
		commands[name] = { fn = fn, opts = opts }
	end
	vim.g = vim.g or {}
	vim.g.loaded_zignite = nil

	dofile(project_root .. "/plugin/zignite.lua")

	assert(commands.RunBuild ~= nil, "Plugin should register RunBuild command")
	local matches = commands.RunBuild.opts.complete("c+", "", 0)
	assert(#matches == 1 and matches[1] == "c++", "RunBuild completion should use literal prefix matching")

	vim.api.nvim_create_user_command = original_create_user_command
	vim.fn.expand = original_expand
	vim.wait = original_wait
	vim.g.loaded_zignite = nil

	print("✓ RunBuild completion nonblocking prefix test passed")
end

-- Test picker opens from immediate commands then live-merges async detected commands.
---@return nil
local function test_picker_async_live_merge_refresh()
	init.setup({
		build_commands = {
			go = {
				build = "go build",
			},
		},
		detect_runtime = {
			async_picker = true,
			cache_ttl_ms = 1,
			live_merge = true,
		},
	})

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_chansend_fn = vim.fn.chansend
	local original_buf_set_lines = vim.api.nvim_buf_set_lines
	local rendered_lines = {}
	local deferred_detect = nil

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/asyncrefresh/main.go"
		end
		return original_expand(expr)
	end
	vim.api.nvim_buf_set_lines = function(buf, start_idx, end_idx, strict, lines)
		if type(lines) == "table" and #lines > 0 then
			rendered_lines = lines
		end
		if original_buf_set_lines then
			return original_buf_set_lines(buf, start_idx, end_idx, strict, lines)
		end
	end
	vim.fn.chansend = function(job_id, data)
		local job = mock_jobs[job_id]
		if job and is_detect_daemon_cmd(job.cmd) then
			local text = type(data) == "table" and table.concat(data) or tostring(data or "")
			deferred_detect = {
				job_id = job_id,
				opts = job.opts,
				response = parse_detect_daemon_request(text),
			}
			state.detect_backend_invocations = state.detect_backend_invocations + 1
			return 1
		end
		return original_chansend_fn(job_id, data)
	end

	reset_job_results()
	init.select_build_command("float")

	local initial_render = table.concat(rendered_lines, "\n")
	assert(initial_render:match("cmd:%s+go build"), "Initial picker render should keep selected command preview")
	assert(not initial_render:match("go env"), "Initial picker render should not include deferred detected commands")
	assert(deferred_detect and deferred_detect.opts and deferred_detect.response, "Detect response should be deferred")

	deferred_detect.opts.on_stdout(deferred_detect.job_id, deferred_detect.response)
	local refreshed_render = table.concat(rendered_lines, "\n")
	assert(refreshed_render:match("go env"), "Live refresh should merge detected commands into picker")
	assert(refreshed_render:match("cmd:%s+go build"), "Live refresh should preserve selected command preview")

	vim.fn.expand = original_expand
	vim.fn.chansend = original_chansend_fn
	vim.api.nvim_buf_set_lines = original_buf_set_lines

	print("✓ Picker async live-merge refresh test passed")
end

-- Test picker detection cache invalidation uses TTL and mtime signature.
---@return nil
local function test_picker_detection_cache_ttl_and_mtime()
	init.setup({
		build_commands = {},
		detect_runtime = {
			async_picker = true,
			cache_ttl_ms = 15000,
			live_merge = false,
		},
	})

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_exepath = vim.fn.exepath
	local original_hrtime = vim.loop.hrtime
	local original_fs_stat = vim.loop.fs_stat
	local fake_now_ms = 1000
	local signature_version = 1

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/cachettl/main.go"
		end
		return original_expand(expr)
	end
	vim.fn.exepath = function(name)
		if name == "go" then
			return "/tmp/fake-go"
		end
		if original_exepath then
			return original_exepath(name)
		end
		return ""
	end
	vim.loop.hrtime = function()
		return fake_now_ms * 1e6
	end
	vim.loop.fs_stat = function(path)
		if path == "/tmp/fake-go" then
			return {
				size = 1,
				mtime = {
					sec = signature_version,
					nsec = 0,
				},
			}
		end
		if original_fs_stat then
			return original_fs_stat(path)
		end
		return nil
	end

	reset_job_results()
	init.select_build_command("float")
	local first = count_detect_backend_jobs()
	assert(first > 0, "First picker open should trigger detection")

	init.select_build_command("float")
	local second = count_detect_backend_jobs()
	assert(second == first, "Second picker open within TTL should reuse cache")

	fake_now_ms = fake_now_ms + 20000
	init.select_build_command("float")
	local third = count_detect_backend_jobs()
	assert(third > second, "TTL expiry should trigger new detection")

	fake_now_ms = fake_now_ms + 10
	signature_version = signature_version + 1
	init.select_build_command("float")
	local fourth = count_detect_backend_jobs()
	assert(fourth > third, "Mtime signature change should trigger new detection")

	vim.fn.expand = original_expand
	vim.fn.exepath = original_exepath
	vim.loop.hrtime = original_hrtime
	vim.loop.fs_stat = original_fs_stat

	print("✓ Picker detection cache TTL+mtime test passed")
end

-- Test failed detection retries sooner than the normal success TTL.
---@return nil
local function test_picker_detection_failed_cache_retries_early()
	init.setup({
		build_commands = {},
		detect_runtime = {
			async_picker = true,
			cache_ttl_ms = 15000,
			live_merge = false,
		},
	})

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_hrtime = vim.loop.hrtime
	local original_next_exit_code = state.next_exit_code
	local fake_now_ms = 1000

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/cachefail/main.go"
		end
		return original_expand(expr)
	end
	vim.loop.hrtime = function()
		return fake_now_ms * 1e6
	end

	reset_job_results()
	state.next_detect_backend_exit_code = 1
	state.next_exit_code = 1
	init.select_build_command("float")
	local first = count_detect_backend_requests()
	assert(first > 0, "First picker open should issue a detect request")

	fake_now_ms = fake_now_ms + 2000
	init.select_build_command("float")
	local second = count_detect_backend_requests()
	assert(second > first, "Failed detection cache should retry before normal TTL expiry")

	state.next_detect_backend_exit_code = 0
	state.next_exit_code = original_next_exit_code
	vim.fn.expand = original_expand
	vim.loop.hrtime = original_hrtime

	print("✓ Picker failed-detection retry test passed")
end

-- Test shebang cache remains bounded across many unique files.
---@return nil
local function test_shebang_cache_is_bounded()
	init.setup({})

	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local shebang_cache = get_upvalue_by_name(init.setup, "shebang_filetype_cache")
	local shebang_cache_order = get_upvalue_by_name(init.setup, "shebang_filetype_cache_order")

	vim.fn.filereadable = function(path)
		if type(path) == "string" and path:match("^/tmp/shebang%-cache/") then
			return 1
		end
		if type(original_filereadable) == "function" then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path, mode, max_lines)
		if type(path) == "string" and path:match("^/tmp/shebang%-cache/") then
			return { "#!/usr/bin/env python" }
		end
		if type(original_readfile) == "function" then
			return original_readfile(path, mode, max_lines)
		end
		return {}
	end

	for index = 1, 300 do
		local filepath = string.format("/tmp/shebang-cache/%03d/script", index)
		init.get_command(filepath, "")
	end

	assert(type(shebang_cache) == "table", "Shebang cache upvalue should be available")
	assert(type(shebang_cache_order) == "table", "Shebang cache order upvalue should be available")
	assert(#shebang_cache_order <= 256, "Shebang cache should respect max size")
	assert(shebang_cache["/tmp/shebang-cache/001/script"] == nil, "Oldest shebang cache entry should be evicted")

	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile

	print("✓ Shebang cache bound test passed")
end

-- Test detect runtime cache remains bounded across many unique projects.
---@return nil
local function test_detect_runtime_cache_is_bounded()
	init.setup({
		build_commands = {},
		detect_runtime = {
			async_picker = true,
			cache_ttl_ms = 15000,
			live_merge = false,
		},
	})

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local detect_cache = get_upvalue_by_name(init.setup, "detect_runtime_cache")
	local detect_cache_order = get_upvalue_by_name(init.setup, "detect_runtime_cache_order")

	for index = 1, 300 do
		vim.fn.expand = function(expr)
			if expr == "%:p" then
				return string.format("/tmp/detect-cache/%03d/main.go", index)
			end
			return original_expand(expr)
		end
		init.get_build_commands_for_completion("go")
	end

	assert(type(detect_cache) == "table", "Detect runtime cache upvalue should be available")
	assert(type(detect_cache_order) == "table", "Detect runtime cache order upvalue should be available")
	assert(#detect_cache_order <= 256, "Detect runtime cache should respect max size")
	assert(detect_cache["go::/tmp/detect-cache/001"] == nil, "Oldest detect runtime cache entry should be evicted")

	vim.fn.expand = original_expand

	print("✓ Detect runtime cache bound test passed")
end

test_float_focus_behavior()
test_build_picker_empty_state()
test_build_picker_keeps_generic_commands_in_mixed_repo()
test_build_picker_window_clamped()
test_build_picker_focus_behavior()
test_build_picker_focus_override()
test_build_picker_filter_and_preview()
test_build_picker_filter_cmdline_mode()
test_build_picker_filter_inline_mode()
test_run_build_last_behavior()
test_run_live_priority_selection()
test_run_live_missing_command()
test_picker_async_path_without_wait()
test_run_build_async_detect_without_wait()
test_run_build_completion_nonblocking_prefix()
test_picker_async_live_merge_refresh()
test_picker_detection_cache_ttl_and_mtime()
test_picker_detection_failed_cache_retries_early()
test_shebang_cache_is_bounded()
test_detect_runtime_cache_is_bounded()
