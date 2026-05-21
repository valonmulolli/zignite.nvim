-- Tests for zignite.config module

package.path = package.path .. ";./lua/?.lua"
package.path = package.path .. ";./lua/?/init.lua"

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
local ui_common = require('zignite.ui.common')

-- Test configuration setup
local function test_config_setup()
    -- Reset config
    config.options = {}

    -- Test default setup
    config.setup()
    assert(config.options.runners, "Default runners not set")
    assert(next(config.options.runners) == nil, "Runner overrides should default to empty")
    assert(config.options.float, "Float config not set")
    assert(config.options.picker.layout == "auto", "Picker should default to auto layout")
    assert(config.options.picker.compact_breakpoint == 96, "Picker compact breakpoint default should be set")
    assert(type(config.options.build_commands) == "table", "Build command overrides table should exist")
    assert(next(config.options.build_commands) == nil, "Build command overrides should default to empty")

    -- Test custom setup
    config.setup({
        runners = {
            custom_lang = "custom_command"
        },
        mode = "tab"
    })

    assert(config.options.runners.custom_lang == "custom_command", "Custom runner not set")
    assert(config.options.mode == "tab", "Custom mode not set")
    assert(config.options.runners.python == nil, "Builtin runners should no longer live in Lua config")
    assert(next(config.options.build_commands) == nil, "Custom setup should not invent builtin build command overrides")

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

local function test_ui_command_activity_helpers()
	local wrapped_zig = {
		"/tmp/zignite",
		"--argv",
		"zig",
		"run",
		"/tmp/example/main.zig",
	}
	assert(ui_common.describe_command_activity(wrapped_zig, "zig") == "Compiling Zig",
		"Wrapped zig run should show a compile-focused title")
	assert(ui_common.summarize_command(wrapped_zig) == "zig run main.zig",
		"Wrapped zig run should expose a short command preview")

	local footer = ui_common.build_float_footer({ close_key = "<Esc>", startinsert = true }, true, "zig run main.zig")
	assert(footer:find("zig run main%.zig", 1, false) ~= nil,
		"Float footer should include the command preview when provided")

	print("✓ UI command helper test passed")
end

-- Run all tests
test_config_setup()
test_keymap_setup()
test_ui_command_activity_helpers()

print("All config tests passed!")
