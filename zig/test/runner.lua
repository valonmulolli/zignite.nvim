-- Simple test runner for Zignite.nvim
-- Run with: lua zig/test/runner.lua (from project root)

local M = {}

-- Test runner
function M.run_tests()
    print("Running Zignite.nvim tests...")

    -- Add the project root to package.path for local requires
    local project_root = arg[1] or "."
    package.path = package.path .. ';' .. project_root .. '/lua/?.lua'
    package.path = package.path .. ';' .. project_root .. '/lua/?/init.lua'
    package.path = package.path .. ';' .. project_root .. '/zig/test/?.lua'

    local test_files = {
        "test_config",
    }

    local passed = 0
    local failed = 0

    for _, test_file in ipairs(test_files) do
        local ok, err = pcall(function()
            require(test_file)
        end)

        if ok then
            print("✓ " .. test_file .. " passed")
            passed = passed + 1
        else
            print("✗ " .. test_file .. " failed: " .. err)
            failed = failed + 1
        end
    end

    -- Run integration tests in a separate Lua process to avoid mock/module
    -- leakage between unit and integration suites.
    local integration_cmd = string.format('lua "%s/zig/test/integration.lua" "%s"', project_root, project_root)
    local integration_ok = os.execute(integration_cmd)
    if integration_ok == true or integration_ok == 0 then
        print("✓ integration passed")
        passed = passed + 1
    else
        print("✗ integration failed")
        failed = failed + 1
    end

    print(string.format("\nTest Results: %d passed, %d failed", passed, failed))

    if failed > 0 then
        os.exit(1)
    end
end

-- If run directly
if arg and arg[0]:match("runner%.lua") then
    M.run_tests()
end

return M
