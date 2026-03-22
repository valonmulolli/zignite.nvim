-- Tests for zignite.utils module

package.path = package.path .. ";./lua/?.lua"
package.path = package.path .. ";./lua/?/init.lua"

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
    assert(project.command == nil, "Node marker fallback should no longer invent a project command")

    -- Restore
    vim.fn.filereadable = original_filereadable

    print("✓ Project marker detection test passed")
end

-- Test Bazel project marker detection
local function test_bazel_project_marker_detection()
    local original_filereadable = vim.fn.filereadable
    vim.fn.filereadable = function(path)
        if path:match("MODULE%.bazel$") then return 1 end
        return 0
    end

    local filepath = "/home/user/bazel-app/app/main.cc"
    local project = utils.detect_project(filepath, {})

    assert(project, "Bazel project not detected by marker")
    assert(project.name == "Bazel Project", "Bazel project name not correct")
    assert(project.command == "bazel build //...", "Bazel project command not correct")

    vim.fn.filereadable = original_filereadable

    print("✓ Bazel project marker detection test passed")
end

-- Test Node project marker detection uses the detected package manager.
local function test_node_project_marker_uses_detected_package_manager()
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile
    local original_vim_json = vim.json

    utils.clear_project_cache()
    vim.fn.filereadable = function(path)
        if path == "/home/user/project/package.json" or path == "/home/user/project/pnpm-lock.yaml" then
            return 1
        end
        return 0
    end
    vim.fn.readfile = function(path)
        if path == "/home/user/project/package.json" then
            return { '{"scripts":{"start":"vite"},"packageManager":"pnpm@9.0.0"}' }
        end
        return {}
    end
    vim.json = {
        decode = function(_)
            return {
                scripts = {
                    start = "vite",
                },
                packageManager = "pnpm@9.0.0",
            }
        end,
    }

    local filepath = "/home/user/project/src/main.js"
    local project = utils.detect_project(filepath, {})

    assert(project, "Node project should still be detected by marker")
    assert(project.command == nil, "Node marker fallback should not invent a package-manager command")

    utils.clear_project_cache()
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile
    vim.json = original_vim_json

    print("✓ Node project package manager marker test passed")
end

-- Test Go workspace marker detection prefers go.work over go.mod.
local function test_go_workspace_marker_detection()
    local original_filereadable = vim.fn.filereadable

    utils.clear_project_cache()
    vim.fn.filereadable = function(path)
        if path == "/home/user/gowork/go.work" or path == "/home/user/gowork/app/go.mod" then
            return 1
        end
        return 0
    end

    local filepath = "/home/user/gowork/app/cmd/web/main.go"
    local project = utils.detect_project(filepath, {})

    assert(project, "Go workspace should be detected by marker")
    assert(project.name == "Go Project", "Go workspace marker name should stay consistent")
    assert(project.command == nil, "Go workspace marker should not invent a root go run command")
    assert(project.root == "/home/user/gowork", "Go workspace marker should use the go.work root")

    utils.clear_project_cache()
    vim.fn.filereadable = original_filereadable

    print("✓ Go workspace marker detection test passed")
end

-- Test Python project marker detection prefers uv when uv markers are present.
local function test_python_project_marker_uses_uv()
    local original_filereadable = vim.fn.filereadable
    local original_readfile = vim.fn.readfile

    utils.clear_project_cache()
    vim.fn.filereadable = function(path)
        if path == "/home/user/pythonapp/pyproject.toml" or path == "/home/user/pythonapp/uv.lock" then
            return 1
        end
        return 0
    end
    vim.fn.readfile = function(path)
        if path == "/home/user/pythonapp/pyproject.toml" then
            return {
                "[project]",
                'name = "pythonapp"',
                "",
                "[tool.uv]",
            }
        end
        return {}
    end

    local filepath = "/home/user/pythonapp/src/main.py"
    local project = utils.detect_project(filepath, {})

    assert(project, "Python project should still be detected by marker")
    assert(project.command == nil, "Python marker fallback should not invent a uv main-module command")

    utils.clear_project_cache()
    vim.fn.filereadable = original_filereadable
    vim.fn.readfile = original_readfile

    print("✓ Python project uv marker test passed")
end

-- Test Gradle project marker detection resolves the build root without inventing a fallback command.
local function test_gradle_project_marker_detection()
    local original_filereadable = vim.fn.filereadable

    utils.clear_project_cache()
    vim.fn.filereadable = function(path)
        if path == "/home/user/gradle-app/settings.gradle" then
            return 1
        end
        return 0
    end

    local filepath = "/home/user/gradle-app/src/main/java/com/example/App.java"
    local project = utils.detect_project(filepath, {})

    assert(project, "Gradle project should be detected by marker")
    assert(project.name == "Gradle Project", "Gradle project name not correct")
    assert(project.command == nil, "Gradle marker fallback should not invent a run command")
    assert(project.root == "/home/user/gradle-app", "Gradle project root should use the settings.gradle root")

    utils.clear_project_cache()
    vim.fn.filereadable = original_filereadable

    print("✓ Gradle project marker detection test passed")
end

-- Test Maven project marker detection resolves the build root without inventing a fallback command.
local function test_maven_project_marker_detection()
    local original_filereadable = vim.fn.filereadable

    utils.clear_project_cache()
    vim.fn.filereadable = function(path)
        if path == "/home/user/maven-app/pom.xml" then
            return 1
        end
        return 0
    end

    local filepath = "/home/user/maven-app/src/main/java/com/example/App.java"
    local project = utils.detect_project(filepath, {})

    assert(project, "Maven project should be detected by marker")
    assert(project.name == "Maven Project", "Maven project name not correct")
    assert(project.command == nil, "Maven marker fallback should not invent a run command")
    assert(project.root == "/home/user/maven-app", "Maven project root should use the pom.xml root")

    utils.clear_project_cache()
    vim.fn.filereadable = original_filereadable

    print("✓ Maven project marker detection test passed")
end

-- Run all tests
test_substitute_variables()
test_normalize_command()
test_project_detection()
test_project_marker_detection()
test_bazel_project_marker_detection()
test_node_project_marker_uses_detected_package_manager()
test_go_workspace_marker_detection()
test_python_project_marker_uses_uv()
test_gradle_project_marker_detection()
test_maven_project_marker_detection()

print("All utils tests passed!")
