local M = {}

-- Substitute variables in command string
-- This is inspired by code_runner.nvim's variable system
function M.substitute_variables(command, filepath)
    if not filepath or filepath == "" then
        return command
    end

    local file = vim.fn.expand(filepath)
    local fileName = vim.fn.fnamemodify(file, ":t")
    local fileNameWithoutExt = vim.fn.fnamemodify(file, ":t:r")
    local dir = vim.fn.fnamemodify(file, ":h")
    local fileExt = vim.fn.fnamemodify(file, ":e")
    
    -- Additional useful variables
    local dirName = vim.fn.fnamemodify(dir, ":t")  -- Just the directory name
    local fileDirPath = dir  -- Full directory path (same as $dir)
    local relativeFile = vim.fn.fnamemodify(file, ":.")  -- Relative to CWD
    local relativeDir = vim.fn.fnamemodify(dir, ":.")  -- Relative dir to CWD

    -- Create substitution map with proper escaping
    local substitutions = {
        -- Primary variables (matching code_runner.nvim style)
        ["$dir"] = vim.fn.shellescape(dir),
        ["$file"] = vim.fn.shellescape(file),
        ["$fileName"] = vim.fn.shellescape(fileName),
        ["$fileNameWithoutExt"] = vim.fn.shellescape(fileNameWithoutExt),
        ["$fileExt"] = fileExt,
        
        -- Additional useful variables
        ["$dirName"] = vim.fn.shellescape(dirName),
        ["$fileDirPath"] = vim.fn.shellescape(fileDirPath),
        ["$relativeFile"] = vim.fn.shellescape(relativeFile),
        ["$relativeDir"] = vim.fn.shellescape(relativeDir),
        
        -- Unescaped versions (for cases where we need raw paths)
        ["$DIR"] = dir,
        ["$FILE"] = file,
        ["$FILENAME"] = fileName,
        ["$FILENAMEWITHOUTEXT"] = fileNameWithoutExt,
        
        -- Legacy support for %
        ["%%"] = vim.fn.shellescape(file),
    }

    -- Perform substitutions
    local result = command
    
    -- First pass: replace all variables
    for pattern, replacement in pairs(substitutions) do
        -- Escape special pattern characters for Lua pattern matching
        local escaped_pattern = pattern:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
        result = result:gsub(escaped_pattern, replacement)
    end

    return result
end

-- Enhanced variable substitution that doesn't escape paths
-- Useful when paths are already within quoted strings
function M.substitute_variables_raw(command, filepath)
    if not filepath or filepath == "" then
        return command
    end

    local file = vim.fn.expand(filepath)
    local fileName = vim.fn.fnamemodify(file, ":t")
    local fileNameWithoutExt = vim.fn.fnamemodify(file, ":t:r")
    local dir = vim.fn.fnamemodify(file, ":h")
    local fileExt = vim.fn.fnamemodify(file, ":e")

    -- Substitution map without shell escaping
    local substitutions = {
        ["$dir"] = dir,
        ["$file"] = file,
        ["$fileName"] = fileName,
        ["$fileNameWithoutExt"] = fileNameWithoutExt,
        ["$fileExt"] = fileExt,
        ["%%"] = file,
    }

    local result = command
    for pattern, replacement in pairs(substitutions) do
        local escaped_pattern = pattern:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
        result = result:gsub(escaped_pattern, replacement)
    end

    return result
end

-- Detect if current file belongs to a project
function M.detect_project(filepath, project_config)
    if not project_config or vim.tbl_isempty(project_config) then
        return nil, nil
    end

    local normalized_path = vim.fs.normalize(filepath)

    for pattern, project_data in pairs(project_config) do
        local expanded_pattern = vim.fn.expand(pattern)
        -- Normalize the pattern for matching
        local normalized_pattern = vim.fs.normalize(expanded_pattern)
        
        -- Try Lua pattern matching
        if normalized_path:match(normalized_pattern) then
            return project_data, pattern
        end
        
        -- Also try simple substring matching for simpler patterns
        if normalized_path:find(normalized_pattern, 1, true) then
            return project_data, pattern
        end
    end

    return nil, nil
end

-- Get project root directory
function M.get_project_root(filepath, project_config)
    local project, pattern = M.detect_project(filepath, project_config)
    if not project then
        return nil
    end

    if pattern then
        local expanded_pattern = vim.fn.expand(pattern)
        -- Remove the pattern part to get the root
        local root = expanded_pattern:gsub("/%.%*$", ""):gsub("/%.%-$", "")
        return vim.fs.normalize(root)
    end

    return vim.fn.fnamemodify(filepath, ":h")
end

-- Get all available variables for a given filepath (useful for debugging)
function M.get_available_variables(filepath)
    if not filepath or filepath == "" then
        return {}
    end

    local file = vim.fn.expand(filepath)
    local fileName = vim.fn.fnamemodify(file, ":t")
    local fileNameWithoutExt = vim.fn.fnamemodify(file, ":t:r")
    local dir = vim.fn.fnamemodify(file, ":h")
    local fileExt = vim.fn.fnamemodify(file, ":e")
    local dirName = vim.fn.fnamemodify(dir, ":t")

    return {
        ["$file"] = file,
        ["$fileName"] = fileName,
        ["$fileNameWithoutExt"] = fileNameWithoutExt,
        ["$dir"] = dir,
        ["$fileExt"] = fileExt,
        ["$dirName"] = dirName,
    }
end

local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

local function filter_empty(tbl)
    local new_tbl = {}
    for _, v in ipairs(tbl) do
        local trimmed = trim(v)
        if trimmed ~= "" then
            table.insert(new_tbl, trimmed)
        end
    end
    return new_tbl
end

function M.normalize_command(runner)
    if type(runner) == "string" then
        return runner
    elseif type(runner) == "table" then
        local commands
        if runner.cmd then
            if type(runner.cmd) == "table" then
                commands = filter_empty(runner.cmd)
            else
                commands = {trim(runner.cmd)}
            end
        else
            commands = filter_empty(runner)
        end

        if #commands == 0 then
            return nil
        elseif #commands == 1 then
            return commands[1]
        else
            return table.concat(commands, " && ")
        end
    end
    return nil
end

return M