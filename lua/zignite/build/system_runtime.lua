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
---@param lines string[]|nil
---@return table|nil
local function decode_system_backend_lines(lines)
	if type(lines) ~= "table" or #lines == 0 then
		return nil
	end
	local result = {}
	for _, raw_line in ipairs(lines or {}) do
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

---@param result table|nil
---@return table|nil
local function copy_system_result(result)
	if type(result) ~= "table" then
		return nil
	end
	if type(vim.deepcopy) == "function" then
		return vim.deepcopy(result)
	end
	local copied = {}
	for key, value in pairs(result) do
		copied[key] = value
	end
	return copied
end

---@param query string
---@param filepath string
---@param project_root string|nil
---@return string
local function system_cache_key(query, filepath, project_root)
	return table.concat({
		tostring(query or ""),
		tostring(project_root or ""),
		vim.fs.normalize(tostring(filepath or "")),
	}, "::")
end

---@param entry table|nil
---@return boolean
local function is_system_cache_stale(entry)
	if type(entry) ~= "table" then
		return true
	end
	local updated_at_ms = tonumber(entry.updated_at_ms)
	if not updated_at_ms then
		return true
	end
	return (state.now_ms() - updated_at_ms) >= state.SYSTEM_RUNTIME_DEFAULT_TTL_MS
end

---@param query string
---@param filepath string
---@param project_root string|nil
---@return table|nil
local function get_cached_system_result(query, filepath, project_root)
	local entry = state.get_bounded_cache_entry(
		state.system_runtime_cache,
		state.system_runtime_cache_order,
		system_cache_key(query, filepath, project_root)
	)
	if is_system_cache_stale(entry) then
		return nil
	end
	return copy_system_result(entry.result)
end

---@param query string
---@param filepath string
---@param project_root string|nil
---@param result table|nil
---@return nil
local function set_cached_system_result(query, filepath, project_root, result)
	local updated_at_ms = state.now_ms()
	local copied_result = copy_system_result(result)

	local function store(cache_path, cache_root)
		state.set_bounded_cache_entry(
			state.system_runtime_cache,
			state.system_runtime_cache_order,
			state.SYSTEM_RUNTIME_CACHE_MAX,
			system_cache_key(query, cache_path, cache_root),
			{
				result = copy_system_result(copied_result),
				updated_at_ms = updated_at_ms,
			}
		)
	end

	store(filepath, project_root)
	if type(copied_result) == "table" and type(copied_result.root) == "string" and copied_result.root ~= "" then
		store(copied_result.root, copied_result.root)
	end
end

---@param root string|nil
---@return table|nil
local function get_cached_c_family_result_for_root(root)
	if type(root) ~= "string" or root == "" then
		return nil
	end
	local backend = get_cached_system_result("c-family", root, root)
	if type(backend) ~= "table" or type(backend.system) ~= "string" or backend.system == "" then
		return nil
	end
	return backend
end

---@param filepath string
---@param project_root string|nil
---@return table|nil
local function get_cached_bazel_result(filepath, project_root)
	local backend = get_cached_system_result("bazel-root", filepath, project_root)
	if
		type(backend) == "table"
		and backend.system == "bazel"
		and type(backend.root) == "string"
		and backend.root ~= ""
	then
		return backend
	end
	local c_family = get_cached_system_result("c-family", filepath, project_root)
	if
		type(c_family) == "table"
		and c_family.system == "bazel"
		and type(c_family.root) == "string"
		and c_family.root ~= ""
	then
		return c_family
	end
	return nil
end

---@param query string
---@param root string|nil
---@param expected_system string|nil
---@return table|nil
local function get_cached_root_query_result(query, root, expected_system)
	if type(root) ~= "string" or root == "" then
		return nil
	end
	local backend = get_cached_system_result(query, root, root)
	if type(backend) ~= "table" then
		return nil
	end
	if type(expected_system) == "string" and expected_system ~= "" then
		if type(backend.system) ~= "string" or backend.system ~= expected_system then
			return nil
		end
	end
	if type(backend.root) ~= "string" or backend.root == "" then
		return nil
	end
	return backend
end

---@param filepath string
---@param query string
---@param project_root string|nil
---@param on_done fun(result: table|nil):nil
---@return boolean
local function prime_system_query_async(filepath, query, project_root, on_done)
	if type(filepath) ~= "string" or filepath == "" then
		return false
	end

	local cached = get_cached_system_result(query, filepath, project_root)
	if cached then
		vim.schedule(function()
			on_done(vim.deepcopy(cached))
		end)
		return true
	end

	local cache_key = system_cache_key(query, filepath, project_root)
	local inflight = state.system_runtime_inflight[cache_key]
	if inflight then
		inflight.callbacks[#inflight.callbacks + 1] = on_done
		return true
	end

	state.system_runtime_inflight[cache_key] = { callbacks = { on_done } }
	---@type string[]
	local extra_args = { "--query=" .. query }
	if type(project_root) == "string" and project_root ~= "" then
		extra_args[#extra_args + 1] = "--project-root=" .. project_root
	end

	local started = detect_backend.parse_project_lines_async("system", filepath, extra_args, function(lines)
		local result = decode_system_backend_lines(lines)
		set_cached_system_result(query, filepath, project_root, result)
		local pending = state.system_runtime_inflight[cache_key]
		state.system_runtime_inflight[cache_key] = nil
		for _, callback in ipairs((pending and pending.callbacks) or {}) do
			if type(callback) == "function" then
				pcall(callback, copy_system_result(result))
			end
		end
	end)

	if not started then
		state.system_runtime_inflight[cache_key] = nil
		return false
	end

	return true
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
local function resolve_bazel_root_local(filepath)
	local root = utils.get_project_root(filepath, config.options.project)
	if root and M.root_has_any_marker(root, M.BAZEL_ROOT_MARKERS) then
		return root
	end
	return M.find_root_for_files(filepath, M.BAZEL_ROOT_MARKERS, 12)
end

---@param filepath string
---@return string|nil, string|nil
local function resolve_jvm_root_local(filepath)
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

---@param filepath string
---@return string|nil, string|nil
local function detect_c_family_build_system_local(filepath)
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

---@param filepath string
---@return string|nil
function M.resolve_bazel_root(filepath)
	local project_root = utils.get_project_root(filepath, config.options.project)
	local backend = get_cached_bazel_result(filepath, project_root)
	if type(backend) == "table" and type(backend.root) == "string" then
		return backend.root
	end

	local root = resolve_bazel_root_local(filepath)
	if root and root ~= "" then
		local cached = get_cached_root_query_result("bazel-root", root, "bazel")
		if cached and cached.root then
			return cached.root
		end
		local c_family_cached = get_cached_root_query_result("c-family", root, "bazel")
		if c_family_cached and c_family_cached.root then
			return c_family_cached.root
		end
		return root
	end
	return nil
end

---@param filepath string
---@return string|nil, string|nil
function M.resolve_jvm_root(filepath)
	local project_root = utils.get_project_root(filepath, config.options.project)
	local backend = get_cached_system_result("jvm-root", filepath, project_root)
	if type(backend) == "table" and type(backend.root) == "string" then
		return backend.root, backend.system
	end

	local found_root, found_system = resolve_jvm_root_local(filepath)
	if found_root and found_system then
		local cached = get_cached_root_query_result("jvm-root", found_root, found_system)
		if cached then
			return cached.root, cached.system
		end
		return found_root, found_system
	end
	return found_root, found_system
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
	local backend = get_cached_c_family_result_for_root(root)
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
	local backend = get_cached_c_family_result_for_root(root)
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
	local project_root = utils.get_project_root(filepath, config.options.project)
	local backend = get_cached_system_result("c-family", filepath, project_root)
	if type(backend) == "table" and type(backend.system) == "string" and backend.system ~= "" then
		return backend.system, backend.root or M.resolve_project_root_for_detection(filepath)
	end

	local system, root = detect_c_family_build_system_local(filepath)
	if root and root ~= "" then
		local cached = get_cached_root_query_result("c-family", root)
		if cached and type(cached.system) == "string" and cached.system ~= "" then
			return cached.system, cached.root
		end
	end
	if system then
		return system, root
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
---@param on_done fun():nil
---@return boolean
function M.prime_system_detection_async(filetype, filepath, is_detection_enabled, on_done)
	local pending = 0
	local completed = false
	local started_any = false

	local function finish_one()
		if completed then
			return
		end
		pending = pending - 1
		if pending <= 0 then
			completed = true
			vim.schedule(on_done)
		end
	end

	local function start_query(query, project_root)
		pending = pending + 1
		local started = prime_system_query_async(filepath, query, project_root, function()
			finish_one()
		end)
		if not started then
			pending = pending - 1
		else
			started_any = true
		end
	end

	local project_root = utils.get_project_root(filepath, config.options.project)
	if filetype == "c" or filetype == "cpp" then
		start_query("c-family", project_root)
	end
	if
		(filetype == "java" or filetype == "kotlin")
		and is_detection_enabled("java_kotlin_project")
	then
		start_query("jvm-root", project_root)
	end
	if
		is_detection_enabled("bazel_project")
		and M.supports_bazel_project_commands(filetype)
	then
		local bazel_root = resolve_bazel_root_local(filepath)
		local should_check_bazel
		if filetype == "c" or filetype == "cpp" then
			should_check_bazel = false
		elseif filetype == "java" or filetype == "kotlin" then
			should_check_bazel = bazel_root ~= nil
		elseif filetype == "bazel" or filetype == "bzl" then
			should_check_bazel = true
		else
			should_check_bazel = bazel_root ~= nil
		end
		if should_check_bazel then
			start_query("bazel-root", project_root)
		end
	end

	return started_any
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
