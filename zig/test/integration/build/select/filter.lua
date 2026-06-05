-- luacheck: globals project_root config init ui state job_results quickfix_results notify_results mock_jobs
-- luacheck: globals command_to_string reset_job_results reset_quickfix_results reset_notify_results
-- luacheck: globals count_quickfix_backend_jobs count_quickfix_daemon_jobs
-- luacheck: globals count_detect_backend_jobs count_detect_backend_requests
-- luacheck: globals get_upvalue_by_name detect_backend_tool_commands is_detect_daemon_cmd parse_detect_daemon_request

local command_helpers = require("zignite.ui.build_picker.commands")

local function test_build_picker_respects_backend_picker_metadata()
	local entries = command_helpers.normalize_command_entries({
		{
			name = "build",
			command = "cmake --build build",
			display_command = "cmake --build build",
			picker_section = "common",
			picker_rank = 1001,
		},
		{
			name = "cmake-build-demo",
			command = "cmake --build build --target demo",
			display_command = "cmake --build build --target demo",
			picker_section = "targets",
			picker_rank = 2999,
		},
	})

	assert(#entries == 2, "Picker should hide backend-pruned aliases")
	assert(entries[1].name == "build", "Picker should keep the generic command")
	assert(entries[2].name == "cmake-build-demo", "Picker should keep target-specific commands")
	assert(command_helpers.command_section(entries[2]) == "targets",
		"Picker should trust backend section metadata")

	print("✓ Build picker backend metadata test passed")
end

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

    assert(type(mapped["j"]) == "function", "Picker should map 'j' for navigation")
    assert(type(mapped["/"]) == "function", "Picker should map '/' for filtering")
    assert(#latest_lines > 0, "Picker should render lines")
    mapped["j"]()
    local preview_line = nil
    for _, line in ipairs(latest_lines) do
        if type(line) == "string" and line:match("^ cmd: ") then
            preview_line = line
            break
        end
    end
    assert(preview_line and preview_line:match("segment%-end"), "Picker preview should include full command text")

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

-- Test picker captures required command args inline instead of using vim.fn.input.
local function test_build_picker_inline_argument_entry()
	local original_expand = vim.fn.expand
	local original_keymap = vim.keymap
	local original_getcharstr = vim.fn.getcharstr
	local original_input = vim.fn.input
	local original_buf_set_lines = vim.api.nvim_buf_set_lines
	local mapped = {}
	local latest_lines = {}
	local input_calls = 0
	local idx = 1
	local keys = {
		"f",
		"e",
		"t",
		"c",
		"h",
		"\r",
		"p",
		"k",
		"g",
		"\r",
	}

	config.setup({
		build_commands = {
			zig = {
				fetch = "zig fetch $zignite_args",
			},
		},
		picker = {
			filter_input = "inline",
		},
	})

	vim.bo.filetype = "zig"
	vim.fn.expand = function(expr)
		if expr == "%:p" then return "/tmp/picker/main.zig" end
		return original_expand(expr)
	end
	vim.fn.getcharstr = function()
		local key = keys[idx]
		idx = idx + 1
		return key
	end
	vim.fn.input = function(_, default)
		input_calls = input_calls + 1
		return default or ""
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

	reset_job_results()
	init.select_build_command("float")

	assert(type(mapped["/"]) == "function", "Picker should map '/' for filtering")
	assert(type(mapped["<CR>"]) == "function", "Picker should map Enter for selection")
	mapped["/"]()
	mapped["<CR>"]()

	assert(input_calls == 0, "Inline argument entry should not use vim.fn.input")
	assert(#job_results > 0, "Inline argument entry should execute the selected command")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("zig fetch"), "Inline argument entry should execute zig fetch")
	assert(command:match("pkg"), "Inline argument entry should include typed argument")
	assert(latest_lines[1]:match("zig fetch url/path"), "Inline argument entry should render the args header in-picker")
	assert(latest_lines[2]:match("^ %> "), "Inline argument entry should render a dedicated input row")
	assert(
		table.concat(latest_lines, "\n"):match("Paste GitHub URL only"),
		"Inline argument entry should explain that a plain GitHub URL is enough"
	)

	vim.fn.expand = original_expand
	vim.fn.getcharstr = original_getcharstr
	vim.fn.input = original_input
	vim.api.nvim_buf_set_lines = original_buf_set_lines
	vim.keymap = original_keymap
	reset_job_results()

	print("✓ Build picker inline argument entry test passed")
end

local function test_build_picker_uses_backend_no_command_message()
	local original_expand = vim.fn.expand

	config.setup({
		build_commands = {},
		detect_runtime = {
			async_picker = false,
		},
	})

	vim.bo.filetype = "unknownft"
	vim.fn.expand = function(expr)
		if expr == "%:p" then return "/tmp/picker/main.unknown" end
		return original_expand(expr)
	end

	reset_notify_results()
	init.select_build_command("float")

	assert(#notify_results > 0, "Picker should notify when backend reports no build commands")
	assert(
		type(notify_results[#notify_results].msg) == "string"
			and notify_results[#notify_results].msg:match("No build commands available for filetype: unknownft"),
		"Picker should surface the backend no-command message"
	)

	vim.fn.expand = original_expand
	reset_notify_results()

	print("✓ Build picker backend no-command message test passed")
end

test_build_picker_respects_backend_picker_metadata()
test_build_picker_filter_and_preview()
test_build_picker_filter_cmdline_mode()
test_build_picker_filter_inline_mode()
test_build_picker_inline_argument_entry()
test_build_picker_uses_backend_no_command_message()
