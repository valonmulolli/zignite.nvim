-- Prevent loading the plugin twice
if vim.g.loaded_zignite then
    return
end
vim.g.loaded_zignite = true

local zignite = require("zignite")

-- Create the :RunCode user command for visual selection
vim.api.nvim_create_user_command(
    "RunCode",
    function(opts)
        zignite.run_code(opts.range)
    end,
    { range = true }
)

-- Create the :RunFile user command with optional mode
vim.api.nvim_create_user_command(
    "RunFile",
    function(opts)
        local mode = nil
        if opts.fargs[1] then
            local valid_modes = { "float", "tab", "split", "vsplit" }
            if vim.tbl_contains(valid_modes, opts.fargs[1]) then
                mode = opts.fargs[1]
            else
                vim.notify("Invalid mode: " .. opts.fargs[1] .. ". Valid modes: float, tab, split, vsplit", vim.log.levels.ERROR)
                return
            end
        end
        zignite.run_code(0, mode)
    end,
    { nargs = "?" }
)

-- Create the :RunClose user command
vim.api.nvim_create_user_command(
    "RunClose",
    function()
        zignite.close_runner()
    end,
    {}
)

-- Create the :RunProject user command
vim.api.nvim_create_user_command(
    "RunProject",
    function(opts)
        local mode = nil
        if opts.fargs[1] then
            local valid_modes = { "float", "tab", "split", "vsplit" }
            if vim.tbl_contains(valid_modes, opts.fargs[1]) then
                mode = opts.fargs[1]
            else
                vim.notify("Invalid mode: " .. opts.fargs[1] .. ". Valid modes: float, tab, split, vsplit", vim.log.levels.ERROR)
                return
            end
        end
        zignite.run_project(mode)
    end,
    { nargs = "?" }
)

-- Create the :StopCode user command
vim.api.nvim_create_user_command(
    "StopCode",
    function()
        zignite.stop_code()
    end,
    {}
)
