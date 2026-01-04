-- Tests for zignite.utils module

-- Mock vim functions for testing
_G.vim = {
    fn = {
        expand = function(path)
            -- Simple mock that returns the path as-is for testing
            return path
        end,
        fnamemodify = function(path, modifier)
            if modifier == ":t" then
                -- Extract filename from path
                return path:match("([^/]+)$") or path
            elseif modifier == ":t:r" then
                -- Extract filename without extension
                local filename = path:match("([^/]+)$") or path
                return filename:gsub("%.([^%.]+)$", "")
            elseif modifier == ":h" then
                -- Extract directory
                return path:gsub("/[^/]+$", "") or ""
            elseif modifier == ":e" then
                -- Extract extension
                return path:match("%.([^%.]+)$") or ""
            elseif modifier == ":." then
                -- Relative path (simplified)
                return path
            end
            return path
        end,
        shellescape = function(str)
            return "'" .. str:gsub("'", "'\"'\"'") .. "'"
        end,
        filereadable = function(path)
            if path:match("package.json$") then return 1 end
            return 0
        end
    },
    fs = {
        normalize = function(path)
            return path
        end
    },
    tbl_isempty = function(tbl)
        return next(tbl) == nil
    end,
    tbl_extend = function(behavior, ...)
        local result = {}
        for i = 1, select('#', ...) do
            local tbl = select(i, ...)
            for k, v in pairs(tbl) do
                if type(v) == "table" and type(result[k]) == "table" then
                    result[k] = vim.tbl_extend(behavior, result[k], v)
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
    end
}

local utils = require('zignite.utils')

-- Test variable substitution
local function test_substitute_variables()
    local filepath = "/home/user/project/main.py"

    -- Test basic variables
    local result = utils.substitute_variables("$file $fileName $fileNameWithoutExt $dir $fileExt", filepath)
    print("Result: '" .. result .. "'") -- Debug output

    -- Check individual substitutions
    local file_sub = result:match("([^%s]+)")
    print("File sub: '" .. file_sub .. "'")
    assert(file_sub == "'/home/user/project/main.py'", "File path not substituted correctly")

    print("✓ Variable substitution test passed")
end

-- Test command normalization
local function test_normalize_command()
    -- Test string command
    local result = utils.normalize_command("python $file")
    assert(result == "python $file", "String command not normalized correctly")

    -- Test array command
    local result2 = utils.normalize_command({"cd $dir", "python $fileName"})
    assert(result2 == "cd $dir && python $fileName", "Array command not normalized correctly")

    -- Test table with cmd
    local result3 = utils.normalize_command({cmd = {"gcc $file", "./a.out"}, cleanup_command = "rm a.out"})
    assert(result3 == "gcc $file && ./a.out", "Table command not normalized correctly")

    print("✓ Command normalization test passed")
end

-- Test project detection
local function test_project_detection()
    local project_config = {
        ["/home/user/projects/myapp/.*"] = {
            name = "My App",
            command = "npm run dev"
        }
    }

    local filepath = "/home/user/projects/myapp/src/main.js"
    local project = utils.detect_project(filepath, project_config)

    assert(project, "Project not detected")
    assert(project.name == "My App", "Project name not correct")
    assert(project.command == "npm run dev", "Project command not correct")

    print("✓ Project detection test passed")
end

-- Test project marker detection
local function test_project_marker_detection()
    -- Mock vim.fn.filereadable
    local original_filereadable = vim.fn.filereadable
    vim.fn.filereadable = function(path)
        if path:match("package.json$") then return 1 end
        return 0
    end

    local filepath = "/home/user/project/src/main.js"
    local project = utils.detect_project(filepath, {})

    assert(project, "Project not detected by marker")
    assert(project.name == "Node.js Project", "Project name not correct")
    assert(project.command == "npm start", "Project command not correct")

    -- Restore
    vim.fn.filereadable = original_filereadable

    print("✓ Project marker detection test passed")
end

-- Run all tests
test_substitute_variables()
test_normalize_command()
test_project_detection()
test_project_marker_detection()

print("All utils tests passed!")