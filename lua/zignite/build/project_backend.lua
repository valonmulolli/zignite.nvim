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

---@param names string[]|nil
---@param make_command fun(name: string): string
---@return table<string, string>
local function build_named_commands(names, make_command)
	---@type table<string, string>
	local commands = {}
	for _, raw_name in ipairs(names or {}) do
		local name = tostring(raw_name or "")
		if name ~= "" then
			commands[name] = make_command(name)
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

	local zig_names = detect_backend.parse_project_names_once("make", makefile_path)
	if type(zig_names) == "table" and #zig_names > 0 then
		local commands = build_named_commands(zig_names, function(name)
			return "make " .. name
		end)
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

	local zig_names = detect_backend.parse_project_names_once("package-json", package_json_path)
	if type(zig_names) == "table" and #zig_names > 0 then
		local commands = build_named_commands(zig_names, function(name)
			return utils.format_package_script_command(package_manager, name)
		end)
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

---@param commands table<string, string>
---@param bin_name string
---@return nil
local function add_cargo_bin_commands(commands, bin_name)
	local quoted_bin = utils.quote_cli_argument(bin_name)
	if quoted_bin == nil then
		return
	end
	commands["cargo-build-" .. bin_name] = "cargo build --bin " .. quoted_bin
	commands["cargo-run-" .. bin_name] = "cargo run --bin " .. quoted_bin
	commands["cargo-test-" .. bin_name] = "cargo test --bin " .. quoted_bin
end

---@param primary_bin string|nil
---@return table|nil
local function build_cargo_info(primary_bin)
	if type(primary_bin) ~= "string" or primary_bin == "" then
		return nil
	end
	local quoted_bin = utils.quote_cli_argument(primary_bin)
	if quoted_bin == nil then
		return nil
	end
	return {
		primary_bin = primary_bin,
		primary_run = "cargo run --bin " .. quoted_bin,
		primary_release_run = "cargo run --release --bin " .. quoted_bin,
		preferred_commands = {
			run = "cargo run --bin " .. quoted_bin,
			["release-run"] = "cargo run --release --bin " .. quoted_bin,
		},
	}
end

---@param zig_lines string[]
---@return table<string, string>, table|nil
local function parse_zig_cargo_targets(zig_lines)
	---@type table<string, string>
	local commands = {}
	local primary_bin = nil
	local primary_run = nil
	local primary_release_run = nil
	---@type string[]
	local bins = {}
	for _, raw_line in ipairs(zig_lines) do
		local line = tostring(raw_line or "")
		local kind, bin_name, matched_flag = line:match("^([^\t]+)\t([^\t]+)\t([01])$")
		if kind == "BIN" and bin_name and bin_name ~= "" then
			bins[#bins + 1] = bin_name
			if matched_flag == "1" and not primary_bin then
				primary_bin = bin_name
			end
		else
			local value_kind, value, extra = line:match("^([^\t]+)\t([^\t]*)\t?(.*)$")
			if value_kind == "PRIMARY_BIN" and value ~= "" then
				primary_bin = value
			elseif value_kind == "PRIMARY_RUN" and value ~= "" then
				primary_run = value
			elseif value_kind == "PRIMARY_RELEASE_RUN" and value ~= "" then
				primary_release_run = value
			elseif value_kind == "COMMAND" and value ~= "" and extra ~= "" then
				commands[value] = extra
			end
		end
	end
	if next(commands) == nil then
		for _, bin_name in ipairs(bins) do
			add_cargo_bin_commands(commands, bin_name)
		end
	end
	local info = build_cargo_info(primary_bin)
	if info then
		info.primary_run = primary_run or info.primary_run
		info.primary_release_run = primary_release_run or info.primary_release_run
	end
	for _, raw_line in ipairs(zig_lines) do
		local value_kind, value, extra = tostring(raw_line or ""):match("^([^\t]+)\t([^\t]*)\t?(.*)$")
		if value_kind == "PREFERRED" and value ~= "" and extra ~= "" and info then
			info.preferred_commands = info.preferred_commands or {}
			info.preferred_commands[value] = extra
		end
	end
	return commands, info
end

---@param filepath string
---@param root string
---@return table<string, string>, table|nil
local function fallback_cargo_commands(filepath, root)
	local relative_filepath = common.normalize_path_text(common.make_relative_to_root(root, filepath))
	local primary_bin = relative_filepath:match("^src/bin/([^/]+)%.rs$")
	if not primary_bin or primary_bin == "" then
		return {}, nil
	end

	---@type table<string, string>
	local commands = {}
	add_cargo_bin_commands(commands, primary_bin)
	return commands, build_cargo_info(primary_bin)
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

	local commands, info = fallback_cargo_commands(filepath, root)
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

---@param selector string|nil
---@param module_name string|nil
---@return table|nil
local function build_go_info(selector, module_name)
	if type(selector) ~= "string" or selector == "" then
		return nil
	end

	local quoted_selector = utils.quote_cli_argument(selector)
	if quoted_selector == nil then
		return nil
	end

	local info = {
		module_name = module_name,
		primary_selector = selector,
	}
	if selector ~= "." then
		info.primary_build = "go build " .. quoted_selector
		info.primary_run = "go run " .. quoted_selector
		info.primary_test = "go test " .. quoted_selector
		info.preferred_commands = {
			build = info.primary_build,
			run = info.primary_run,
			test = info.primary_test,
		}
	end
	return info
end

---@param commands table<string, string>
---@param info table
---@return nil
local function add_go_commands_from_info(commands, info)
	if type(info.primary_build) == "string" and info.primary_build ~= "" then
		commands["go-build-package"] = info.primary_build
	end
	if type(info.primary_run) == "string" and info.primary_run ~= "" then
		commands["go-run-package"] = info.primary_run
	end
	if type(info.primary_test) == "string" and info.primary_test ~= "" then
		commands["go-test-package"] = info.primary_test
	end
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

	if next(commands) == nil then
		add_go_commands_from_info(commands, info)
	end
	return commands, copy_go_info(info)
end

---@param raw_path string
---@return string
local function normalize_path(raw_path)
	return vim.fs.normalize(tostring(raw_path or "")):gsub("\\", "/")
end

---@param root string
---@param filepath string
---@return string
local function package_selector(root, filepath)
	local package_dir = normalize_path(vim.fn.fnamemodify(filepath, ":h"))
	local normalized_root = normalize_path(root)
	if package_dir == normalized_root then
		return "."
	end
	if package_dir:sub(1, #normalized_root + 1) == (normalized_root .. "/") then
		return "./" .. package_dir:sub(#normalized_root + 2)
	end
	return "."
end

---@param go_mod_path string
---@return string|nil
local function parse_go_module_name(go_mod_path)
	local zig_lines = detect_backend.parse_project_lines_once("go-mod", go_mod_path)
	if type(zig_lines) == "table" then
		for _, raw_line in ipairs(zig_lines) do
			local kind, name = tostring(raw_line or ""):match("^([^\t]+)\t([^\t]+)$")
			if kind == "MODULE" and type(name) == "string" and name ~= "" then
				return name
			end
		end
	end
	return nil
end

---@param go_work_path string
---@param filepath string
---@return string|nil
local function detect_workspace_use_root(go_work_path, filepath)
	local zig_lines = detect_backend.parse_project_lines_once("go-work", go_work_path, {
		"--match-path=" .. filepath,
	})
	if type(zig_lines) == "table" and #zig_lines > 0 then
		local first_root = nil
		for _, raw_line in ipairs(zig_lines) do
			local kind, use_path, matched_flag = tostring(raw_line or ""):match("^([^\t]+)\t([^\t]+)\t([01])$")
			if kind == "USE" and type(use_path) == "string" and use_path ~= "" then
				first_root = first_root or use_path
				if matched_flag == "1" then
					return normalize_path(use_path)
				end
			end
		end
		if first_root then
			return normalize_path(first_root)
		end
	end
	return nil
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

	local selector
	local module_name
	if vim.fn.filereadable(go_work_path) == 1 then
		local zig_lines = detect_backend.parse_project_lines_once("go", go_work_path, {
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

		local matched_root = detect_workspace_use_root(go_work_path, filepath)
		if matched_root and matched_root ~= "" then
			module_name = parse_go_module_name(vim.fs.joinpath(matched_root, "go.mod"))
		end
		selector = package_selector(root, filepath)
	elseif vim.fn.filereadable(go_mod_path) == 1 then
		local zig_lines = detect_backend.parse_project_lines_once("go", go_mod_path, {
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

		module_name = parse_go_module_name(go_mod_path)
		selector = package_selector(root, filepath)
	else
		state.set_bounded_cache_entry(
			state.go_project_cache,
			state.go_project_cache_order,
			state.GO_PROJECT_CACHE_MAX,
			cache_key,
			{ mtime_key = mtime_key, commands = {}, info = nil }
		)
		return {}, nil
	end

	if type(selector) ~= "string" or selector == "" then
		selector = "."
	end

	local quoted_selector = utils.quote_cli_argument(selector)
	if quoted_selector == nil then
		state.set_bounded_cache_entry(
			state.go_project_cache,
			state.go_project_cache_order,
			state.GO_PROJECT_CACHE_MAX,
			cache_key,
			{ mtime_key = mtime_key, commands = {}, info = nil }
		)
		return {}, nil
	end

	local commands = {
		["go-build-package"] = "go build " .. quoted_selector,
		["go-run-package"] = "go run " .. quoted_selector,
		["go-test-package"] = "go test " .. quoted_selector,
	}
	local info = build_go_info(selector, module_name)

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

	return commands, copy_go_info(info)
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

---@param commands table<string, string>
---@param preferred table<string, string>|nil
---@return table<string, string>
local function apply_preferred_aliases(commands, preferred)
	if type(preferred) ~= "table" then
		return commands
	end
	for _, key in ipairs({ "build", "run", "test" }) do
		local value = preferred[key]
		if type(value) == "string" and value ~= "" and commands[key] == nil then
			commands[key] = value
		end
	end
	return commands
end

---@param lines string[]|nil
---@return table<string, string>, table<string, string>
local function decode_backend_commands(lines)
	---@type table<string, string>
	local commands = {}
	---@type table<string, string>
	local preferred = {}
	for _, raw_line in ipairs(lines or {}) do
		local kind, name, command = tostring(raw_line or ""):match("^([^\t]+)\t([^\t]+)\t(.+)$")
		local valid_name = type(name) == "string" and name ~= ""
		local valid_command = type(command) == "string" and command ~= ""
		if kind == "COMMAND" and valid_name and valid_command then
			commands[name] = command
		elseif kind == "PREFERRED" and valid_name and valid_command then
			preferred[name] = command
		end
	end
	return commands, preferred
end

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
			local decoded, preferred = decode_backend_commands(zig_lines)
			return apply_preferred_aliases(decoded, preferred)
		end
		return apply_preferred_aliases(build_maven_commands(nil), {
			build = "mvn compile",
			test = "mvn test",
		})
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
				local decoded, preferred = decode_backend_commands(zig_lines)
				return apply_preferred_aliases(decoded, preferred)
			end
		end
		return apply_preferred_aliases(build_gradle_commands("./gradlew", nil), {
			build = "./gradlew build",
			test = "./gradlew test",
		})
	elseif vim.fn.filereadable(gradle_build) == 1 or vim.fn.filereadable(gradle_build_kts) == 1 then
		local gradle_file = vim.fn.filereadable(gradle_build_kts) == 1 and gradle_build_kts or gradle_build
		local zig_lines = detect_backend.parse_project_lines_once("gradle", gradle_file)
		if type(zig_lines) == "table" and #zig_lines > 0 then
			local decoded, preferred = decode_backend_commands(zig_lines)
			return apply_preferred_aliases(decoded, preferred)
		end
		return apply_preferred_aliases(build_gradle_commands("gradle", nil), {
			build = "gradle build",
			test = "gradle test",
		})
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
	---@type table<string, string>
	local preferred = {}
	for _, raw_line in ipairs(lines or {}) do
		local line = tostring(raw_line or "")
		if line ~= "" then
			local fields = split_tab_fields(line)
			if fields[1] == "COMMAND" and type(fields[2]) == "string" and type(fields[3]) == "string" then
				commands[fields[2]] = fields[3]
			elseif fields[1] == "PREFERRED" and type(fields[2]) == "string" and type(fields[3]) == "string" then
				preferred[fields[2]] = fields[3]
			end
		end
	end
	return commands, preferred
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
	---@type table<string, string>
	local preferred = {}

	for _, build_info in ipairs(build_files) do
		local zig_lines = detect_backend.parse_project_lines_once("bazel", build_info.build_file, {
			"--package-path=" .. build_info.package_path,
			"--match-path=" .. filepath,
		})
		if type(zig_lines) ~= "table" or #zig_lines == 0 then
			goto continue
		end

		local parsed_commands, parsed_preferred = parse_bazel_backend_command_lines(zig_lines)
		for name, command in pairs(parsed_commands) do
			if commands[name] == nil then
				commands[name] = command
			end
		end
		for key, value in pairs(parsed_preferred) do
			if preferred[key] == nil then
				preferred[key] = value
			end
		end

		::continue::
	end

	if preferred.build then
		commands["bazel-build"] = preferred.build
	end
	if preferred.run then
		commands["bazel-run"] = preferred.run
	end
	if preferred.test then
		commands["bazel-test"] = preferred.test
	end

	return apply_preferred_aliases(commands, preferred)
end

return M
