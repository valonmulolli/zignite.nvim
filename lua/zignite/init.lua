local config = require('zignite.config')
local ui = require('zignite.ui')
local utils = require('zignite.utils')

local M = {}

local current_job_id = nil

-- Get the plugin directory path
local function get_plugin_path()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    return vim.fn.fnamemodify(source, ":h:h:h")
end

local PLUGIN_PATH = get_plugin_path()

-- Helper function to get visual selection
local function get_visual_selection()
    local _, start_line, start_col, _ = unpack(vim.fn.getpos("'<"))
    local _, end_line, end_col, _ = unpack(vim.fn.getpos("'>"))
    if start_line == 0 or end_line == 0 then
        return ""
    end
    return table.concat(vim.api.nvim_buf_get_text(0, start_line - 1, start_col, end_line - 1, end_col, {}), "\n")
end

-- Get the command to run (from project or filetype)
function M.get_command()
    local filepath = vim.fn.expand("%:p")
    local filetype = vim.bo.filetype
    
    -- First check if this file belongs to a project
    local project = utils.detect_project(filepath, config.options.project)
    if project and project.command then
        return project, "project"
    end
    
    -- Fall back to filetype runner
    local runner = config.options.runners[filetype]
    if runner then
        return runner, "filetype"
    end
    
    return nil, nil
end

-- Run code with specified mode
function M.run_code(range, mode)
    local filetype = vim.bo.filetype
    local execution_path
    local code_to_run

    if range > 0 then -- Visual mode execution
        code_to_run = get_visual_selection()
        if code_to_run == "" then
            ui.show_output("Error: Visual selection is empty.", mode)
            return
        end
        execution_path = vim.fn.tempname()
        local file = io.open(execution_path, "w")
        if file then
            file:write(code_to_run)
            file:close()
        else
            ui.show_output("Error: Could not write to temporary file.", mode)
            return
        end
    else -- Normal file execution
        execution_path = vim.fn.expand("%:p")
        if execution_path == "" then
            ui.show_output("Error: No file path. Please save the buffer.", mode)
            return
        end
    end

    -- Get command (project or filetype)
    local runner, source = M.get_command()
    
    if not runner then
        ui.show_output("Error: No runner configured for filetype: " .. filetype, mode)
        return
    end

    local command_str
    local cleanup_command
    local display_name

    if source == "project" then
        command_str = runner.command
        display_name = runner.name
    else
        command_str = utils.normalize_command(runner)
        if type(runner) == "table" and runner.cleanup_command then
            cleanup_command = runner.cleanup_command
        end
        display_name = filetype
    end

    -- Substitute variables in command
    local final_command = utils.substitute_variables(command_str, execution_path)
    
    -- If it's a project command, navigate to project root
    if source == "project" then
        local cwd = utils.get_project_root(execution_path, config.options.project)
        if cwd then
            final_command = "cd " .. vim.fn.shellescape(cwd) .. " && " .. final_command
        end
    end

    -- Use the plugin's Zig executable wrapper
    local zig_executable = PLUGIN_PATH .. "/zig/zig-out/bin/zig"
    
    if vim.fn.executable(zig_executable) ~= 1 then
        ui.show_output(
            "Error: Zig executable not found at: " .. zig_executable .. 
            "\n\nPlease run: cd " .. PLUGIN_PATH .. "/zig && zig build",
            mode
        )
        return
    end

    local system_command = zig_executable .. " " .. vim.fn.shellescape(final_command)
    
    M.execute_command(system_command, execution_path, range, mode, display_name, cleanup_command)
end

-- Execute command asynchronously
function M.execute_command(system_command, execution_path, range, mode, display_name, cleanup_command)
    mode = mode or config.options.mode or "float"
    
    -- For terminal modes, create terminal first and send command
    if mode ~= "float" then
        local term_id = ui.show_output("", mode)
        if term_id then
            ui.send_to_terminal(term_id, system_command)
            current_job_id = term_id
        end
        return
    end

    -- For float mode, capture output and display with spinner
    local output_lines = {}
    ui.show_spinner("Running " .. display_name .. "...", config.options.spinner or "dots", config.options.spinner_speed or 80)

    current_job_id = vim.fn.jobstart(system_command, {
        on_stdout = function(_, data)
            if data then
                for _, line in ipairs(data) do
                    if line ~= "" then
                        table.insert(output_lines, line)
                    end
                end
            end
        end,
        on_stderr = function(_, data)
            if data then
                for _, line in ipairs(data) do
                    if line ~= "" then
                        if config.options.show_stderr_prefix == false then
                            table.insert(output_lines, line)
                        else
                            -- Check if the current runner is for a language where stderr is commonly used for normal output
                            local current_filetype = vim.bo.filetype
                            local no_prefix_types = {"zig", "go", "rust"} -- Add languages that commonly output to stderr
                            
                            local has_error = false
                            if current_filetype and vim.tbl_contains(no_prefix_types, current_filetype) then
                                -- For these languages don't add [STDERR] prefix by default
                                table.insert(output_lines, line)
                            else
                                -- For other languages, add [STDERR] prefix unless it's clearly not an error
                                has_error = string.find(line, "error") or string.find(line, "Error") or 
                                           string.find(line, "failed") or string.find(line, "Failed") or
                                           string.find(line, "exception") or string.find(line, "Exception") or
                                           string.find(line, "panic") or string.find(line, "crash")
                                
                                if has_error then
                                    table.insert(output_lines, "[STDERR] " .. line)
                                else
                                    table.insert(output_lines, line)
                                end
                            end
                        end
                    end
                end
            end
        end,
        on_exit = function(_, exit_code)
            current_job_id = nil
            
            -- Clean up temporary file if created
            if range > 0 and execution_path then
                os.remove(execution_path)
            end

            if cleanup_command then
                os.execute(utils.substitute_variables(cleanup_command, execution_path))
            end

            local final_output = table.concat(output_lines, "\n")
            vim.schedule(function()
                ui.update_output_with_exit_animation(final_output, exit_code)
            end)
        end,
    })
end

-- Run current project
function M.run_project(mode)
    local runner, source = M.get_command()
    
    if not runner or source ~= "project" then
        ui.show_output("Error: Current file is not part of any configured project.", mode)
        return
    end
    
    if not runner.command then
        ui.show_output("Error: No command configured for project: " .. (runner.name or "Unknown"), mode)
        return
    end
    
    local filepath = vim.fn.expand("%:p")
    local cwd = utils.get_project_root(filepath, config.options.project)
    local command = runner.command
    
    if cwd then
        command = "cd " .. vim.fn.shellescape(cwd) .. " && " .. command
    end
    
    -- Substitute variables
    command = utils.substitute_variables(command, filepath)
    
    local zig_executable = PLUGIN_PATH .. "/zig/zig-out/bin/zig"
    if vim.fn.executable(zig_executable) == 1 then
        command = zig_executable .. " " .. command
    end
    
    M.execute_command(command, filepath, 0, mode, runner.name or "Project")
end

function M.stop_code()
    if current_job_id and current_job_id > 0 then
        vim.fn.jobstop(current_job_id)
        ui.show_output("Process " .. current_job_id .. " stopped.")
        current_job_id = nil
    else
        ui.show_output("No process is currently running.")
    end
end

function M.close_runner()
    ui.close_output()
end

function M.setup(opts)
    config.setup(opts)
end

-- Initialize with defaults if not already set up
if vim.tbl_isempty(config.options) then
    config.setup()
end

return M
