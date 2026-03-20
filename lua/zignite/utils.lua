---@type table
local M = {}
---@type table<string, table>
local detect_cache = {}
---@type string[]
local detect_cache_order = {}
local DETECT_CACHE_MAX = 256

---@param root string
---@param name string
---@return string
local function join_path(root, name)
	if vim.fs and type(vim.fs.joinpath) == "function" then
		return vim.fs.joinpath(root, name)
	end
	return tostring(root or "") .. "/" .. tostring(name or "")
end

---@param path string
---@return boolean
local function file_exists(path)
	return type(vim.fn.filereadable) == "function" and vim.fn.filereadable(path) == 1
end

---@param path string
---@return string|nil
local function read_text_file(path)
	if type(vim.fn.readfile) ~= "function" or not file_exists(path) then
		return nil
	end
	local lines = vim.fn.readfile(path)
	if type(lines) ~= "table" then
		return nil
	end
	return table.concat(lines, "\n")
end

---@param payload string
---@return table|nil
local function decode_json_payload(payload)
	if type(payload) ~= "string" or payload == "" then
		return nil
	end
	if vim.json and type(vim.json.decode) == "function" then
		local ok, decoded = pcall(vim.json.decode, payload)
		if ok then
			return decoded
		end
	end
	if vim.fn and type(vim.fn.json_decode) == "function" then
		local ok, decoded = pcall(vim.fn.json_decode, payload)
		if ok then
			return decoded
		end
	end
	return nil
end

---@param filepath string
---@param project_config table|nil
---@return string
local function make_detect_cache_key(filepath, project_config)
	local dir = vim.fn.fnamemodify(filepath, ":h")
	local normalized_dir = vim.fs.normalize(dir)
	return tostring(project_config) .. "::" .. normalized_dir
end

---@param key string
---@param project table|nil
---@param pattern string|nil
---@return nil
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

---@return nil
function M.clear_project_cache()
	detect_cache = {}
	detect_cache_order = {}
end

---@param package_manager string
---@param script_name string
---@return string
function M.format_package_script_command(package_manager, script_name)
	local manager = tostring(package_manager or "npm")
	local script = tostring(script_name or "")
	if manager == "bun" then
		return "bun run " .. script
	end
	if manager == "yarn" then
		return "yarn " .. script
	end
	if manager == "pnpm" then
		if script == "start" then
			return "pnpm start"
		end
		if script == "test" then
			return "pnpm test"
		end
		return "pnpm run " .. script
	end
	if script == "start" then
		return "npm start"
	end
	if script == "test" then
		return "npm test"
	end
	return "npm run " .. script
end

---@param package_manager string
---@return string
function M.format_package_install_command(package_manager)
	local manager = tostring(package_manager or "npm")
	if manager == "bun" then
		return "bun install"
	end
	if manager == "yarn" then
		return "yarn install"
	end
	if manager == "pnpm" then
		return "pnpm install"
	end
	return "npm install"
end

---@param root string|nil
---@return string
function M.detect_node_package_manager_root(root)
	if type(root) ~= "string" or root == "" then
		return "npm"
	end

	local package_json_path = join_path(root, "package.json")
	local payload = read_text_file(package_json_path)
	local parsed = decode_json_payload(payload or "")
	if type(parsed) == "table" and type(parsed.packageManager) == "string" then
		local manager_name = tostring(parsed.packageManager):match("^([%w_%-]+)@")
			or tostring(parsed.packageManager):match("^([%w_%-]+)")
		if manager_name == "npm" or manager_name == "pnpm" or manager_name == "yarn" or manager_name == "bun" then
			return manager_name
		end
	end

	if file_exists(join_path(root, "bun.lockb")) or file_exists(join_path(root, "bun.lock")) then
		return "bun"
	end
	if file_exists(join_path(root, "pnpm-lock.yaml")) then
		return "pnpm"
	end
	if file_exists(join_path(root, "yarn.lock")) then
		return "yarn"
	end
	return "npm"
end

---@param filepath string
---@param project_config table|nil
---@return string
function M.detect_node_package_manager(filepath, project_config)
	local root = M.get_project_root(filepath, project_config)
	if not root or root == "" then
		root = vim.fn.fnamemodify(filepath, ":h")
	end
	return M.detect_node_package_manager_root(root)
end

---@param root string|nil
---@return boolean
function M.is_uv_project_root(root)
	if type(root) ~= "string" or root == "" then
		return false
	end
	if file_exists(join_path(root, "uv.lock")) then
		return true
	end
	local pyproject_payload = read_text_file(join_path(root, "pyproject.toml"))
	if type(pyproject_payload) == "string" and pyproject_payload:find("%[tool%.uv%]", 1, false) then
		return true
	end
	return false
end

---@param filepath string
---@param project_config table|nil
---@return string
function M.detect_python_project_tool(filepath, project_config)
	local root = M.get_project_root(filepath, project_config)
	if not root or root == "" then
		root = vim.fn.fnamemodify(filepath, ":h")
	end
	if M.is_uv_project_root(root) then
		return "uv"
	end
	return "python"
end

-- Substitute variables in command string
-- This is inspired by code_runner.nvim's variable system
---@param command string
---@param filepath string
---@return string
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
---@param command string
---@param filepath string
---@return string
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
---@type table<string, table>
local default_project_markers = {
	["package.json"] = { name = "Node.js Project", command = "npm start" },
	["Cargo.toml"] = { name = "Rust Project", command = "cargo run" },
	["go.mod"] = { name = "Go Project", command = "go run ." },
	["build.zig"] = { name = "Zig Project", command = "zig build run" },
	["MODULE.bazel"] = { name = "Bazel Project", command = "bazel build //..." },
	["WORKSPACE.bazel"] = { name = "Bazel Project", command = "bazel build //..." },
	WORKSPACE = { name = "Bazel Project", command = "bazel build //..." },
	["pyproject.toml"] = { name = "Python Project", command = "python -m main" },
	["Makefile"] = { name = "Make Project", command = "make run" },
	["CMakeLists.txt"] = { name = "CMake Project", command = "[ ! -f build/Makefile ] && [ ! -f build/build.ninja ] && cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1; cmake --build build && { ./build/$fileNameWithoutExt || ./build/$dirName || ./build/main; }" },
	["meson.build"] = { name = "Meson Project", command = "[ ! -f build/build.ninja ] && meson setup build; meson compile -C build && { ./build/$fileNameWithoutExt || ./build/$dirName || ./build/main; }" },
}

-- Detect project by markers
---@param filepath string
---@return table|nil
local function detect_project_by_markers(filepath)
	local dir = vim.fn.fnamemodify(filepath, ":h")
	-- Check current directory and parent directories
	local current_dir = dir
	for _ = 1, 10 do -- Limit search to 10 levels up
		-- Priority order for detection
		local priority_markers = {
			"MODULE.bazel",
			"WORKSPACE.bazel",
			"WORKSPACE",
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
				local project = vim.tbl_extend("force", default_project_markers[marker], { root = current_dir })
				if marker == "package.json" then
					project.command = M.format_package_script_command(M.detect_node_package_manager_root(current_dir), "start")
				elseif marker == "pyproject.toml" and M.is_uv_project_root(current_dir) then
					project.command = "uv run -m main"
				end
				return project
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
---@param filepath string
---@param project_config table|nil
---@return table|nil, string|nil
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
---@param filepath string
---@param project_config table|nil
---@return string|nil
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

---@param s string
---@return string
local function trim(s)
	return s:match("^%s*(.-)%s*$")
end

---@param tbl string[]
---@return string[]
local function filter_empty(tbl)
	---@type string[]
	local new_tbl = {}
	for _, v in ipairs(tbl) do
		local trimmed = trim(v)
		if trimmed ~= "" then
			table.insert(new_tbl, trimmed)
		end
	end
	return new_tbl
end

---@param runner string|string[]|table
---@return string|nil
function M.normalize_command(runner)
	if type(runner) == "string" then
		return runner
	elseif type(runner) == "table" then
		---@type string[]
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
