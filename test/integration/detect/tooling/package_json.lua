-- luacheck: globals project_root config init ui state job_results quickfix_results notify_results mock_jobs
-- luacheck: globals command_to_string reset_job_results reset_quickfix_results reset_notify_results
-- luacheck: globals make_expand_override with_overrides
-- luacheck: globals count_quickfix_backend_jobs count_quickfix_daemon_jobs
-- luacheck: globals count_detect_backend_jobs count_detect_backend_requests
-- luacheck: globals get_upvalue_by_name detect_backend_tool_commands is_detect_daemon_cmd parse_detect_daemon_request


-- Test JavaScript package scripts are detected from package.json.
local function test_javascript_package_scripts_detection()
    init.setup({
        build_commands = {},
    })

    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
	with_overrides({
		{ tbl = vim.bo, key = "filetype", value = "javascript" },
		{ tbl = vim.fn, key = "expand", value = make_expand_override("/tmp/jsapp/src/main.js") },
		{
			tbl = vim.fn,
			key = "executable",
			value = function(path)
				if tostring(path):match("zignite$") then
					return 1
				end
				if original_executable then
					return original_executable(path)
				end
				return 0
			end,
		},
		{
			tbl = vim.fn,
			key = "systemlist",
			value = function(cmd)
					if type(cmd) == "table" and cmd[2] == "--project-parse" and cmd[3] == "--kind=package-json-auto" then
						vim.v.shell_error = 0
						return {
							"COMMAND\tinstall\tnpm install",
							"COMMAND\tdev\tnpm run dev",
							"COMMAND\tlive\tnpm run dev",
							"COMMAND\tlint\tnpm run lint",
						}
				end
				if original_systemlist then
					return original_systemlist(cmd)
				end
				return {}
			end,
		},
		{
			tbl = vim.fn,
			key = "filereadable",
			value = function(path)
				if path == "/tmp/jsapp/package.json" then
					return 1
				end
				return 0
			end,
		},
	}, function()
		reset_job_results()
		init.run_build_command("lint", "float")
		assert(#job_results > 0, "Detected package script should start a job")
		local command = command_to_string(job_results[#job_results].cmd)
		assert(command:match("npm run lint"), "Detected script should execute via npm run lint")
		reset_job_results()
	end)
	vim.fn.executable = original_executable
	vim.fn.systemlist = original_systemlist

	print("✓ JavaScript package script detection test passed")
end

-- Test package.json script parsing can use the Zig project parser path.
local function test_javascript_package_scripts_use_zig_project_parser()
    init.setup({
        build_commands = {},
    })

    local package_parser = require("zignite.build.project_query")
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

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
        vim.v.shell_error = 0
        assert(type(cmd) == "table", "Zig package parser should execute via argv")
        assert(cmd[2] == "--project-parse", "Package parser should call the Zig project parser mode")
        assert(cmd[3] == "--kind=package-json-auto", "Package parser should use the package-json-auto parser kind")
        assert(cmd[4] == "--path=/tmp/jsapp/src/main.js", "Package parser should target the current source path")
        assert(cmd[5] == "--package-manager=npm", "Package parser should pass the detected package manager")
	        return {
	            "COMMAND\tinstall\tnpm install",
	            "COMMAND\tdev\tnpm run dev",
	            "COMMAND\tlive\tnpm run dev",
	            "COMMAND\tlint\tnpm run lint",
	        }
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

	    local commands = package_parser.detect_package_scripts("/tmp/jsapp/src/main.js")
	    assert(commands.install == "npm install", "Zig package parser should return npm install")
	    assert(commands.dev == "npm run dev", "Zig package parser should return npm run dev")
	    assert(commands.live == "npm run dev", "Zig package parser should return a live alias")
	    assert(commands.lint == "npm run lint", "Zig package parser should return npm run lint")

    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.v.shell_error = 0

    print("✓ Zig package.json parser test passed")
end

-- Test JavaScript package scripts use the detected package manager.
local function test_javascript_package_scripts_detect_package_manager()
    init.setup({
        build_commands = {},
    })

    vim.bo.filetype = "javascript"
    local original_expand = vim.fn.expand
    local original_filereadable = vim.fn.filereadable
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist

    vim.fn.expand = function(expr)
        if expr == "%:p" then return "/tmp/pnpmapp/src/main.js" end
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
	        if type(cmd) == "table" and cmd[2] == "--project-parse" and cmd[3] == "--kind=package-json-auto" then
	            vim.v.shell_error = 0
	            assert(cmd[5] == "--package-manager=pnpm", "Package parser should pass the detected package manager")
	            return {
	                "COMMAND\tinstall\tpnpm install",
	                "COMMAND\tdev\tpnpm run dev",
	                "COMMAND\tlive\tpnpm run dev",
	                "COMMAND\tlint\tpnpm run lint",
	            }
        end
        if original_systemlist then
            return original_systemlist(cmd)
        end
        return {}
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
    reset_job_results()
    init.run_build_command("lint", "float")
    assert(#job_results > 0, "Detected package script should start a job")
    local command = command_to_string(job_results[#job_results].cmd)
    assert(command:match("pnpm run lint"), "Detected script should execute via pnpm run lint")

    vim.fn.expand = original_expand
    vim.fn.filereadable = original_filereadable
    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    reset_job_results()

	print("✓ JavaScript package manager detection test passed")
end


test_javascript_package_scripts_detection()
test_javascript_package_scripts_use_zig_project_parser()
test_javascript_package_scripts_detect_package_manager()
