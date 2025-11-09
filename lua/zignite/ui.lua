local M = {}

-- Keep track of the last window to close it if a new run is triggered
local last_win_id = nil
local last_mode = nil

-- Spinner animation variables
local spinner_timer = nil
local spinner_frames = {
    dots = {".", "..", "...", "....", ".....", "....", "...", ".."},
    line = {"|", "/", "-", "\\"},
    bar = {" ", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█"},
    clock = {"◜", "◠", "◝", "◞", "◡", "◟"},
    arrows = {"←", "↖", "↑", "↗", "→", "↘", "↓", "↙"},
    dots2 = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"},
    triangle = {"◢", "◣", "◤", "◥"},
    square = {"◰", "◳", "◲", "◱"},
    circle = {"◐", "◓", "◑", "◒"},
    arrow = {"▹▹▹▹▹", "▸▹▹▹▹", "▹▸▹▹▹", "▹▹▸▹▹", "▹▹▹▸▹", "▹▹▹▹▸"},
    box = {"[    ]", "[=   ]", "[==  ]", "[=== ]", "[====]", "[ ===]", "[  ==]", "[   =]"},
}

-- Show output in floating window
function M.show_float(content)
    local config = require('zignite.config').options.float

    local lines = vim.split(content, "\n")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype = 'zignite'

    -- Calculate window dimensions and position from config
    local width = math.floor(vim.o.columns * config.width)
    local height = math.floor(vim.o.lines * config.height)
    local col = math.floor((vim.o.columns - width) * config.x)
    local row = math.floor((vim.o.lines - height) * config.y)

    local opts = {
        relative = "editor",
        style = "minimal",
        width = width,
        height = height,
        col = col,
        row = row,
        border = config.border,
    }

    local win = vim.api.nvim_open_win(buf, config.focus or true, opts)
    
    -- Set border highlight
    vim.api.nvim_set_option_value('winhl', 'Normal:Normal,FloatBorder:' .. config.border_hl, { win = win })

    -- Handle startinsert option
    if config.startinsert then
        vim.cmd("startinsert")
    end

    -- Keymap to close the window
    vim.api.nvim_buf_set_keymap(buf, "n", config.close_key, ":close<CR>", { noremap = true, silent = true })

    return win
end

-- Show output in terminal (split, vsplit, or tab)
function M.show_terminal(mode)
    local config = require('zignite.config').options.term
    
    -- Create a new terminal buffer
    local buf = vim.api.nvim_create_buf(false, true)
    
    local win
    if mode == "tab" then
        vim.cmd("tabnew")
        win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, buf)
    elseif mode == "vsplit" then
        vim.cmd("vsplit")
        win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, buf)
    elseif mode == "split" then
        vim.cmd("split")
        win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, buf)
        -- Resize to configured size
        vim.api.nvim_win_set_height(win, config.size)
    else
        -- Default to bottom split
        vim.cmd("botright split")
        win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, buf)
        vim.api.nvim_win_set_height(win, config.size)
    end

    -- Set buffer options
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].filetype = 'zignite'
    vim.bo[buf].bufhidden = 'wipe'
    
    -- Create terminal
    local term_id = vim.fn.termopen(vim.o.shell)
    
    -- Focus or not based on config
    if not config.focus then
        vim.cmd("wincmd p")
    elseif config.startinsert then
        vim.cmd("startinsert")
    end

    return win, term_id
end

-- Update terminal with new content
function M.update_terminal(buf, content)
    if not vim.api.nvim_buf_is_valid(buf) then
        return false
    end
    
    local lines = vim.split(content, "\n")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return true
end

-- Send command to terminal
function M.send_to_terminal(term_id, command)
    if term_id then
        vim.fn.chansend(term_id, command .. "\n")
    end
end

-- Main function to show output based on mode
function M.show_output(content, mode)
    -- Close previous window if it exists
    M.close_output()

    mode = mode or require('zignite.config').options.mode or "float"
    last_mode = mode

    if mode == "float" then
        last_win_id = M.show_float(content)
    else
        -- For terminal modes, just create the terminal
        -- Content will be sent via command execution
        local win, term_id = M.show_terminal(mode)
        last_win_id = win
        return term_id
    end
end

-- Update existing output
function M.update_output(content)
    -- Stop spinner if it's running
    M.stop_spinner()
    
    if last_mode == "float" then
        if last_win_id and vim.api.nvim_win_is_valid(last_win_id) then
            local buf = vim.api.nvim_win_get_buf(last_win_id)
            if buf and vim.api.nvim_buf_is_valid(buf) then
                local lines = vim.split(content, "\n")
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
            end
        end
    end
end

-- Update output with exit code animation
function M.update_output_with_exit_animation(output, exit_code)
    -- First stop any running spinner
    M.stop_spinner()
    
    if last_mode ~= "float" then
        -- For non-float modes, just update normally
        M.update_output(output .. "\n\n--- Exited with code " .. exit_code .. " ---")
        return
    end
    
    if not (last_win_id and vim.api.nvim_win_is_valid(last_win_id)) then
        return
    end
    
    local buf = vim.api.nvim_win_get_buf(last_win_id)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return
    end
    
    -- Show the main output first
    local output_lines = vim.split(output, "\n")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, output_lines)
    
    -- Add a more engaging exit animation
    local animation_timer = vim.loop.new_timer()
    local frame = 1
    -- More engaging animation sequence 
    local animation_frames = {
        "Processing... ",      -- Initial status
        "Finishing.   ",       -- Dots progress
        "Finishing..  ", 
        "Finishing... ", 
        "Exit code: " .. exit_code .. " ",
        "Exit code: " .. exit_code .. " .",
        "Exit code: " .. exit_code .. " ..",
        "Exit code: " .. exit_code .. " ...",
        "Status: " .. exit_code .. " ✓",  -- Final status with checkmark
    }
    local animation_cycles = 0
    local max_cycles = 1  -- Single cycle through the frames
    
    -- Start with initial message
    local all_lines = vim.list_extend(vim.split(output, "\n"), {"", animation_frames[frame]})
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
    
    animation_timer:start(0, 200, vim.schedule_wrap(function()  -- Faster interval for better animation
        -- Check if the window still exists before updating
        if not last_win_id or not vim.api.nvim_win_is_valid(last_win_id) then
            if not animation_timer:is_closing() then
                animation_timer:stop()
                animation_timer:close()
            end
            return
        end
        
        local current_buf = vim.api.nvim_win_get_buf(last_win_id)
        if not (current_buf and vim.api.nvim_buf_is_valid(current_buf)) then
            if not animation_timer:is_closing() then
                animation_timer:stop()
                animation_timer:close()
            end
            return
        end
        
        frame = frame + 1
        if frame <= #animation_frames then
            local message = animation_frames[frame]
            local all_lines = vim.list_extend(vim.split(output, "\n"), {"", message})
            vim.api.nvim_buf_set_lines(current_buf, 0, -1, false, all_lines)
        else
            -- Final message after animation completes
            if vim.api.nvim_win_is_valid(last_win_id) then
                local current_final_buf = vim.api.nvim_win_get_buf(last_win_id)
                if current_final_buf and vim.api.nvim_buf_is_valid(current_final_buf) then
                    -- Show the final message without animation
                    local final_lines = vim.list_extend(vim.split(output, "\n"), {"", "--- Exited with code " .. exit_code .. " ---"})
                    vim.api.nvim_buf_set_lines(current_final_buf, 0, -1, false, final_lines)
                end
            end
            
            if not animation_timer:is_closing() then
                animation_timer:stop()
                animation_timer:close()
            end
        end
    end))
end

function M.close_output()
    if last_win_id and vim.api.nvim_win_is_valid(last_win_id) then
        vim.api.nvim_win_close(last_win_id, true)
    end
    last_win_id = nil
    last_mode = nil
    
    -- Stop any running spinner
    M.stop_spinner()
end

-- Spinner animation functions
function M.show_spinner(initial_message, spinner_type, spinner_speed)
    -- Stop any existing spinner
    M.stop_spinner()
    
    -- Get spinner frames
    local frames = spinner_frames[spinner_type] or spinner_frames.dots
    local frame_index = 1
    
    -- Show initial message with first spinner frame
    M.show_output(initial_message .. " " .. frames[frame_index], "float")
    
    -- Create a timer for the spinner animation
    spinner_timer = vim.loop.new_timer()
    
    spinner_timer:start(0, spinner_speed or 80, vim.schedule_wrap(function()
        -- Check if the window still exists before updating
        if not last_win_id or not vim.api.nvim_win_is_valid(last_win_id) then
            M.stop_spinner()
            return
        end
        
        frame_index = frame_index + 1
        if frame_index > #frames then
            frame_index = 1
        end
        
        -- Update the output with the new spinner frame
        local current_output = initial_message .. " " .. frames[frame_index]
        local buf = vim.api.nvim_win_get_buf(last_win_id)
        if buf and vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {current_output})
        end
    end))
end

function M.stop_spinner()
    if spinner_timer then
        spinner_timer:stop()
        spinner_timer:close()
        spinner_timer = nil
    end
end

return M