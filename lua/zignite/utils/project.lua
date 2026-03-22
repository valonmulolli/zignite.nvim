local path_utils = require("zignite.utils.path")

---@type table
local M = {}

---@type table<string, table>
local detect_cache = {}
---@type string[]
local detect_cache_order = {}
local DETECT_CACHE_MAX = 256
local MAX_PROJECT_LOOKUP_UP = 10

---@type table<string, table>
local default_project_markers = {
	["package.json"] = { name = "Node.js Project", command = "npm start" },
	["pom.xml"] = { name = "Maven Project", command = nil },
	["settings.gradle"] = { name = "Gradle Project", command = nil },
	["settings.gradle.kts"] = { name = "Gradle Project", command = nil },
	["build.gradle"] = { name = "Gradle Project", command = nil },
	["build.gradle.kts"] = { name = "Gradle Project", command = nil },
	gradlew = { name = "Gradle Project", command = nil },
	["Cargo.toml"] = { name = "Rust Project", command = "cargo run" },
	["go.work"] = { name = "Go Project", command = nil },
	["go.mod"] = { name = "Go Project", command = "go run ." },
	["build.zig"] = { name = "Zig Project", command = "zig build run" },
	["MODULE.bazel"] = { name = "Bazel Project", command = "bazel build //..." },
	["WORKSPACE.bazel"] = { name = "Bazel Project", command = "bazel build //..." },
	WORKSPACE = { name = "Bazel Project", command = "bazel build //..." },
	["pyproject.toml"] = { name = "Python Project", command = "python -m main" },
	["Makefile"] = { name = "Make Project", command = "make run" },
	["CMakeLists.txt"] = {
		name = "CMake Project",
		command = "[ ! -f build/Makefile ] && [ ! -f build/build.ninja ] "
			.. "&& cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1; "
			.. "cmake --build build && { ./build/$fileNameWithoutExt || ./build/$dirName || ./build/main; }",
	},
	["meson.build"] = {
		name = "Meson Project",
		command = "[ ! -f build/build.ninja ] && meson setup build; "
			.. "meson compile -C build && { ./build/$fileNameWithoutExt || ./build/$dirName || ./build/main; }",
	},
}

local PROJECT_MARKER_PRIORITY = {
	"MODULE.bazel",
	"WORKSPACE.bazel",
	"WORKSPACE",
	"settings.gradle.kts",
	"settings.gradle",
	"build.gradle.kts",
	"build.gradle",
	"gradlew",
	"pom.xml",
	"meson.build",
	"CMakeLists.txt",
	"build.zig",
	"Cargo.toml",
	"go.work",
	"go.mod",
	"package.json",
	"pyproject.toml",
	"Makefile",
}

local PROJECT_MARKERS_WITHOUT_FALLBACK_COMMAND = {
	["package.json"] = true,
	["pyproject.toml"] = true,
	["pom.xml"] = true,
	["settings.gradle"] = true,
	["settings.gradle.kts"] = true,
	["build.gradle"] = true,
	["build.gradle.kts"] = true,
	gradlew = true,
}

---@param pattern string
---@return string
local function infer_root_from_pattern(pattern)
	local normalized = vim.fs.normalize(pattern)
	for _, suffix in ipairs({ "/.*", "/.-", ".*", ".-" }) do
		if normalized:sub(-#suffix) == suffix then
			normalized = normalized:sub(1, #normalized - #suffix)
			return vim.fs.normalize(normalized:gsub("/+$", ""))
		end
	end

	local first_magic = normalized:find("[%*%+%?%[%]%(%)%^%$]")
	if first_magic and first_magic > 1 then
		local prefix = normalized:sub(1, first_magic - 1)
		prefix = prefix:gsub("/+$", "")
		if prefix ~= "" then
			return vim.fs.normalize(prefix)
		end
	end

	return vim.fs.normalize(normalized)
end

---@param filepath string
---@param project_config table|nil
---@return string
local function make_detect_cache_key(filepath, project_config)
	local dir = vim.fn.fnamemodify(filepath, ":h")
	local normalized_dir = vim.fs.normalize(dir)
	return tostring(project_config) .. "::" .. normalized_dir
end

---@param path string
---@return boolean
local function is_readable_file(path)
	return vim.fn.filereadable(path) == 1
end

---@param start_dir string
---@param max_up integer
---@param callback fun(dir: string): table|nil
---@return table|nil
local function walk_parent_dirs(start_dir, max_up, callback)
	local current_dir = start_dir
	for _ = 1, max_up do
		local result = callback(current_dir)
		if result ~= nil then
			return result
		end
		local parent = vim.fn.fnamemodify(current_dir, ":h")
		if parent == current_dir then
			break
		end
		current_dir = parent
	end
	return nil
end

---@param project_data table
---@param root string
---@return table
local function build_project_from_data(project_data, root)
	return vim.tbl_extend("force", project_data, { root = root })
end

---@param marker string
---@param root string
---@return table
local function build_marker_project(marker, root)
	local project = build_project_from_data(default_project_markers[marker], root)
	if PROJECT_MARKERS_WITHOUT_FALLBACK_COMMAND[marker] then
		project.command = nil
	end
	return project
end

---@param filepath string
---@param pattern string
---@param project_data table
---@return table|nil, string|nil
local function match_project_pattern(filepath, pattern, project_data)
	local normalized_path = vim.fs.normalize(filepath)
	local expanded_pattern = vim.fn.expand(pattern)
	local normalized_pattern = vim.fs.normalize(expanded_pattern)

	if normalized_path:match(normalized_pattern) or normalized_path:find(normalized_pattern, 1, true) then
		local matched_project = build_project_from_data(project_data, infer_root_from_pattern(normalized_pattern))
		return matched_project, pattern
	end

	return nil, nil
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

---@param filepath string
---@return table|nil
local function detect_project_by_markers(filepath)
	local dir = vim.fn.fnamemodify(filepath, ":h")

	if vim.fn.fnamemodify(filepath, ":e") == "go" then
		local workspace_project = walk_parent_dirs(dir, MAX_PROJECT_LOOKUP_UP, function(current_dir)
			if is_readable_file(path_utils.join_path(current_dir, "go.work")) then
				return build_marker_project("go.work", current_dir)
			end
		end)
		if workspace_project then
			return workspace_project
		end
	end

	return walk_parent_dirs(dir, MAX_PROJECT_LOOKUP_UP, function(current_dir)
		for _, marker in ipairs(PROJECT_MARKER_PRIORITY) do
			if is_readable_file(path_utils.join_path(current_dir, marker)) then
				return build_marker_project(marker, current_dir)
			end
		end
	end)
end

---@return nil
function M.clear_project_cache()
	detect_cache = {}
	detect_cache_order = {}
end

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

	if project_config and not vim.tbl_isempty(project_config) then
		for pattern, project_data in pairs(project_config) do
			local matched_project, matched_pattern = match_project_pattern(filepath, pattern, project_data)
			if matched_project then
				set_detect_cache(cache_key, matched_project, pattern)
				return matched_project, matched_pattern
			end
		end
	end

	local project = detect_project_by_markers(filepath)
	set_detect_cache(cache_key, project, nil)
	return project, nil
end

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
		return infer_root_from_pattern(expanded_pattern)
	end

	return vim.fn.fnamemodify(filepath, ":h")
end

return M
