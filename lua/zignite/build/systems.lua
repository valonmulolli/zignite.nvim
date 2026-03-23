local config = require("zignite.config")
local detect_backend = require("zignite.build.detect.backend")
local state = require("zignite.build.state")
local utils = require("zignite.utils")

---@type table
local M = {}

M.BAZEL_ROOT_MARKERS = { "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE" }
M.CMAKE_ROOT_MARKERS = { "CMakeLists.txt" }
M.MESON_ROOT_MARKERS = { "meson.build" }
M.BAZEL_PROJECT_FILETYPES = {
	bazel = true,
	bzl = true,
	c = true,
	cpp = true,
	go = true,
	java = true,
	javascript = true,
	kotlin = true,
	lua = true,
	odin = true,
	python = true,
	rust = true,
	sh = true,
	typescript = true,
	zsh = true,
	zig = true,
}

---@param root string|nil
---@return string|nil
local function get_build_dir(root)
	if type(root) ~= "string" or root == "" then
		return nil
	end
	return vim.fs.joinpath(root, "build")
end

---@param root string|nil
---@param relative_path string
---@return boolean
local function build_dir_has_file(root, relative_path)
	local build_dir = get_build_dir(root)
	if not build_dir or type(vim.fn.filereadable) ~= "function" then
		return false
	end
	return vim.fn.filereadable(vim.fs.joinpath(build_dir, relative_path)) == 1
end

---@param base_command string
---@param target string|nil
---@param target_prefix string
---@return string
local function append_target_argument(base_command, target, target_prefix)
	if type(target) ~= "string" or target == "" then
		return base_command
	end
	return base_command .. target_prefix .. target
end

---@param root string|nil
---@param is_ready boolean
---@param setup_command string
---@param build_command string
---@return string
local function with_optional_setup(root, is_ready, setup_command, build_command)
	local _ = root
	if is_ready then
		return build_command
	end
	return setup_command .. " && " .. build_command
end

---@param filepath string
---@param query string
---@param project_root string|nil
---@return table|nil
local function query_system_backend(filepath, query, project_root)
	if type(filepath) ~= "string" or filepath == "" then
		return nil
	end
	---@type string[]
	local extra_args = { "--query=" .. query }
	if type(project_root) == "string" and project_root ~= "" then
		extra_args[#extra_args + 1] = "--project-root=" .. project_root
	end
	local lines = detect_backend.parse_project_lines_once("system", filepath, extra_args)
	if type(lines) ~= "table" or #lines == 0 then
		return nil
	end

	local result = {}
	for _, raw_line in ipairs(lines) do
		local kind, value = tostring(raw_line or ""):match("^([^\t]+)\t(.+)$")
		if kind == "ROOT" and value ~= "" then
			result.root = value
		elseif kind == "SYSTEM" and value ~= "" then
			result.system = value
		elseif kind == "BUILD_READY" then
			result.build_ready = value == "1"
		end
	end
	return next(result) ~= nil and result or nil
end

---@param filepath string
---@return string
function M.resolve_project_root_for_detection(filepath)
	local root = utils.get_project_root(filepath, config.options.project)
	if root and root ~= "" then
		return vim.fs.normalize(root)
	end
	return vim.fs.normalize(vim.fn.fnamemodify(filepath, ":h"))
end

---@param start_path string
---@param candidates string[]
---@param max_up integer
---@return string|nil
function M.find_root_for_files(start_path, candidates, max_up)
	local dir = vim.fn.fnamemodify(start_path, ":h")
	local limit = max_up or 10
	for _ = 1, limit do
		for _, file_name in ipairs(candidates) do
			if vim.fn.filereadable(vim.fs.joinpath(dir, file_name)) == 1 then
				return dir
			end
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then
			break
		end
		dir = parent
	end
	return nil
end

---@param root string
---@param markers string[]
---@return boolean
function M.root_has_any_marker(root, markers)
	for _, marker in ipairs(markers) do
		if vim.fn.filereadable(vim.fs.joinpath(root, marker)) == 1 then
			return true
		end
	end
	return false
end

---@param root string
---@param markers string[]
---@return string
function M.build_marker_signature(root, markers)
	---@type string[]
	local signatures = {}
	for _, marker in ipairs(markers) do
		local path = vim.fs.joinpath(root, marker)
		local signature = "missing"
		if type(vim.fn.filereadable) == "function" and vim.fn.filereadable(path) == 1 then
			signature = state.get_file_mtime_key(path) or "unknown"
		end
		signatures[#signatures + 1] = marker .. ":" .. signature
	end
	return table.concat(signatures, "|")
end

---@param filepath string
---@return string|nil
function M.resolve_bazel_root(filepath)
	local root = utils.get_project_root(filepath, config.options.project)
	if root and M.root_has_any_marker(root, M.BAZEL_ROOT_MARKERS) then
		return root
	end
	return M.find_root_for_files(filepath, M.BAZEL_ROOT_MARKERS, 12)
end

---@param filepath string
---@return string|nil, string|nil
function M.resolve_jvm_root(filepath)
	local root = utils.get_project_root(filepath, config.options.project)
	local found_root = root
	if not found_root or found_root == "" then
		found_root = M.find_root_for_files(filepath, { "pom.xml", "gradlew", "build.gradle", "build.gradle.kts" }, 12)
	end
	if not found_root or found_root == "" then
		return nil, nil
	end
	if M.root_has_marker(found_root, "pom.xml") then
		return found_root, "maven"
	end
	if M.root_has_any_marker(found_root, { "gradlew", "build.gradle", "build.gradle.kts" }) then
		return found_root, "gradle"
	end
	return found_root, nil
end

---@param filetype string
---@return boolean
function M.supports_bazel_project_commands(filetype)
	if type(filetype) ~= "string" or filetype == "" then
		return false
	end
	return M.BAZEL_PROJECT_FILETYPES[filetype] == true
end

---@param root string
---@param marker string
---@return boolean
function M.root_has_marker(root, marker)
	return type(vim.fn.filereadable) == "function" and vim.fn.filereadable(vim.fs.joinpath(root, marker)) == 1
end

---@param root string|nil
---@return boolean
function M.has_cmake_build_tree(root)
	if build_dir_has_file(root, "CMakeCache.txt") then
		return true
	end
	local backend = query_system_backend(root, "c-family", root)
	if type(backend) == "table" and backend.system == "cmake" and type(backend.build_ready) == "boolean" then
		return backend.build_ready
	end
	return false
end

---@param root string|nil
---@return boolean
function M.has_meson_build_tree(root)
	if build_dir_has_file(root, "build.ninja") then
		return true
	end
	if build_dir_has_file(root, vim.fs.joinpath("meson-private", "coredata.dat")) then
		return true
	end
	local backend = query_system_backend(root, "c-family", root)
	if type(backend) == "table" and backend.system == "meson" and type(backend.build_ready) == "boolean" then
		return backend.build_ready
	end
	return false
end

---@param root string|nil
---@return string
function M.cmake_config_command(root)
	local _ = root
	return "cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1"
end

---@param root string|nil
---@param target string|nil
---@return string
function M.cmake_build_command(root, target)
	local build_cmd = append_target_argument("cmake --build build", target, " --target ")
	return with_optional_setup(root, M.has_cmake_build_tree(root), M.cmake_config_command(root), build_cmd)
end

---@param root string|nil
---@return string
function M.cmake_clean_command(root)
	if M.has_cmake_build_tree(root) then
		return "cmake --build build --target clean"
	end
	return "cmake -E rm -rf build"
end

---@param root string|nil
---@return string
function M.meson_setup_command(root)
	local _ = root
	return "meson setup build"
end

---@param root string|nil
---@param target string|nil
---@return string
function M.meson_build_command(root, target)
	local build_cmd = append_target_argument("meson compile -C build", target, " ")
	return with_optional_setup(root, M.has_meson_build_tree(root), M.meson_setup_command(root), build_cmd)
end

---@param root string|nil
---@return string
function M.meson_clean_command(root)
	if M.has_meson_build_tree(root) then
		return "meson compile -C build --clean"
	end
	return "cmake -E rm -rf build"
end

---@param filepath string
---@return string|nil, string|nil
function M.detect_c_family_build_system(filepath)
	if not filepath or filepath == "" then
		return nil, nil
	end

	local root = M.resolve_project_root_for_detection(filepath)
	if root == "" then
		return nil, nil
	end

	if M.root_has_any_marker(root, M.BAZEL_ROOT_MARKERS) then
		return "bazel", root
	end
	if M.root_has_any_marker(root, M.MESON_ROOT_MARKERS) then
		return "meson", root
	end
	if M.root_has_any_marker(root, M.CMAKE_ROOT_MARKERS) then
		return "cmake", root
	end
	if M.root_has_marker(root, "Makefile") then
		return "make", root
	end
	return nil, root
end

---@param path string
---@return string
function M.detect_file_signature(path)
	if type(vim.fn.filereadable) ~= "function" or vim.fn.filereadable(path) ~= 1 then
		return "missing"
	end
	return state.get_file_mtime_key(path) or "unknown"
end

---@param filetype string
---@param filepath string
---@param is_detection_enabled fun(flag: string): boolean
---@return string|nil
function M.get_mtime_signature_for_filetype(filetype, filepath, is_detection_enabled)
	local root = M.resolve_project_root_for_detection(filepath)
	local signature = nil

	if filetype == "c" or filetype == "cpp" then
		local signatures = {
			"Makefile:" .. M.detect_file_signature(vim.fs.joinpath(root, "Makefile")),
			"CMakeLists.txt:" .. M.detect_file_signature(vim.fs.joinpath(root, "CMakeLists.txt")),
			"meson.build:" .. M.detect_file_signature(vim.fs.joinpath(root, "meson.build")),
		}
		signature = table.concat(signatures, "|")
	elseif filetype == "javascript" or filetype == "typescript" then
		signature = "package.json:" .. M.detect_file_signature(vim.fs.joinpath(root, "package.json"))
	elseif filetype == "java" or filetype == "kotlin" then
		local signatures = {
			"pom.xml:" .. M.detect_file_signature(vim.fs.joinpath(root, "pom.xml")),
			"gradlew:" .. M.detect_file_signature(vim.fs.joinpath(root, "gradlew")),
			"build.gradle:" .. M.detect_file_signature(vim.fs.joinpath(root, "build.gradle")),
			"build.gradle.kts:" .. M.detect_file_signature(vim.fs.joinpath(root, "build.gradle.kts")),
		}
		signature = table.concat(signatures, "|")
	end

	local tool_name = nil
	if filetype == "zig" then
		tool_name = "zig"
	elseif filetype == "go" then
		tool_name = "go"
	elseif filetype == "rust" then
		tool_name = "cargo"
	elseif filetype == "odin" then
		tool_name = "odin"
	end

	if tool_name then
		local executable_path = nil
		if type(vim.fn.exepath) == "function" then
			local resolved = vim.fn.exepath(tool_name)
			if type(resolved) == "string" and resolved ~= "" then
				executable_path = resolved
			end
		end
		if executable_path then
			signature = string.format(
				"tool:%s:%s:%s",
				tool_name,
				executable_path,
				state.get_file_mtime_key(executable_path) or "unknown"
			)
		else
			signature = "tool:" .. tool_name
		end
	end

	if is_detection_enabled("bazel_project") and M.supports_bazel_project_commands(filetype) then
		local bazel_root = M.resolve_bazel_root(filepath)
		if bazel_root then
			local bazel_signature = "bazel:" .. M.build_marker_signature(bazel_root, M.BAZEL_ROOT_MARKERS)
			if signature and signature ~= "" then
				return signature .. "|" .. bazel_signature
			end
			return bazel_signature
		end
	end

	return signature
end

return M
