local M = {}

local detect_cache = {}
local detect_cache_order = {}
local DETECT_CACHE_MAX = 256

local function make_detect_cache_key(filepath, project_config)
	local dir = vim.fn.fnamemodify(filepath, ":h")
	local normalized_dir = vim.fs.normalize(dir)
	return tostring(project_config) .. "::" .. normalized_dir
end

local function set_detect_cache(key, project, pattern)
	if detect_cache[key] == nil then
		table.insert(detect_cache_order, key)
		if #detect_cache_order > DETECT_CACHE_MAX then
			local oldest = table.remove(detect_cache_order, 1)
			detect_cache[oldest] = nil
		end
	end

	detect_cache[key] = {
		project = project,
		pattern = pattern,
	}
end

function M.clear_project_cache()
	detect_cache = {}
	detect_cache_order = {}
end

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
	local dirName = vim.fn.fnamemodify(dir, ":t")    -- Just the directory name
	local fileDirPath = dir                          -- Full directory path (same as $dir)
	local relativeFile = vim.fn.fnamemodify(file, ":.") -- Relative to CWD
	local relativeDir = vim.fn.fnamemodify(dir, ":.") -- Relative dir to CWD

	-- Project Name detection
	local projectName = dirName
	local project_root = M.get_project_root(file)
	if project_root then
		projectName = vim.fn.fnamemodify(project_root, ":t")
	end
	local projectNameShort = projectName:gsub("%-cli$", ""):gsub("%-tui$", ""):gsub("%-app$", "")

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
		["$projectName"] = vim.fn.shellescape(projectName),
		["$projectNameShort"] = vim.fn.shellescape(projectNameShort),

		-- Unescaped versions (for cases where we need raw paths)
		["$DIR"] = dir,
		["$FILE"] = file,
		["$FILENAME"] = fileName,
		["$FILENAMEWITHOUTEXT"] = fileNameWithoutExt,
		["$PROJECTNAME"] = projectName,
		["$PROJECTNAMESHORT"] = projectNameShort,

		-- Legacy support for %
		["%%"] = vim.fn.shellescape(file),
	}

	-- Perform substitutions in a single pass using a replacement function
	local result = command:gsub("%$([%w_]+)", function(var)
		return substitutions["$" .. var] or ("$" .. var)
	end)

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
	-- Fallback for unknown variables
	result = result:gsub("%$([%w_]+)", function(var)
		return substitutions["$" .. var] or ("$" .. var)
	end)

	return result
end

-- Default project markers
local default_project_markers = {
	["package.json"] = { name = "Node.js Project", command = "npm start" },
	["Cargo.toml"] = { name = "Rust Project", command = "cargo run" },
	["go.mod"] = { name = "Go Project", command = "go run ." },
	["build.zig"] = { name = "Zig Project", command = "zig build run" },
	["pyproject.toml"] = { name = "Python Project", command = "python -m main" },
	["Makefile"] = { name = "Make Project", command = "make run" },
	["CMakeLists.txt"] = { name = "CMake Project", command = "[ ! -f build/Makefile ] && [ ! -f build/build.ninja ] && cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1; cmake --build build && { ./build/$fileNameWithoutExt || ./build/$dirName || ./build/main; }" },
	["meson.build"] = { name = "Meson Project", command = "[ ! -f build/build.ninja ] && meson setup build; meson compile -C build && { ./build/$fileNameWithoutExt || ./build/$dirName || ./build/main; }" },
}

-- Detect project by markers
local function detect_project_by_markers(filepath)
	local dir = vim.fn.fnamemodify(filepath, ":h")
	-- Check current directory and parent directories
	local current_dir = dir
	for _ = 1, 10 do -- Limit search to 10 levels up
		-- Priority order for detection
		local priority_markers = {
			"meson.build",
			"CMakeLists.txt",
			"build.zig",
			"Cargo.toml",
			"go.mod",
			"package.json",
			"pyproject.toml",
			"Makefile",
		}

		for _, marker in ipairs(priority_markers) do
			if vim.fn.filereadable(current_dir .. "/" .. marker) == 1 then
				return vim.tbl_extend("force", default_project_markers[marker], { root = current_dir })
			end
		end
		local parent = vim.fn.fnamemodify(current_dir, ":h")
		if parent == current_dir then
			break
		end -- Reached root
		current_dir = parent
	end
	return nil
end

-- Detect if current file belongs to a project
function M.detect_project(filepath, project_config)
	if not filepath or filepath == "" then
		return nil, nil
	end

	local cache_key = make_detect_cache_key(filepath, project_config)
	local cached = detect_cache[cache_key]
	if cached ~= nil then
		return cached.project, cached.pattern
	end

	-- First check user-defined projects
	if project_config and not vim.tbl_isempty(project_config) then
		local normalized_path = vim.fs.normalize(filepath)

		for pattern, project_data in pairs(project_config) do
			local expanded_pattern = vim.fn.expand(pattern)
			-- Normalize the pattern for matching
			local normalized_pattern = vim.fs.normalize(expanded_pattern)

			-- Try matching as Lua pattern (assuming user config keys are patterns)
			if normalized_path:match(normalized_pattern) then
				set_detect_cache(cache_key, project_data, pattern)
				return project_data, pattern
			end

			-- Also try simple substring matching for literal patterns
			if normalized_path:find(normalized_pattern, 1, true) then
				set_detect_cache(cache_key, project_data, pattern)
				return project_data, pattern
			end
		end
	end

	-- Fallback to marker-based detection
	local project = detect_project_by_markers(filepath)
	set_detect_cache(cache_key, project, nil)
	return project, nil
end

-- Get project root directory
function M.get_project_root(filepath, project_config)
	local project, pattern = M.detect_project(filepath, project_config)
	if not project then
		return nil
	end

	if project.root then
		return project.root
	end

	if pattern then
		local expanded_pattern = vim.fn.expand(pattern)
		-- Try to extract root from pattern
		local root = expanded_pattern:gsub("/%.%*$", ""):gsub("/%.%-$", ""):gsub("%.%*$", ""):gsub("%.-$", "")
		if root ~= expanded_pattern then
			return vim.fs.normalize(root)
		end
		-- Fallback: assume pattern is a directory path
		return vim.fs.normalize(expanded_pattern)
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
				commands = { trim(runner.cmd) }
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
