local common = require("zignite.build.common")
local config = require("zignite.config")
local detect_backend = require("zignite.build.detect.backend")
local state = require("zignite.build.state")
local systems = require("zignite.build.systems")
local utils = require("zignite.utils")

---@type table
local M = {}

---@param filepath string
---@return string
local function resolve_project_root(filepath)
	local root = utils.get_project_root(filepath, config.options.project)
	if root and root ~= "" then
		return root
	end
	return vim.fn.fnamemodify(filepath, ":h")
end

---@param project_file string
---@param cache table<string, table>
---@param order string[]
---@return table|nil
local function get_cached_entry(project_file, cache, order)
	local mtime_key = state.get_file_mtime_key(project_file)
	local cached = state.get_bounded_cache_entry(cache, order, project_file)
	if cached and cached.mtime_key == mtime_key then
		return cached
	end
	return nil
end

---@param project_file string
---@param cache table<string, table>
---@param order string[]
---@param max_entries integer
---@param entry table
---@return nil
local function set_cached_entry(project_file, cache, order, max_entries, entry)
	state.set_bounded_cache_entry(cache, order, max_entries, project_file, entry)
end

---@param lines string[]|nil
---@return table<string, string>
local function decode_backend_commands(lines)
	---@type table<string, string>
	local commands = {}
	for _, raw_line in ipairs(lines or {}) do
		local kind, name, command = tostring(raw_line or ""):match("^([^\t]+)\t([^\t]+)\t(.+)$")
		local valid_name = type(name) == "string" and name ~= ""
		local valid_command = type(command) == "string" and command ~= ""
		if kind == "COMMAND" and valid_name and valid_command then
			commands[name] = command
		end
	end
	return commands
end

---@param filepath string
---@return table<string, string>
function M.detect_makefile_targets(filepath)
	if not filepath or filepath == "" then
		return {}
	end
	if type(vim.fn.filereadable) ~= "function" then
		return {}
	end

	local root = resolve_project_root(filepath)
	local makefile_path = vim.fs.joinpath(root, "Makefile")
	if vim.fn.filereadable(makefile_path) ~= 1 then
		return {}
	end

	local cached = get_cached_entry(makefile_path, state.make_target_cache, state.make_target_cache_order)
	if cached then
		return state.copy_string_map(cached.commands)
	end

	local zig_lines = detect_backend.parse_project_lines_once("make", makefile_path)
	if type(zig_lines) == "table" and #zig_lines > 0 then
		local commands = decode_backend_commands(zig_lines)
		set_cached_entry(makefile_path, state.make_target_cache, state.make_target_cache_order, state.MAKE_TARGET_CACHE_MAX, {
			mtime_key = state.get_file_mtime_key(makefile_path),
			commands = state.copy_string_map(commands),
		})
		return commands
	end

	set_cached_entry(makefile_path, state.make_target_cache, state.make_target_cache_order, state.MAKE_TARGET_CACHE_MAX, {
		mtime_key = state.get_file_mtime_key(makefile_path),
		commands = {},
	})
	return {}
end

---@param filepath string
---@return table<string, string>
function M.detect_package_scripts(filepath)
	if not filepath or filepath == "" then
		return {}
	end
	if type(vim.fn.filereadable) ~= "function" then
		return {}
	end

	local root = resolve_project_root(filepath)
	local package_json_path = vim.fs.joinpath(root, "package.json")
	if vim.fn.filereadable(package_json_path) ~= 1 then
		return {}
	end

	local package_manager = utils.detect_node_package_manager_root(root)
	local cached = get_cached_entry(package_json_path, state.package_script_cache, state.package_script_cache_order)
	if cached and cached.package_manager == package_manager then
		return state.copy_string_map(cached.commands)
	end

	local zig_lines = detect_backend.parse_project_lines_once("package-json", package_json_path, {
		"--package-manager=" .. package_manager,
	})
	if type(zig_lines) == "table" and #zig_lines > 0 then
		local commands = decode_backend_commands(zig_lines)
		set_cached_entry(
			package_json_path,
			state.package_script_cache,
			state.package_script_cache_order,
			state.PACKAGE_SCRIPT_CACHE_MAX,
			{
				mtime_key = state.get_file_mtime_key(package_json_path),
				package_manager = package_manager,
				commands = state.copy_string_map(commands),
			}
		)
		return commands
	end

	set_cached_entry(
		package_json_path,
		state.package_script_cache,
		state.package_script_cache_order,
		state.PACKAGE_SCRIPT_CACHE_MAX,
		{
			mtime_key = state.get_file_mtime_key(package_json_path),
			package_manager = package_manager,
			commands = {},
		}
	)
	return {}
end

---@param commands table<string, string>|nil
---@return table<string, string>|nil
local function copy_preferred_commands(commands)
	if type(commands) ~= "table" then
		return nil
	end
	local copied = state.copy_string_map(commands)
	return next(copied) ~= nil and copied or nil
end

---@param info table|nil
---@return table|nil
local function copy_cargo_info(info)
	if type(info) ~= "table" then
		return nil
	end
	return {
		primary_bin = info.primary_bin,
		primary_run = info.primary_run,
		primary_release_run = info.primary_release_run,
		preferred_commands = copy_preferred_commands(info.preferred_commands),
	}
end

---@param zig_lines string[]
---@return table<string, string>, table|nil
local function parse_zig_cargo_targets(zig_lines)
	---@type table<string, string>
	local commands = {}
	---@type table
	local info = {}
	for _, raw_line in ipairs(zig_lines) do
		local line = tostring(raw_line or "")
		local kind, bin_name, matched_flag = line:match("^([^\t]+)\t([^\t]+)\t([01])$")
		if kind == "BIN" and bin_name and bin_name ~= "" then
			if matched_flag == "1" and not info.primary_bin then
				info.primary_bin = bin_name
			end
		else
			local value_kind, value, extra = line:match("^([^\t]+)\t([^\t]*)\t?(.*)$")
			if value_kind == "PRIMARY_BIN" and value ~= "" then
				info.primary_bin = value
			elseif value_kind == "PRIMARY_RUN" and value ~= "" then
				info.primary_run = value
			elseif value_kind == "PRIMARY_RELEASE_RUN" and value ~= "" then
				info.primary_release_run = value
			elseif value_kind == "COMMAND" and value ~= "" and extra ~= "" then
				commands[value] = extra
			elseif value_kind == "PREFERRED" and value ~= "" and extra ~= "" then
				info.preferred_commands = info.preferred_commands or {}
				info.preferred_commands[value] = extra
			end
		end
	end
	if next(info) == nil then
		info = nil
	end
	return commands, copy_cargo_info(info)
end

---@param filepath string
---@return table<string, string>, table|nil
function M.detect_cargo_project_commands(filepath)
	if not filepath or filepath == "" or type(vim.fn.filereadable) ~= "function" then
		return {}, nil
	end

	local root = utils.get_project_root(filepath, config.options.project)
	if not root or root == "" then
		return {}, nil
	end

	local cargo_toml_path = vim.fs.joinpath(root, "Cargo.toml")
	if vim.fn.filereadable(cargo_toml_path) ~= 1 then
		return {}, nil
	end

	local mtime_key = state.get_file_mtime_key(cargo_toml_path) or "missing"
	local cached = state.get_bounded_cache_entry(
		state.cargo_target_cache,
		state.cargo_target_cache_order,
		cargo_toml_path
	)
	if cached and cached.mtime_key == mtime_key and cached.match_path == filepath then
		return state.copy_string_map(cached.commands), copy_cargo_info(cached.info)
	end

	local zig_lines = detect_backend.parse_project_lines_once("cargo", cargo_toml_path, {
		"--match-path=" .. filepath,
	})
	if type(zig_lines) == "table" and #zig_lines > 0 then
		local commands, info = parse_zig_cargo_targets(zig_lines)
		state.set_bounded_cache_entry(
			state.cargo_target_cache,
			state.cargo_target_cache_order,
			state.CARGO_TARGET_CACHE_MAX,
			cargo_toml_path,
			{
				mtime_key = mtime_key,
				match_path = filepath,
				commands = state.copy_string_map(commands),
				info = copy_cargo_info(info),
			}
		)
		return commands, copy_cargo_info(info)
	end

	state.set_bounded_cache_entry(
		state.cargo_target_cache,
		state.cargo_target_cache_order,
		state.CARGO_TARGET_CACHE_MAX,
		cargo_toml_path,
		{
			mtime_key = mtime_key,
			match_path = filepath,
			commands = {},
			info = nil,
		}
	)
	return {}, nil
end

---@param info table|nil
---@return table|nil
local function copy_go_info(info)
	if type(info) ~= "table" then
		return nil
	end
	return {
		module_name = info.module_name,
		primary_selector = info.primary_selector,
		primary_build = info.primary_build,
		primary_run = info.primary_run,
		primary_test = info.primary_test,
		preferred_commands = copy_preferred_commands(info.preferred_commands),
	}
end

---@param zig_lines string[]
---@return table<string, string>, table|nil
local function parse_zig_go_info(zig_lines)
	---@type table
	local info = {}
	---@type table<string, string>
	local commands = {}
	for _, raw_line in ipairs(zig_lines) do
		local line = tostring(raw_line or "")
		local kind, value, extra = line:match("^([^\t]+)\t([^\t]*)\t?(.*)$")
		if kind == "MODULE" and value ~= "" then
			info.module_name = value
		elseif kind == "PRIMARY_SELECTOR" and value ~= "" then
			info.primary_selector = value
		elseif kind == "PRIMARY_BUILD" and value ~= "" then
			info.primary_build = value
		elseif kind == "PRIMARY_RUN" and value ~= "" then
			info.primary_run = value
		elseif kind == "PRIMARY_TEST" and value ~= "" then
			info.primary_test = value
		elseif kind == "COMMAND" and value ~= "" and extra ~= "" then
			commands[value] = extra
		elseif kind == "PREFERRED" and value ~= "" and extra ~= "" then
			info.preferred_commands = info.preferred_commands or {}
			info.preferred_commands[value] = extra
		end
	end

	if next(info) == nil then
		return {}, nil
	end

	return commands, copy_go_info(info)
end

---@param raw_path string
---@return string
local function normalize_path(raw_path)
	return vim.fs.normalize(tostring(raw_path or "")):gsub("\\", "/")
end

---@param filepath string
---@return table<string, string>, table|nil
function M.detect_go_project_commands(filepath)
	if not filepath or filepath == "" or type(vim.fn.filereadable) ~= "function" then
		return {}, nil
	end

	local root = utils.get_project_root(filepath, config.options.project)
	if not root or root == "" then
		return {}, nil
	end
	root = normalize_path(root)

	local go_work_path = vim.fs.joinpath(root, "go.work")
	local go_mod_path = vim.fs.joinpath(root, "go.mod")
	local cache_key = root .. "::" .. normalize_path(filepath)
	local mtime_key = string.format(
		"%s|%s",
		state.get_file_mtime_key(go_work_path) or "missing",
		state.get_file_mtime_key(go_mod_path) or "missing"
	)
	local cached = state.get_bounded_cache_entry(
		state.go_project_cache,
		state.go_project_cache_order,
		cache_key
	)
	if cached and cached.mtime_key == mtime_key then
		return state.copy_string_map(cached.commands), copy_go_info(cached.info)
	end

	local project_path = vim.fn.filereadable(go_work_path) == 1 and go_work_path
		or (vim.fn.filereadable(go_mod_path) == 1 and go_mod_path or nil)
	if not project_path then
		state.set_bounded_cache_entry(
			state.go_project_cache,
			state.go_project_cache_order,
			state.GO_PROJECT_CACHE_MAX,
			cache_key,
			{ mtime_key = mtime_key, commands = {}, info = nil }
		)
		return {}, nil
	end

	local zig_lines = detect_backend.parse_project_lines_once("go", project_path, {
		"--match-path=" .. filepath,
	})
	if type(zig_lines) == "table" and #zig_lines > 0 then
		local commands, info = parse_zig_go_info(zig_lines)
		state.set_bounded_cache_entry(
			state.go_project_cache,
			state.go_project_cache_order,
			state.GO_PROJECT_CACHE_MAX,
			cache_key,
			{
				mtime_key = mtime_key,
				commands = state.copy_string_map(commands),
				info = copy_go_info(info),
			}
		)
		return state.copy_string_map(commands), copy_go_info(info)
	end

	state.set_bounded_cache_entry(
		state.go_project_cache,
		state.go_project_cache_order,
		state.GO_PROJECT_CACHE_MAX,
		cache_key,
		{
			mtime_key = mtime_key,
			commands = {},
			info = nil,
		}
	)

	return {}, nil
end

---@param run_command string|nil
---@return table<string, string>
local function build_maven_commands(run_command)
	---@type table<string, string>
	local commands = {
		["mvn-build"] = "mvn compile",
		["mvn-test"] = "mvn test",
		["mvn-package"] = "mvn package",
	}
	if type(run_command) == "string" and run_command ~= "" then
		commands["mvn-run"] = run_command
	end
	return commands
end

---@param prefix string
---@param run_task string|nil
---@return table<string, string>
local function build_gradle_commands(prefix, run_task)
	---@type table<string, string>
	local commands = {
		["gradle-build"] = prefix .. " build",
		["gradle-test"] = prefix .. " test",
		["gradle-clean"] = prefix .. " clean",
	}
	if type(run_task) == "string" and run_task ~= "" then
		commands["gradle-run"] = prefix .. " " .. run_task
	end
	return commands
end

---@param lines string[]|nil
---@return table<string, string>
---@param filepath string
---@return table<string, string>
function M.detect_java_like_project_commands(filepath)
	if not filepath or filepath == "" or type(vim.fn.filereadable) ~= "function" then
		return {}
	end

	local root, backend_system = systems.resolve_jvm_root(filepath)
	root = root or vim.fn.fnamemodify(filepath, ":h")

	---@type table<string, string>
	local commands = {}
	local pom_xml = vim.fs.joinpath(root, "pom.xml")
	local gradle_wrapper = vim.fs.joinpath(root, "gradlew")
	local gradle_build = vim.fs.joinpath(root, "build.gradle")
	local gradle_build_kts = vim.fs.joinpath(root, "build.gradle.kts")

	if backend_system == "maven" or vim.fn.filereadable(pom_xml) == 1 then
		local zig_lines = detect_backend.parse_project_lines_once("maven", pom_xml)
		if type(zig_lines) == "table" and #zig_lines > 0 then
			local decoded = decode_backend_commands(zig_lines)
			return decoded
		end
		local fallback = build_maven_commands(nil)
		fallback.build = fallback.build or "mvn compile"
		fallback.test = fallback.test or "mvn test"
		return fallback
	end
	if backend_system == "gradle"
		and vim.fn.filereadable(gradle_wrapper) ~= 1
		and vim.fn.filereadable(gradle_build) ~= 1
		and vim.fn.filereadable(gradle_build_kts) ~= 1
	then
		return commands
	end
	if vim.fn.filereadable(gradle_wrapper) == 1 or backend_system == "gradle" then
		local gradle_file = nil
		if vim.fn.filereadable(gradle_build_kts) == 1 then
			gradle_file = gradle_build_kts
		elseif vim.fn.filereadable(gradle_build) == 1 then
			gradle_file = gradle_build
		end
		if gradle_file then
			local zig_lines = detect_backend.parse_project_lines_once("gradle", gradle_file)
			if type(zig_lines) == "table" and #zig_lines > 0 then
				local decoded = decode_backend_commands(zig_lines)
				return decoded
			end
		end
		local fallback = build_gradle_commands("./gradlew", nil)
		fallback.build = fallback.build or "./gradlew build"
		fallback.test = fallback.test or "./gradlew test"
		return fallback
	elseif vim.fn.filereadable(gradle_build) == 1 or vim.fn.filereadable(gradle_build_kts) == 1 then
		local gradle_file = vim.fn.filereadable(gradle_build_kts) == 1 and gradle_build_kts or gradle_build
		local zig_lines = detect_backend.parse_project_lines_once("gradle", gradle_file)
		if type(zig_lines) == "table" and #zig_lines > 0 then
			local decoded = decode_backend_commands(zig_lines)
			return decoded
		end
		local fallback = build_gradle_commands("gradle", nil)
		fallback.build = fallback.build or "gradle build"
		fallback.test = fallback.test or "gradle test"
		return fallback
	end
	return commands
end

---@param build_dir string
---@param workspace_root string
---@return string
local function bazel_package_path_from_dir(build_dir, workspace_root)
	local normalized_dir = common.normalize_path_text(build_dir)
	local normalized_root = common.normalize_path_text(workspace_root)
	if normalized_dir == normalized_root then
		return ""
	end
	if normalized_dir:sub(1, #normalized_root + 1) == (normalized_root .. "/") then
		return normalized_dir:sub(#normalized_root + 2)
	end
	return ""
end

---@param start_path string
---@param workspace_root string
---@return table[]
local function find_bazel_build_files_for_path(start_path, workspace_root)
	---@type table[]
	local build_files = {}
	local dir = vim.fn.fnamemodify(start_path, ":h")
	local normalized_root = common.normalize_path_text(workspace_root)

	while type(dir) == "string" and dir ~= "" do
		for _, file_name in ipairs({ "BUILD.bazel", "BUILD" }) do
			local candidate = vim.fs.joinpath(dir, file_name)
			if vim.fn.filereadable(candidate) == 1 then
				build_files[#build_files + 1] = {
					build_file = candidate,
					package_dir = dir,
					package_path = bazel_package_path_from_dir(dir, workspace_root),
				}
				break
			end
		end

		local normalized_dir = common.normalize_path_text(dir)
		if normalized_dir == normalized_root then
			break
		end

		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then
			break
		end
		dir = parent
	end

	return build_files
end

---@param line string
---@return string[]
local function split_tab_fields(line)
	---@type string[]
	local fields = {}
	local start_idx = 1
	while true do
		local tab_idx = line:find("\t", start_idx, true)
		if not tab_idx then
			fields[#fields + 1] = line:sub(start_idx)
			break
		end
		fields[#fields + 1] = line:sub(start_idx, tab_idx - 1)
		start_idx = tab_idx + 1
	end
	return fields
end

---@param lines string[]
---@return table<string, string>, table<string, string>
local function parse_bazel_backend_command_lines(lines)
	---@type table<string, string>
	local commands = {}
	for _, raw_line in ipairs(lines or {}) do
		local line = tostring(raw_line or "")
		if line ~= "" then
			local fields = split_tab_fields(line)
			if fields[1] == "COMMAND" and type(fields[2]) == "string" and type(fields[3]) == "string" then
				commands[fields[2]] = fields[3]
			end
		end
	end
	return commands
end

---@param filepath string
---@return table<string, string>
function M.detect_bazel_project_commands(filepath)
	if not filepath or filepath == "" or type(vim.fn.filereadable) ~= "function" then
		return {}
	end

	local root = systems.resolve_bazel_root(filepath)
	if not root then
		return {}
	end

	---@type table<string, string>
	local commands = {
		["bazel-build"] = "bazel build $zignite_args",
		["bazel-run"] = "bazel run $zignite_args",
		["bazel-test"] = "bazel test $zignite_args",
		["bazel-query"] = "bazel query $zignite_args",
		["bazel-clean"] = "bazel clean",
		["bazel-build-all"] = "bazel build //...",
		["bazel-test-all"] = "bazel test //...",
	}

	local build_files = find_bazel_build_files_for_path(filepath, root)
	if #build_files == 0 then
		return commands
	end
	for _, build_info in ipairs(build_files) do
		local zig_lines = detect_backend.parse_project_lines_once("bazel", build_info.build_file, {
			"--package-path=" .. build_info.package_path,
			"--match-path=" .. filepath,
		})
		if type(zig_lines) ~= "table" or #zig_lines == 0 then
			goto continue
		end

		local parsed_commands = parse_bazel_backend_command_lines(zig_lines)
		for name, command in pairs(parsed_commands) do
			commands[name] = command
		end

		::continue::
	end
	return commands
end

return M
