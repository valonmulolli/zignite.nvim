local config = require("zignite.config")
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

---@param value string
---@return string
local function shellescape_text(value)
	if vim.fn and type(vim.fn.shellescape) == "function" then
		return vim.fn.shellescape(value)
	end
	return tostring(value or "")
end

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

---@param target string
---@return string
local function build_discovered_run_suffix(target)
	local target_name = tostring(target or "")
	local target_exe = target_name .. ".exe"
	local candidate_paths = {
		"./build/" .. target_name,
		"./build/" .. target_exe,
		"./build/bin/" .. target_name,
		"./build/bin/" .. target_exe,
		"./build/Debug/" .. target_name,
		"./build/Debug/" .. target_exe,
		"./build/Release/" .. target_name,
		"./build/Release/" .. target_exe,
		"./build/RelWithDebInfo/" .. target_name,
		"./build/RelWithDebInfo/" .. target_exe,
		"./build/MinSizeRel/" .. target_name,
		"./build/MinSizeRel/" .. target_exe,
		"./build/bin/Debug/" .. target_name,
		"./build/bin/Debug/" .. target_exe,
		"./build/bin/Release/" .. target_name,
		"./build/bin/Release/" .. target_exe,
		"./build/bin/RelWithDebInfo/" .. target_name,
		"./build/bin/RelWithDebInfo/" .. target_exe,
		"./build/bin/MinSizeRel/" .. target_name,
		"./build/bin/MinSizeRel/" .. target_exe,
	}
	local escaped_candidates = {}
	for _, candidate in ipairs(candidate_paths) do
		escaped_candidates[#escaped_candidates + 1] = shellescape_text(candidate)
	end
	local find_clause = string.format(
		"find build -type f \\( -name %s -o -name %s \\) "
			.. "! -path '*/CMakeFiles/*' ! -path '*/meson-private/*' "
			.. "! -path '*/meson-logs/*' | head -n 1",
		shellescape_text(target_name),
		shellescape_text(target_exe)
	)
	return string.format(
		"for ZIGNITE_CANDIDATE in %s; do "
			.. "if [ -x \"$ZIGNITE_CANDIDATE\" ]; then \"$ZIGNITE_CANDIDATE\"; exit $?; fi; "
			.. "done; "
			.. "ZIGNITE_BIN=$(%s) && "
			.. "if [ -n \"$ZIGNITE_BIN\" ] && [ -x \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; "
			.. "elif [ -n \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; "
			.. "else %s; fi",
		table.concat(escaped_candidates, " "),
		find_clause,
		shellescape_text("./build/" .. target_name)
	)
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
	return build_dir_has_file(root, "CMakeCache.txt")
end

---@param root string|nil
---@return boolean
function M.has_meson_build_tree(root)
	if build_dir_has_file(root, "build.ninja") then
		return true
	end
	return build_dir_has_file(root, vim.fs.joinpath("meson-private", "coredata.dat"))
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
---@param target string
---@return string
function M.cmake_run_command(root, target)
	return M.cmake_build_command(root, target) .. " && " .. build_discovered_run_suffix(target)
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
---@param target string
---@return string
function M.meson_run_command(root, target)
	return M.meson_build_command(root, target) .. " && " .. build_discovered_run_suffix(target)
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
