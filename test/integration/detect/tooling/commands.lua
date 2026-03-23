-- luacheck: globals project_root config init ui state job_results quickfix_results notify_results mock_jobs
-- luacheck: globals command_to_string reset_job_results reset_quickfix_results reset_notify_results
-- luacheck: globals make_expand_override with_overrides
-- luacheck: globals count_quickfix_backend_jobs count_quickfix_daemon_jobs
-- luacheck: globals count_detect_backend_jobs count_detect_backend_requests
-- luacheck: globals get_upvalue_by_name detect_backend_tool_commands is_detect_daemon_cmd parse_detect_daemon_request


local function test_run_build_command_with_detected_zig_command()
    init.setup({
        build_commands = {},
    })

	with_overrides({
		{ tbl = vim.bo, key = "filetype", value = "zig" },
		{ tbl = vim.fn, key = "expand", value = make_expand_override("/tmp/zigdetect/main.zig") },
		{
			tbl = vim.fn,
			key = "systemlist",
			value = function(cmd)
				vim.v.shell_error = 0
				if type(cmd) == "table" and cmd[2] == "--detect" and cmd[3] == "--tool=zig" then
					return { "fmt\tzig fmt $file" }
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
			end,
		},
	}, function()
		reset_job_results()
		init.run_build_command("fmt", "float")
		assert(#job_results > 0, "Detected zig build command should start a job")
		local command = command_to_string(job_results[#job_results].cmd)
		assert(command:match("zig fmt"), "Detected zig command should execute via zig fmt")
		vim.v.shell_error = 0
		reset_job_results()
	end)

    print("✓ RunBuild with detected zig command test passed")
end

-- Test run_build_command can execute go commands detected from `go help`.
local function test_run_build_command_with_detected_go_command()
    init.setup({
        build_commands = {},
    })

	with_overrides({
		{ tbl = vim.bo, key = "filetype", value = "go" },
		{ tbl = vim.fn, key = "expand", value = make_expand_override("/tmp/godetect/main.go") },
		{
			tbl = vim.fn,
			key = "systemlist",
			value = function(cmd)
				vim.v.shell_error = 0
				if type(cmd) == "table" and cmd[2] == "--detect" and cmd[3] == "--tool=go" then
					return { "env\tgo env" }
				end
				return {}
			end,
		},
	}, function()
		reset_job_results()
		init.run_build_command("env", "float")
		assert(#job_results > 0, "Detected go command should start a job")
		local command = command_to_string(job_results[#job_results].cmd)
		assert(command:match("go env"), "Detected go command should execute via go env")
		vim.v.shell_error = 0
		reset_job_results()
	end)

    print("✓ RunBuild with detected go command test passed")
end

-- Test run_build_command can execute rust commands detected from `cargo --list`.
local function test_run_build_command_with_detected_rust_command()
    init.setup({
        build_commands = {},
    })

	local original_detect_commands = detect_backend_tool_commands.cargo
	with_overrides({
		{ tbl = vim.bo, key = "filetype", value = "rust" },
		{ tbl = vim.fn, key = "expand", value = make_expand_override("/tmp/rustdetect/main.rs") },
		{ tbl = detect_backend_tool_commands, key = "cargo", value = { "metadata\tcargo metadata" } },
		{
			tbl = vim.fn,
			key = "systemlist",
			value = function(cmd)
				vim.v.shell_error = 0
				if type(cmd) == "table" and cmd[2] == "--detect" and cmd[3] == "--tool=cargo" then
					return { "metadata\tcargo metadata" }
				end
				return {}
			end,
		},
	}, function()
		reset_job_results()
		init.run_build_command("metadata", "float")
		assert(#job_results > 0, "Detected rust command should start a job")
		local command = command_to_string(job_results[#job_results].cmd)
		assert(command:match("cargo metadata"), "Detected rust command should execute via cargo metadata")
		vim.v.shell_error = 0
		reset_job_results()
	end)
	detect_backend_tool_commands.cargo = original_detect_commands

    print("✓ RunBuild with detected rust command test passed")
end

-- Test tool detection no longer shells out to cargo --list when the Zig backend is unavailable.
local function test_rust_detected_commands_require_backend()
    init.setup({
        build_commands = {},
    })

    local detect_module = require("zignite.build.detect")
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist

    vim.fn.executable = function(path)
        if tostring(path):match("zignite$") then
            return 0
        end
        if original_executable then
            return original_executable(path)
        end
        return 0
    end
    vim.fn.systemlist = function(cmd)
        if type(cmd) == "table" and cmd[1] == "cargo" and cmd[2] == "--list" then
            error("Lua cargo --list fallback should not run without the Zig backend")
        end
        return original_systemlist(cmd)
    end

    local commands = detect_module.detect_rust_tool_commands()
    assert(vim.tbl_isempty(commands), "Rust tool detection should require the Zig backend now")

    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist

    print("✓ Rust tool detection backend-only test passed")
end

-- Test detect worker async timeouts tear down the stale worker and allow later requests to recover.
local function test_detect_worker_async_timeout_resets_client()
    init.setup({
        build_commands = {},
    })

    local detect_module = require("zignite.build.detect")
    local detect_backend = require("zignite.build.detect.backend")
    local original_executable = vim.fn.executable
    local original_chansend = vim.fn.chansend
    local original_new_timer = vim.loop and vim.loop.new_timer or nil
    local timer_callbacks = {}
    local timeout_result = false
    local recovered_commands = nil

    vim.fn.executable = function(path)
        if tostring(path):match("zignite$") then
            return 1
        end
        if original_executable then
            return original_executable(path)
        end
        return 0
    end
    if vim.loop then
        vim.loop.new_timer = function()
            return {
                start = function(_, _, _, callback)
                    timer_callbacks[#timer_callbacks + 1] = callback
                end,
                stop = function() end,
                close = function() end,
            }
        end
    end
    vim.fn.chansend = function(job_id, data)
        local job = mock_jobs[job_id]
        if job and is_detect_daemon_cmd(job.cmd) then
            job.input = job.input .. tostring(data or "")
            return 1
        end
        if original_chansend then
            return original_chansend(job_id, data)
        end
        return 0
    end

    detect_backend.reset()
    reset_job_results()
    detect_module.detect_go_tool_commands_async(function(commands)
        timeout_result = commands
    end, true)
    assert(#timer_callbacks > 0, "Detect worker async request should arm a timeout timer")
    timer_callbacks[1]()
    assert(type(timeout_result) == "table", "Timed out detect worker should fall back to one-shot Zig detection")
    assert(timeout_result.env == "go env", "Timed out detect worker should still surface fallback commands")
    assert(state.jobstop_count > 0, "Timed out detect worker should stop the stale job")

    vim.fn.chansend = original_chansend
    if vim.loop then
        vim.loop.new_timer = original_new_timer
    end

    detect_module.detect_go_tool_commands_async(function(commands)
        recovered_commands = commands
    end, true)
    assert(type(recovered_commands) == "table", "Detect worker should recover after a timeout reset")
    assert(recovered_commands.env == "go env", "Detect worker should still return commands after recovery")

    vim.fn.executable = original_executable
    detect_backend.reset()
    reset_job_results()

    print("✓ Detect worker async timeout reset test passed")
end

-- Test sync detect worker parsing handles multi-line stdout callbacks without timing out.
local function test_detect_worker_sync_multiline_response()
    init.setup({
        build_commands = {},
    })

    local detect_module = require("zignite.build.detect")
    local detect_backend = require("zignite.build.detect.backend")
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
    local original_wait = vim.wait

    vim.fn.executable = function(path)
        if tostring(path):match("zignite$") then
            return 1
        end
        if original_executable then
            return original_executable(path)
        end
        return 0
    end
    vim.wait = function(_, condition)
        return condition()
    end
    vim.fn.systemlist = function(cmd)
        if type(cmd) == "table" and cmd[2] == "--detect" then
            error("Sync detect should not fall back to one-shot parsing when the daemon succeeds")
        end
        vim.v.shell_error = 0
        return {}
    end

    detect_backend.reset()
    reset_job_results()
    local commands = detect_module.detect_go_tool_commands()
    assert(type(commands) == "table", "Sync detect worker should return detected commands")
    assert(commands.build == "go build", "Sync detect worker should decode build command")
    assert(commands.env == "go env", "Sync detect worker should decode env command")
    assert(count_detect_backend_requests() == 1, "Sync detect worker should send one daemon request")

    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.wait = original_wait
    detect_backend.reset()
    reset_job_results()

    print("✓ Detect worker sync multiline response test passed")
end

-- Test run_build_command can execute cpp commands detected from Makefile targets.
local function test_run_build_command_with_detected_cpp_make_target()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "cpp"
    local original_expand = vim.fn.expand
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
    local original_filereadable = vim.fn.filereadable
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/cppdetect/main.cpp" end
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
        if type(cmd) == "table" and cmd[2] == "--project-parse" and cmd[3] == "--kind=make" then
            vim.v.shell_error = 0
            return { "custom-target" }
        end
        if original_systemlist then
            return original_systemlist(cmd)
        end
        return {}
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

    reset_job_results()
    init.run_build_command("custom-target", "float")
    assert(#job_results > 0, "Detected cpp Makefile target should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("make custom%-target"), "Detected cpp Makefile target should execute via make custom-target")

    vim.fn.expand = original_expand
    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable
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
	detect_backend_tool_commands.odin = { "version\todin version" }
	vim.fn.systemlist = function(cmd)
		vim.v.shell_error = 0
		if type(cmd) == "table" and cmd[2] == "--detect" and cmd[3] == "--tool=odin" then
			return { "version\todin version" }
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

-- Test generic run alias can use Zig-preferred Maven command selection.
local function test_detected_java_preferred_run_alias()
    init.setup({
        build_commands = {},
    })

    local build = require("zignite.build")
    vim.bo.filetype = "java"
    local original_expand = vim.fn.expand
    local original_systemlist = vim.fn.systemlist
    local original_filereadable = vim.fn.filereadable
    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/javadetect/src/Main.java" end
        return original_expand(expr)
    end
    vim.fn.systemlist = function(cmd)
        vim.v.shell_error = 0
        if type(cmd) == "table" and cmd[2] == "--project-parse" and cmd[3] == "--kind=maven" then
            return {
                "COMMAND\tmvn-build\tmvn compile",
                "COMMAND\tmvn-test\tmvn test",
                "COMMAND\tmvn-package\tmvn package",
                "COMMAND\tmvn-run\tmvn spring-boot:run",
                "PRIMARY_RUN\tmvn spring-boot:run",
                "PREFERRED\tbuild\tmvn compile",
                "PREFERRED\ttest\tmvn test",
                "PREFERRED\trun\tmvn spring-boot:run",
            }
        end
        if original_systemlist then
            return original_systemlist(cmd)
        end
        return {}
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

    local commands = build.get_build_commands_for_filetype("java", "/tmp/javadetect/src/Main.java")
    assert(commands.run == "mvn spring-boot:run", "Generic Java run should follow Zig-preferred Maven run command")

    vim.fn.expand = original_expand
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable
    reset_job_results()

    print("✓ Generic Java run alias test passed")
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
    local last_job = job_results[#job_results]
    local command = command_to_string(last_job.cmd)
    assert(command:match("./gradlew build"), "Detected Kotlin Gradle command should execute via ./gradlew build")
    assert(
        last_job.opts and last_job.opts.cwd == "/tmp/ktdetect",
        "Detected Kotlin Gradle command should execute from the Gradle project root"
    )

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    reset_job_results()

    print("✓ RunBuild with detected Kotlin Gradle command test passed")
end


test_run_build_command_with_detected_zig_command()
test_run_build_command_with_detected_go_command()
test_run_build_command_with_detected_rust_command()
test_rust_detected_commands_require_backend()
test_detect_worker_async_timeout_resets_client()
test_run_build_command_with_detected_cpp_make_target()
test_detect_worker_sync_multiline_response()
test_run_build_command_with_detected_odin_command()
test_run_build_command_with_detected_java_maven_command()
test_detected_java_preferred_run_alias()
test_run_build_command_with_detected_kotlin_gradle_command()
