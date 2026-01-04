-- Simple test runner for Zignite.nvim
-- Run with: lua test/runner.lua (from project root)

local M = {}

-- Simple assertion function
local function assert(condition, message)
    if not condition then
        error("Assertion failed: " .. (message or "no message"), 2)
    end
end

-- Test runner
function M.run_tests()
    print("Running Zignite.nvim tests...")

    -- Add the project root to package.path for local requires
    local project_root = arg[1] or "."
    package.path = package.path .. ';' .. project_root .. '/lua/?.lua'
    package.path = package.path .. ';' .. project_root .. '/lua/?/init.lua'
    package.path = package.path .. ';' .. project_root .. '/test/?.lua'

    local test_files = {
        "test_utils",
        "test_config",
        -- "integration" -- Requires nvim environment
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