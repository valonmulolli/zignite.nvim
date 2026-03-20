-- luacheck: globals project_root config init ui state job_results quickfix_results notify_results mock_jobs
-- luacheck: globals command_to_string reset_job_results reset_quickfix_results reset_notify_results
-- luacheck: globals count_quickfix_backend_jobs count_quickfix_daemon_jobs
-- luacheck: globals count_detect_backend_jobs count_detect_backend_requests
-- luacheck: globals get_upvalue_by_name detect_backend_tool_commands is_detect_daemon_cmd parse_detect_daemon_request

-- Test Zig command detection from `zig --help` appears in build picker.
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
        if expr == "%:p" then return "/tmp/godetect/main.go" end
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

-- Test Go command detection falls back to Lua parsing when zig detect worker fails.
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
    for _, job in ipairs(job_results) do
        if type(job.cmd) == "table" and job.cmd[1] == "go" and job.cmd[2] == "help" then
            go_help_spawned = true
            break
        end
    end

    assert(picker_opened, "Picker should open when falling back from worker to Lua parser")
    assert(go_help_spawned, "Fallback should spawn go help when worker fails")
    local rendered = table.concat(rendered_lines, "\n")
    assert(rendered:match("go env"), "Fallback-detected go commands should include env")
    assert(rendered:match("go fmt"), "Fallback-detected go commands should include fmt")

    vim.fn.expand = original_expand
    vim.api.nvim_open_win = original_open_win
    vim.api.nvim_buf_set_lines = original_buf_set_lines
    vim.v.shell_error = 0

    print("✓ Go detected commands worker fallback test passed")
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
local function test_c_detected_make_targets_in_picker()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "c"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile
    local original_open_win = vim.api.nvim_open_win
    local original_buf_set_lines = vim.api.nvim_buf_set_lines
    local picker_opened = false
    local rendered_lines = {}

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/cdetect/main.c" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/cdetect/Makefile" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/cdetect/Makefile" then
            return {
                "all: app",
                "bench test: app",
                ".PHONY: all bench test",
                "\t@echo done",
            }
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
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

    assert(picker_opened, "Picker should open for detected c Makefile targets")
    local rendered = table.concat(rendered_lines, "\n")
    assert(rendered:match("bench"), "Picker should include detected Makefile target: bench")
    assert(rendered:match("test"), "Picker should include detected Makefile target: test")
    assert(rendered:match("make bench"), "Detected target should map to make bench")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.api.nvim_open_win = original_open_win
    vim.api.nvim_buf_set_lines = original_buf_set_lines

    print("✓ C detected Makefile targets in picker test passed")
end

-- Test run_build_command can execute zig commands detected from `zig --help`.
local function test_run_build_command_with_detected_zig_command()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "zig"
    local original_expand = vim.fn.expand
    local original_systemlist = vim.fn.systemlist
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/zigdetect/main.zig" end
        return original_expand(expr)
    end
	vim.fn.systemlist = function(cmd)
		vim.v.shell_error = 0
		if type(cmd) == "table" and cmd[2] == "--detect" and cmd[3] == "--tool=zig" then
			return { "fmt" }
		end
		return {
			"Usage: zig [command] [options]",
			"",
			"Commands:",
			"  build            Build project from build.zig",
			"  fmt              Reformat Zig source into canonical form",
			"",
			"General Options:",
		}
	end

    reset_job_results()
    init.run_build_command("fmt", "float")
    assert(#job_results > 0, "Detected zig build command should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("zig fmt"), "Detected zig command should execute via zig fmt")

    vim.fn.expand = original_expand
    vim.fn.systemlist = original_systemlist
    vim.v.shell_error = 0
    reset_job_results()

    print("✓ RunBuild with detected zig command test passed")
end

-- Test run_build_command can execute go commands detected from `go help`.
local function test_run_build_command_with_detected_go_command()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "go"
    local original_expand = vim.fn.expand
    local original_systemlist = vim.fn.systemlist
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/godetect/main.go" end
        return original_expand(expr)
    end
	vim.fn.systemlist = function(cmd)
		vim.v.shell_error = 0
		if type(cmd) == "table" and cmd[2] == "--detect" and cmd[3] == "--tool=go" then
			return { "env" }
		end
		if type(cmd) == "table" and cmd[1] == "go" and cmd[2] == "help" then
			return {
				"The commands are:",
				"    env         print Go environment information",
			}
		end
		return original_systemlist(cmd)
	end

    reset_job_results()
    init.run_build_command("env", "float")
    assert(#job_results > 0, "Detected go command should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("go env"), "Detected go command should execute via go env")

    vim.fn.expand = original_expand
    vim.fn.systemlist = original_systemlist
    vim.v.shell_error = 0
    reset_job_results()

    print("✓ RunBuild with detected go command test passed")
end

-- Test run_build_command can execute rust commands detected from `cargo --list`.
local function test_run_build_command_with_detected_rust_command()
    init.setup({
        build_commands = {},
    })

	vim.bo.filetype = "rust"
	local original_expand = vim.fn.expand
	local original_systemlist = vim.fn.systemlist
	local original_detect_commands = detect_backend_tool_commands.cargo
	vim.fn.expand = function(expr)
	    if expr == "%:p" then return "/tmp/rustdetect/main.rs" end
	    return original_expand(expr)
	end
	detect_backend_tool_commands.cargo = { "metadata" }
	vim.fn.systemlist = function(cmd)
		vim.v.shell_error = 0
		if type(cmd) == "table" and cmd[2] == "--detect" and cmd[3] == "--tool=cargo" then
			return { "metadata" }
		end
		if type(cmd) == "table" and cmd[1] == "cargo" and cmd[2] == "--list" then
			return {
				"Installed Commands:",
				"    metadata    Output metadata about local package",
			}
		end
		return original_systemlist(cmd)
	end

    reset_job_results()
    init.run_build_command("metadata", "float")
    assert(#job_results > 0, "Detected rust command should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("cargo metadata"), "Detected rust command should execute via cargo metadata")

	vim.fn.expand = original_expand
	vim.fn.systemlist = original_systemlist
	detect_backend_tool_commands.cargo = original_detect_commands
	vim.v.shell_error = 0
	reset_job_results()

    print("✓ RunBuild with detected rust command test passed")
end

-- Test run_build_command can execute cpp commands detected from Makefile targets.
local function test_run_build_command_with_detected_cpp_make_target()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "cpp"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/cppdetect/main.cpp" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/cppdetect/Makefile" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/cppdetect/Makefile" then
            return {
                "custom-target:",
                "\t@echo cpp",
            }
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end

    reset_job_results()
    init.run_build_command("custom-target", "float")
    assert(#job_results > 0, "Detected cpp Makefile target should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("make custom%-target"), "Detected cpp Makefile target should execute via make custom-target")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    reset_job_results()

    print("✓ RunBuild with detected cpp Makefile target test passed")
end

-- Test run_build_command can execute odin commands detected from `odin help`.
local function test_run_build_command_with_detected_odin_command()
    init.setup({
        build_commands = {},
    })

	vim.bo.filetype = "odin"
	local original_expand = vim.fn.expand
	local original_systemlist = vim.fn.systemlist
	local original_detect_commands = detect_backend_tool_commands.odin
	vim.fn.expand = function(expr)
	    if expr == "%:p" then return "/tmp/odindetect/main.odin" end
	    return original_expand(expr)
	end
	detect_backend_tool_commands.odin = { "version" }
	vim.fn.systemlist = function(cmd)
		vim.v.shell_error = 0
		if type(cmd) == "table" and cmd[2] == "--detect" and cmd[3] == "--tool=odin" then
			return { "version" }
		end
		if type(cmd) == "table" and cmd[1] == "odin" and cmd[2] == "help" then
			return {
				"Commands:",
				"    version     Print version information",
				"",
				"Flags:",
			}
		end
		return original_systemlist(cmd)
	end

    reset_job_results()
    init.run_build_command("version", "float")
    assert(#job_results > 0, "Detected odin command should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("odin version"), "Detected odin command should execute via odin version")

	vim.fn.expand = original_expand
	vim.fn.systemlist = original_systemlist
	detect_backend_tool_commands.odin = original_detect_commands
	vim.v.shell_error = 0
	reset_job_results()

    print("✓ RunBuild with detected odin command test passed")
end

-- Test Java build commands can be inferred from Maven project files.
local function test_run_build_command_with_detected_java_maven_command()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "java"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/javadetect/src/Main.java" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/javadetect/pom.xml" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end

    reset_job_results()
    init.run_build_command("mvn-test", "float")
    assert(#job_results > 0, "Detected Java Maven command should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("mvn test"), "Detected Java Maven command should execute via mvn test")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    reset_job_results()

    print("✓ RunBuild with detected Java Maven command test passed")
end

-- Test Kotlin build commands can be inferred from Gradle wrapper projects.
local function test_run_build_command_with_detected_kotlin_gradle_command()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "kotlin"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/ktdetect/src/Main.kt" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/ktdetect/gradlew" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end

    reset_job_results()
    init.run_build_command("gradle-build", "float")
    assert(#job_results > 0, "Detected Kotlin Gradle command should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("./gradlew build"), "Detected Kotlin Gradle command should execute via ./gradlew build")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    reset_job_results()

    print("✓ RunBuild with detected Kotlin Gradle command test passed")
end

-- Test JavaScript package scripts are detected from package.json.
local function test_javascript_package_scripts_detection()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "javascript"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile
    local original_vim_json = vim.json

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/jsapp/src/main.js" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/jsapp/package.json" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/jsapp/package.json" then
            return { '{"scripts":{"dev":"vite","lint":"eslint ."}}' }
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end
    vim.json = {
        decode = function(_)
            return {
                scripts = {
                    dev = "vite",
                    lint = "eslint .",
                },
            }
        end,
    }

    reset_job_results()
    init.run_build_command("lint", "float")
    assert(#job_results > 0, "Detected package script should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("npm run lint"), "Detected script should execute via npm run lint")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.json = original_vim_json
    reset_job_results()

	print("✓ JavaScript package script detection test passed")
end

-- Test JavaScript package scripts use the detected package manager.
local function test_javascript_package_scripts_detect_package_manager()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "javascript"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile
    local original_vim_json = vim.json

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/pnpmapp/src/main.js" end
        return original_expand(expr)
    end
    vim.fn.filereadable = function(path)
        if path == "/tmp/pnpmapp/package.json" or path == "/tmp/pnpmapp/pnpm-lock.yaml" then
            return 1
        end
        if original_filereadable then
            return original_filereadable(path)
        end
        return 0
    end
    vim.fn.readfile = function(path, _, _)
        if path == "/tmp/pnpmapp/package.json" then
            return { '{"scripts":{"dev":"vite","lint":"eslint ."}}' }
        end
        if original_readfile then
            return original_readfile(path)
        end
        return {}
    end
    vim.json = {
        decode = function(_)
            return {
                scripts = {
                    dev = "vite",
                    lint = "eslint .",
                },
            }
        end,
    }

    reset_job_results()
    init.run_build_command("lint", "float")
    assert(#job_results > 0, "Detected package script should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("pnpm run lint"), "Detected script should execute via pnpm run lint")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.json = original_vim_json
    reset_job_results()

	print("✓ JavaScript package manager detection test passed")
end

-- Test Bazel workspace commands appear in picker and prompt-aware commands render placeholders.
local function test_bazel_project_commands_in_picker()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "cpp"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_open_win = vim.api.nvim_open_win
	local original_buf_set_lines = vim.api.nvim_buf_set_lines
	local picker_opened = false
	local rendered_lines = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazelapp/src/main.cc"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazelapp/MODULE.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
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

	assert(picker_opened, "Picker should open for detected Bazel workspace commands")
	local rendered = table.concat(rendered_lines, "\n")
	assert(rendered:match("bazel%-build"), "Picker should include bazel-build command")
	assert(rendered:match("bazel%-run"), "Picker should include bazel-run command")
	assert(rendered:match("bazel build <%a+>"), "Bazel placeholder command should render <args>")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.api.nvim_open_win = original_open_win
	vim.api.nvim_buf_set_lines = original_buf_set_lines

	print("✓ Bazel project commands in picker test passed")
end

-- Test Bazel command execution prompts for target arguments.
local function test_run_build_command_with_detected_bazel_command()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "cpp"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_input = vim.fn.input
	local prompts = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazelapp/src/main.cc"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazelapp/MODULE.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.input = function(prompt, _default)
		prompts[#prompts + 1] = prompt
		return "//app:main"
	end

	reset_job_results()
	init.run_build_command("bazel-build", "float")
	assert(#job_results > 0, "Detected Bazel command should start a job after prompting for target")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel build"), "Detected Bazel command should execute via bazel build")
	assert(command:match("//app:main"), "Detected Bazel command should include provided target argument")
	assert(#prompts == 1 and prompts[1]:match("cpp bazel%-build args"), "Bazel command should prompt for target argument")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.input = original_input
	reset_job_results()

	print("✓ RunBuild with detected Bazel command test passed")
end

-- Test Bazel BUILD parsing infers a concrete target for the current file.
local function test_bazel_target_inference_in_picker()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "cpp"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local original_open_win = vim.api.nvim_open_win
	local original_buf_set_lines = vim.api.nvim_buf_set_lines
	local picker_opened = false
	local rendered_lines = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazelapp/app/main.cc"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazelapp/MODULE.bazel" or path == "/tmp/bazelapp/app/BUILD.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path)
		if path == "/tmp/bazelapp/app/BUILD.bazel" then
			return {
				'cc_binary(',
				'    name = "main",',
				'    srcs = ["main.cc"],',
				')',
			}
		end
		if original_readfile then
			return original_readfile(path)
		end
		return {}
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

	assert(picker_opened, "Picker should open for inferred Bazel target commands")
	local rendered = table.concat(rendered_lines, "\n")
	assert(rendered:match("bazel%-run%-main"), "Picker should include target-specific Bazel run command")
	assert(rendered:match("bazel run //app:main"), "Picker should render inferred Bazel label")
	assert(not rendered:match("bazel run <%a+>"), "Inferred Bazel run command should not render placeholder args")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile
	vim.api.nvim_open_win = original_open_win
	vim.api.nvim_buf_set_lines = original_buf_set_lines

	print("✓ Bazel target inference in picker test passed")
end

-- Test Bazel run uses inferred target without prompting for args.
local function test_run_build_command_with_inferred_bazel_target()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "cpp"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local original_input = vim.fn.input
	local prompts = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazelapp/app/main.cc"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazelapp/MODULE.bazel" or path == "/tmp/bazelapp/app/BUILD.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path)
		if path == "/tmp/bazelapp/app/BUILD.bazel" then
			return {
				'cc_binary(',
				'    name = "main",',
				'    srcs = ["main.cc"],',
				')',
			}
		end
		if original_readfile then
			return original_readfile(path)
		end
		return {}
	end
	vim.fn.input = function(prompt, default_value)
		prompts[#prompts + 1] = prompt
		return default_value or ""
	end

	reset_job_results()
	init.run_build_command("bazel-run", "float")

	assert(#job_results > 0, "Inferred Bazel run should start a job")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel run //app:main"), "Inferred Bazel run should execute concrete label")
	assert(#prompts == 0, "Inferred Bazel run should not prompt for args")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile
	vim.fn.input = original_input
	reset_job_results()

	print("✓ Inferred Bazel run command test passed")
end

-- Test Bazel infers a target when BUILD uses glob() for sources.
local function test_bazel_glob_target_inference()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "cpp"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local original_input = vim.fn.input
	local prompts = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazelglob/app/main.cc"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazelglob/MODULE.bazel" or path == "/tmp/bazelglob/app/BUILD.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path)
		if path == "/tmp/bazelglob/app/BUILD.bazel" then
			return {
				'cc_binary(',
				'    name = "glob_app",',
				'    srcs = glob(["*.cc"]),',
				')',
			}
		end
		if original_readfile then
			return original_readfile(path)
		end
		return {}
	end
	vim.fn.input = function(prompt, default_value)
		prompts[#prompts + 1] = prompt
		return default_value or ""
	end

	reset_job_results()
	init.run_build_command("bazel-run", "float")

	assert(#job_results > 0, "Glob-based Bazel run should start a job")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel run //app:glob_app"), "Glob-based Bazel run should infer target label")
	assert(#prompts == 0, "Glob-based Bazel run should not prompt for args")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile
	vim.fn.input = original_input
	reset_job_results()

	print("✓ Bazel glob target inference test passed")
end

-- Test Bazel infers a related cc_test target for the current source file.
local function test_bazel_related_test_inference()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "cpp"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local original_input = vim.fn.input
	local prompts = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazeltests/app/foo.cc"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazeltests/MODULE.bazel" or path == "/tmp/bazeltests/app/BUILD.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path)
		if path == "/tmp/bazeltests/app/BUILD.bazel" then
			return {
				'cc_library(',
				'    name = "foo_lib",',
				'    srcs = ["foo.cc"],',
				')',
				'cc_test(',
				'    name = "foo_test",',
				'    srcs = ["foo_test.cc"],',
				')',
			}
		end
		if original_readfile then
			return original_readfile(path)
		end
		return {}
	end
	vim.fn.input = function(prompt, default_value)
		prompts[#prompts + 1] = prompt
		return default_value or ""
	end

	reset_job_results()
	init.run_build_command("bazel-test", "float")

	assert(#job_results > 0, "Related Bazel test should start a job")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel test //app:foo_test"), "Related Bazel test should infer test target")
	assert(#prompts == 0, "Related Bazel test should not prompt for args")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile
	vim.fn.input = original_input
	reset_job_results()

	print("✓ Bazel related test inference test passed")
end

-- Test Bazel can infer a target from a parent package BUILD file.
local function test_bazel_parent_package_inference()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "cpp"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local original_input = vim.fn.input
	local prompts = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazelparent/app/main.cc"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if
			path == "/tmp/bazelparent/MODULE.bazel"
			or path == "/tmp/bazelparent/BUILD.bazel"
			or path == "/tmp/bazelparent/app/BUILD.bazel"
		then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path)
		if path == "/tmp/bazelparent/app/BUILD.bazel" then
			return {
				'exports_files(["main.cc"])',
			}
		end
		if path == "/tmp/bazelparent/BUILD.bazel" then
			return {
				'cc_binary(',
				'    name = "root_app",',
				'    srcs = ["app/main.cc"],',
				')',
			}
		end
		if original_readfile then
			return original_readfile(path)
		end
		return {}
	end
	vim.fn.input = function(prompt, default_value)
		prompts[#prompts + 1] = prompt
		return default_value or ""
	end

	reset_job_results()
	init.run_build_command("bazel-run", "float")

	assert(#job_results > 0, "Parent-package Bazel run should start a job")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel run //:root_app"), "Parent-package Bazel run should infer root package target")
	assert(#prompts == 0, "Parent-package Bazel run should not prompt for args")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile
	vim.fn.input = original_input
	reset_job_results()

	print("✓ Bazel parent package inference test passed")
end

-- Test Bazel wrapper macro names still infer runnable targets.
local function test_bazel_wrapper_rule_inference()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "cpp"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local original_input = vim.fn.input
	local prompts = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazelmacro/app/main.cc"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazelmacro/MODULE.bazel" or path == "/tmp/bazelmacro/app/BUILD.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path)
		if path == "/tmp/bazelmacro/app/BUILD.bazel" then
			return {
				'wrapped_cc_binary(',
				'    name = "macro_app",',
				'    srcs = ["main.cc"],',
				')',
			}
		end
		if original_readfile then
			return original_readfile(path)
		end
		return {}
	end
	vim.fn.input = function(prompt, default_value)
		prompts[#prompts + 1] = prompt
		return default_value or ""
	end

	reset_job_results()
	init.run_build_command("bazel-run", "float")

	assert(#job_results > 0, "Wrapper-rule Bazel run should start a job")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel run //app:macro_app"), "Wrapper-rule Bazel run should infer wrapped binary target")
	assert(#prompts == 0, "Wrapper-rule Bazel run should not prompt for args")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile
	vim.fn.input = original_input
	reset_job_results()

	print("✓ Bazel wrapper rule inference test passed")
end

-- Test Bazel infers related Go test targets from *_test.go naming.
local function test_bazel_go_test_relationship_inference()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "go"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local original_input = vim.fn.input
	local prompts = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazelgo/app/foo.go"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazelgo/MODULE.bazel" or path == "/tmp/bazelgo/app/BUILD.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path)
		if path == "/tmp/bazelgo/app/BUILD.bazel" then
			return {
				'go_library(',
				'    name = "foo_lib",',
				'    srcs = ["foo.go"],',
				')',
				'go_test(',
				'    name = "foo_test",',
				'    srcs = ["foo_test.go"],',
				')',
			}
		end
		if original_readfile then
			return original_readfile(path)
		end
		return {}
	end
	vim.fn.input = function(prompt, default_value)
		prompts[#prompts + 1] = prompt
		return default_value or ""
	end

	reset_job_results()
	init.run_build_command("bazel-test", "float")

	assert(#job_results > 0, "Go-related Bazel test should start a job")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel test //app:foo_test"), "Go-related Bazel test should infer go_test target")
	assert(#prompts == 0, "Go-related Bazel test should not prompt for args")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile
	vim.fn.input = original_input
	reset_job_results()

	print("✓ Bazel Go test relationship inference test passed")
end

-- Test Bazel infers related Python test targets from test_*.py naming.
local function test_bazel_python_test_relationship_inference()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "python"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local original_input = vim.fn.input
	local prompts = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazelpy/app/main.py"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazelpy/MODULE.bazel" or path == "/tmp/bazelpy/app/BUILD.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path)
		if path == "/tmp/bazelpy/app/BUILD.bazel" then
			return {
				'py_binary(',
				'    name = "main",',
				'    srcs = ["main.py"],',
				'    main = "main.py",',
				')',
				'py_test(',
				'    name = "main_test",',
				'    srcs = ["test_main.py"],',
				')',
			}
		end
		if original_readfile then
			return original_readfile(path)
		end
		return {}
	end
	vim.fn.input = function(prompt, default_value)
		prompts[#prompts + 1] = prompt
		return default_value or ""
	end

	reset_job_results()
	init.run_build_command("bazel-test", "float")

	assert(#job_results > 0, "Python-related Bazel test should start a job")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel test //app:main_test"), "Python-related Bazel test should infer py_test target")
	assert(#prompts == 0, "Python-related Bazel test should not prompt for args")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile
	vim.fn.input = original_input
	reset_job_results()

	print("✓ Bazel Python test relationship inference test passed")
end

-- Test Bazel infers related JVM test targets from Foo.java -> FooTest.java naming.
local function test_bazel_jvm_test_relationship_inference()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "java"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local original_input = vim.fn.input
	local prompts = {}

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazeljvm/app/Foo.java"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazeljvm/MODULE.bazel" or path == "/tmp/bazeljvm/app/BUILD.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path)
		if path == "/tmp/bazeljvm/app/BUILD.bazel" then
			return {
				'java_library(',
				'    name = "foo_lib",',
				'    srcs = ["Foo.java"],',
				')',
				'java_test(',
				'    name = "foo_test",',
				'    srcs = ["FooTest.java"],',
				')',
			}
		end
		if original_readfile then
			return original_readfile(path)
		end
		return {}
	end
	vim.fn.input = function(prompt, default_value)
		prompts[#prompts + 1] = prompt
		return default_value or ""
	end

	reset_job_results()
	init.run_build_command("bazel-test", "float")

	assert(#job_results > 0, "JVM-related Bazel test should start a job")
	local command = command_to_string(job_results[#job_results].cmd)
	assert(command:match("bazel test //app:foo_test"), "JVM-related Bazel test should infer java_test target")
	assert(#prompts == 0, "JVM-related Bazel test should not prompt for args")

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile
	vim.fn.input = original_input
	reset_job_results()

	print("✓ Bazel JVM test relationship inference test passed")
end

-- Test parsed Bazel BUILD files are cached across repeated lookups.
local function test_bazel_build_file_cache_reuses_parsed_targets()
	init.setup({
		build_commands = {},
	})

	vim.bo.filetype = "cpp"
	local original_expand = vim.fn.expand
	local original_filereadable = vim.fn.filereadable
	local original_readfile = vim.fn.readfile
	local build_read_count = 0

	vim.fn.expand = function(expr)
		if expr == "%:p" then
			return "/tmp/bazelcache/app/main.cc"
		end
		return original_expand(expr)
	end
	vim.fn.filereadable = function(path)
		if path == "/tmp/bazelcache/MODULE.bazel" or path == "/tmp/bazelcache/app/BUILD.bazel" then
			return 1
		end
		if original_filereadable then
			return original_filereadable(path)
		end
		return 0
	end
	vim.fn.readfile = function(path)
		if path == "/tmp/bazelcache/app/BUILD.bazel" then
			build_read_count = build_read_count + 1
			return {
				'cc_binary(',
				'    name = "main",',
				'    srcs = ["main.cc"],',
				')',
			}
		end
		if original_readfile then
			return original_readfile(path)
		end
		return {}
	end

	local first_commands = init.get_build_commands_for_filetype("cpp")
	local second_commands = init.get_build_commands_for_filetype("cpp")

	assert(
		first_commands["bazel-run"] == "bazel run //app:main",
		"First Bazel lookup should infer concrete run target"
	)
	assert(
		second_commands["bazel-run"] == "bazel run //app:main",
		"Second Bazel lookup should reuse inferred concrete run target"
	)
	assert(
		build_read_count == 1,
		"Repeated Bazel lookups should reuse cached parsed BUILD targets"
	)

	vim.fn.expand = original_expand
	vim.fn.filereadable = original_filereadable
	vim.fn.readfile = original_readfile

	print("✓ Bazel parsed BUILD cache reuse test passed")
end

test_zig_detected_commands_in_picker()
test_go_detected_commands_in_picker()
test_go_detected_commands_with_zig_worker()
test_go_detected_commands_worker_fallback()
test_go_detection_can_be_disabled()
test_c_detected_make_targets_in_picker()
test_run_build_command_with_detected_zig_command()
test_run_build_command_with_detected_go_command()
test_run_build_command_with_detected_rust_command()
test_run_build_command_with_detected_cpp_make_target()
test_run_build_command_with_detected_odin_command()
test_run_build_command_with_detected_java_maven_command()
test_run_build_command_with_detected_kotlin_gradle_command()
test_javascript_package_scripts_detection()
test_javascript_package_scripts_detect_package_manager()
test_bazel_target_inference_in_picker()
test_bazel_glob_target_inference()
test_bazel_parent_package_inference()
test_bazel_project_commands_in_picker()
test_bazel_wrapper_rule_inference()
test_bazel_go_test_relationship_inference()
test_bazel_python_test_relationship_inference()
test_bazel_jvm_test_relationship_inference()
test_bazel_build_file_cache_reuses_parsed_targets()
test_bazel_related_test_inference()
test_run_build_command_with_inferred_bazel_target()
test_run_build_command_with_detected_bazel_command()
