-- Tests for zignite.config module

-- Mock vim functions for testing
_G.vim = {
    tbl_isempty = function(tbl)
        return next(tbl) == nil
    end,
    tbl_deep_extend = function(behavior, ...)
        -- Simple implementation for testing
        local result = {}
        for i = 1, select('#', ...) do
            local tbl = select(i, ...)
            for k, v in pairs(tbl) do
                if type(v) == "table" and type(result[k]) == "table" then
                    result[k] = vim.tbl_deep_extend(behavior, result[k], v)
                else
                    result[k] = v
                end
            end
        end
        return result
    end,
    tbl_contains = function(tbl, value)
        for _, v in ipairs(tbl) do
            if v == value then return true end
        end
        return false
    end,
    log = {
        levels = {
            WARN = 1
        }
    },
    notify = function(_msg, _level)
        -- Mock notify - do nothing
    end,
    keymap = {
        set = function(_mode, _lhs, _rhs, _opts)
            -- Mock keymap.set - do nothing for testing
        end
    }
}

local config = require('zignite.config')

-- Test configuration setup
local function test_config_setup()
    -- Reset config
    config.options = {}

    -- Test default setup
    config.setup()
    assert(config.options.runners, "Default runners not set")
    assert(config.options.runners.python, "Python runner not set")
    assert(config.options.float, "Float config not set")

    -- Test custom setup
    config.setup({
        runners = {
            custom_lang = "custom_command"
        },
        mode = "tab"
    })

    assert(config.options.runners.custom_lang == "custom_command", "Custom runner not set")
    assert(config.options.mode == "tab", "Custom mode not set")
    assert(config.options.runners.python, "Default runners should still exist")

    print("✓ Config setup test passed")
end

-- Test keymap setup (mock version)
local function test_keymap_setup()
    -- Mock vim.keymap.set
    local keymaps_set = {}
    _G.vim.keymap = {
        set = function(mode, lhs, rhs, opts)
            table.insert(keymaps_set, { mode = mode, lhs = lhs, rhs = rhs, opts = opts })
        end
    }

    config.setup_keymaps()
    assert(#keymaps_set > 0, "Keymaps not set")

    print("✓ Keymap setup test passed")
end

-- Run all tests
test_config_setup()
test_keymap_setup()

print("All config tests passed!")
