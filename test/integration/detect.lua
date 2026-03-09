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
