local path_utils = require("zignite.utils.path")

---@type table
local M = {}

---@type table<string, table>
local detect_cache = {}
---@type string[]
local detect_cache_order = {}
local DETECT_CACHE_MAX = 256

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
	local current_dir = dir
	for _ = 1, 10 do
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
			if vim.fn.filereadable(path_utils.join_path(current_dir, marker)) == 1 then
				local project = vim.tbl_extend("force", default_project_markers[marker], { root = current_dir })
				if marker == "package.json" or marker == "pyproject.toml" then
					project.command = nil
				end
				return project
			end
		end
		local parent = vim.fn.fnamemodify(current_dir, ":h")
		if parent == current_dir then
			break
		end
		current_dir = parent
	end
	return nil
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
		local normalized_path = vim.fs.normalize(filepath)

		for pattern, project_data in pairs(project_config) do
			local expanded_pattern = vim.fn.expand(pattern)
			local normalized_pattern = vim.fs.normalize(expanded_pattern)

			if normalized_path:match(normalized_pattern) then
				local matched_project = vim.tbl_extend("force", project_data, {
					root = infer_root_from_pattern(normalized_pattern),
				})
				set_detect_cache(cache_key, matched_project, pattern)
				return matched_project, pattern
			end

			if normalized_path:find(normalized_pattern, 1, true) then
				local matched_project = vim.tbl_extend("force", project_data, {
					root = infer_root_from_pattern(normalized_pattern),
				})
				set_detect_cache(cache_key, matched_project, pattern)
				return matched_project, pattern
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
