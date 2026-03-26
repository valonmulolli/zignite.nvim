-- luacheck: globals project_root config init ui state job_results quickfix_results notify_results mock_jobs
-- luacheck: globals command_to_string reset_job_results reset_quickfix_results reset_notify_results
-- luacheck: globals count_quickfix_backend_jobs count_quickfix_daemon_jobs
-- luacheck: globals count_detect_backend_jobs count_detect_backend_requests
-- luacheck: globals get_upvalue_by_name detect_backend_tool_commands is_detect_daemon_cmd parse_detect_daemon_request


local function test_zig_detected_commands_in_picker()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "zig"
    local original_expand = vim.fn.expand
    local original_open_win = vim.api.nvim_open_win
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local picker_opened = false
    local rendered_lines = {}

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/zigdetect/main.zig" end
        return original_expand(expr)
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

	reset_job_results()
	init.select_build_command("float")

	    assert(picker_opened, "Picker should open for detected zig commands")
	    local rendered = table.concat(rendered_lines, "\n")
	    assert(rendered:match("build"), "Picker should include detected zig build command")
	    assert(rendered:match("fmt"), "Picker should include detected zig fmt command")
	    assert(rendered:match("run"), "Picker should include detected zig run command")
	    assert(rendered:match("fetch"), "Picker should include zig fetch command")
	    assert(rendered:match("zig fetch <%a+>"), "Picker should display placeholder for required fetch argument")

    vim.fn.expand = original_expand
    vim.api.nvim_open_win = original_open_win
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    vim.v.shell_error = 0

    print("✓ Zig detected commands in picker test passed")
end

-- Test Go command detection from `go help` appears in build picker.
local function test_go_detected_commands_in_picker()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_open_win = vim.api.nvim_open_win
	local original_buf_set_lines = vim.api.nvim_buf_set_lines
	local picker_opened = false
	local rendered_lines = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/godetect/main.go"
		end
		return original_expand(expr)
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

	assert(picker_opened, "Picker should open for detected go commands")
	local rendered = table.concat(rendered_lines, "\n")
	assert(rendered:match("env"), "Picker should include detected go env command")
	assert(rendered:match("fmt"), "Picker should include detected go fmt command")

	vim.fn.expand = original_expand
	vim.api.nvim_open_win = original_open_win
	vim.api.nvim_buf_set_lines = original_buf_set_lines
	vim.v.shell_error = 0

	print("✓ Go detected commands in picker test passed")
end

-- Test Go command detection can use the persistent zig detect worker path.
local function test_go_detected_commands_with_zig_worker()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "go"
    local original_expand = vim.fn.expand
    local original_systemlist = vim.fn.systemlist
    local original_wait = vim.wait
    local original_open_win = vim.api.nvim_open_win
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local picker_opened = false
    local rendered_lines = {}

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/godetect-error/main.go" end
        return original_expand(expr)
    end
    vim.wait = function(_, condition)
        return condition()
    end
    vim.fn.systemlist = function(cmd)
        assert(
            not (type(cmd) == "table" and cmd[1] == "go" and cmd[2] == "help"),
            "go help should not be probed when zig detect worker succeeds"
        )
        return original_systemlist(cmd)
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

	reset_job_results()
    init.select_build_command("float")

    assert(picker_opened, "Picker should open for go commands detected via zig worker")
    assert(count_detect_backend_jobs() > 0, "Detect worker path should send at least one request")
    local rendered = table.concat(rendered_lines, "\n")
    assert(rendered:match("go env"), "Worker-detected go commands should include env")
    assert(rendered:match("go fmt"), "Worker-detected go commands should include fmt")

    vim.fn.expand = original_expand
    vim.fn.systemlist = original_systemlist
    vim.wait = original_wait
    vim.api.nvim_open_win = original_open_win
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    vim.v.shell_error = 0

    print("✓ Go detected commands via zig worker test passed")
end

-- Test Go command detection falls back to one-shot Zig detect when the daemon worker fails.
local function test_go_detected_commands_worker_fallback()
    init.setup({
        build_commands = {},
    })

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_open_win = vim.api.nvim_open_win
	local original_buf_set_lines = vim.api.nvim_buf_set_lines
	local picker_opened = false
	local rendered_lines = {}

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/godetect/main.go" end
        return original_expand(expr)
    end
    state.next_detect_backend_exit_code = 1
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

    reset_job_results()
    init.select_build_command("float")

    local go_help_spawned = false
    local one_shot_detect_spawned = false
	    for _, job in ipairs(job_results) do
	        if type(job.cmd) == "table" and job.cmd[1] == "go" and job.cmd[2] == "help" then
	            go_help_spawned = true
	        end
	        if type(job.cmd) == "table"
	            and tostring(job.cmd[2] or "") == "--detect"
	            and tostring(job.cmd[3] or "") == "--tool=go"
	        then
	            one_shot_detect_spawned = true
	        end
	    end

    assert(
        picker_opened,
        "Picker should open when detect falls back from worker to one-shot backend"
    )
    assert(one_shot_detect_spawned, "Fallback should spawn one-shot Zig detect when worker fails")
    assert(not go_help_spawned, "Lua go help fallback should not run anymore")
    local rendered = table.concat(rendered_lines, "\n")
    assert(rendered:match("go env"), "Backend fallback should still include env")
    assert(rendered:match("go fmt"), "Backend fallback should still include fmt")

    vim.fn.expand = original_expand
    vim.api.nvim_open_win = original_open_win
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    vim.v.shell_error = 0

    print("✓ Go detected commands worker one-shot fallback test passed")
end

-- Test Go command detection retries through one-shot Zig detect when the daemon returns an error frame.
local function test_go_detected_commands_worker_error_frame_fallback()
    init.setup({
        build_commands = {},
    })
    local detect_module = require("zignite.build.tooling.query")
    detect_module.reset()

    reset_job_results()
    state.next_detect_backend_error = "ToolProbeFailed"
    local callback_commands = nil
    detect_module.detect_go_tool_commands_async(function(commands)
        callback_commands = commands
    end, true)

    local go_help_spawned = false
    local one_shot_detect_spawned = false
	    for _, job in ipairs(job_results) do
	        if type(job.cmd) == "table" and job.cmd[1] == "go" and job.cmd[2] == "help" then
	            go_help_spawned = true
	        end
	        if type(job.cmd) == "table"
	            and tostring(job.cmd[2] or "") == "--detect"
	            and tostring(job.cmd[3] or "") == "--tool=go"
	        then
	            one_shot_detect_spawned = true
	        end
	    end

    assert(one_shot_detect_spawned, "Explicit daemon errors should retry with one-shot Zig detect")
    assert(not go_help_spawned, "Lua go help fallback should not run on daemon errors")
    assert(
        type(callback_commands) == "table",
        "One-shot fallback should still produce detected go commands"
    )
    assert(callback_commands.env == "go env", "One-shot fallback should include env")
    assert(callback_commands.fmt == "go fmt ./...", "One-shot fallback should include fmt")

    state.next_detect_backend_error = nil
    vim.v.shell_error = 0

    print("✓ Go detected commands worker error-frame one-shot fallback test passed")
end

-- Test disabling go auto-detection removes detected commands and avoids probing.
local function test_go_detection_can_be_disabled()
	init.setup({
		build_commands = {},
		detect = {
			go = false,
		},
	})
	assert(config.options.detect.go == false, "Test setup should disable detect.go")

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_jobstart_fn = vim.fn.jobstart
	local original_open_win = vim.api.nvim_open_win
	local original_buf_set_lines = vim.api.nvim_buf_set_lines
	local picker_opened = false
	local rendered_lines = {}
	local picker_job_commands = {}
	local in_picker_call = false

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/godetect/main.go"
		end
		return original_expand(expr)
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
	vim.fn.jobstart = function(cmd, opts)
		if in_picker_call then
			picker_job_commands[#picker_job_commands + 1] = command_to_string(cmd)
		end
		return original_jobstart_fn(cmd, opts)
	end

	reset_job_results()
	in_picker_call = true
	init.select_build_command("float")
	in_picker_call = false

	local go_help_spawned = false
	for _, cmd in ipairs(picker_job_commands) do
		if cmd:match("^go help") then
			go_help_spawned = true
			break
		end
	end

	assert(picker_opened, "Picker should still open when go detection is disabled")
	assert(not go_help_spawned, "go help should not run when detect.go=false")
	local rendered = table.concat(rendered_lines, "\n")
	assert(not rendered:match("go env"), "Disabled go detection should not include detected go env command")
	assert(not rendered:match("go fmt"), "Disabled go detection should not include detected go fmt command")

	vim.fn.expand = original_expand
	vim.fn.jobstart = original_jobstart_fn
	vim.api.nvim_open_win = original_open_win
	vim.api.nvim_buf_set_lines = original_buf_set_lines
	vim.v.shell_error = 0

	print("✓ Go detection disable test passed")
end

-- Test C command detection from Makefile targets appears in build picker.

test_zig_detected_commands_in_picker()
test_go_detected_commands_in_picker()
test_go_detected_commands_with_zig_worker()
test_go_detected_commands_worker_fallback()
test_go_detected_commands_worker_error_frame_fallback()
test_go_detection_can_be_disabled()
