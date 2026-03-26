local config = require("zignite.config")
local tooling_transport = require("zignite.build.tooling.transport")
local cache_state = require("zignite.build.cache_state")
local systems = require("zignite.build.system_runtime")
local project_utils = require("zignite.utils.project")

---@type table
local M = {}
local PARSER_BACKED_BUILD_SOURCES
local decode_backend_commands

---@param filepath string|nil
---@return boolean
local function can_query_backend(filepath)
	return type(filepath) == "string" and filepath ~= "" and type(vim.fn.filereadable) == "function"
end

---@param raw_path string|nil
---@return string
local function normalize_path(raw_path)
	return vim.fs.normalize(tostring(raw_path or "")):gsub("\\", "/")
end

---@param target table<string, string>
---@param source table<string, string>|nil
---@return nil
local function extend_command_map(target, source)
	for key, value in pairs(source or {}) do
		if type(key) == "string" and type(value) == "string" then
			target[key] = value
		end
	end
end

---@param kind string
---@param filepath string
---@param extra_args string[]|nil
---@return table<string, string>
local function parse_backend_command_map(kind, filepath, extra_args)
	local lines = tooling_transport.parse_project_lines_once(kind, filepath, extra_args)
	if type(lines) == "table" and #lines > 0 then
		return decode_backend_commands(lines)
	end
	return {}
end

---@param cache table
---@param order string[]
---@param max_entries integer
---@param key string
---@param entry table
---@return nil
local function store_command_cache_entry(cache, order, max_entries, key, entry)
	local stored = {}
	for field, value in pairs(entry or {}) do
		if field == "commands" then
			stored.commands = cache_state.copy_string_map(value or {})
		else
			stored[field] = value
		end
	end
	cache_state.set_bounded_cache_entry(cache, order, max_entries, key, stored)
end

---@param query string
---@param filepath string
---@return table<string, string>|nil
local function get_warmed_system_commands(query, filepath)
	local project_root = project_utils.get_project_root(filepath, config.options.project)
	local warmed_system = systems.get_cached_system_query_result(query, filepath, project_root)
	if type(warmed_system) == "table" and type(warmed_system.commands) == "table" then
		local commands = cache_state.copy_string_map(warmed_system.commands)
		if next(commands) ~= nil then
			return commands
		end
	end
	return nil
end

---@param query string
---@param filepath string
---@param fallback fun(string): table<string, string>
---@return table<string, string>
local function detect_warmed_or_backend_commands(query, filepath, fallback)
	if not can_query_backend(filepath) then
		return {}
	end

	local commands = get_warmed_system_commands(query, filepath)
	if commands then
		return commands
	end

	return fallback(filepath)
end

---@param kind string
---@param filepath string
---@param extra_args string[]|nil
---@return table<string, string>
local function detect_simple_backend_commands(kind, filepath, extra_args)
	if not can_query_backend(filepath) then
		return {}
	end
	return parse_backend_command_map(kind, filepath, extra_args)
end

---@param opts table
---@return table<string, string>, table|nil
local function detect_cached_backend_commands(opts)
	if not can_query_backend(opts.filepath) then
		return {}, nil
	end

	local cached = cache_state.get_bounded_cache_entry(opts.cache, opts.order, opts.cache_key)
	if cached and opts.is_fresh(cached) then
		return cache_state.copy_string_map(cached.commands), nil
	end

	local commands = parse_backend_command_map(opts.kind, opts.filepath, opts.extra_args)
	local entry = {
		mtime_key = opts.mtime_key,
		commands = commands,
		info = nil,
	}
	for field, value in pairs(opts.extra_entry or {}) do
		entry[field] = value
	end
	store_command_cache_entry(opts.cache, opts.order, opts.max_entries, opts.cache_key, entry)
	if next(commands) ~= nil then
		return cache_state.copy_string_map(commands), nil
	end
	return {}, nil
end

---@param lines string[]|nil
---@return table<string, string>
decode_backend_commands = function(lines)
	---@type table<string, string>
	local commands = {}
	for _, raw_line in ipairs(lines or {}) do
		local kind, name, command = tostring(raw_line or ""):match("^([^\t]+)\t([^\t]+)\t(.+)$")
		if kind == "COMMAND" and type(name) == "string" and name ~= "" and type(command) == "string" and command ~= "" then
			commands[name] = command
		end
	end
	return commands
end

---@param lines string[]|nil
---@return table
local function decode_backend_project_result(lines)
	local result = {
		commands = decode_backend_commands(lines),
	}
	for _, raw_line in ipairs(lines or {}) do
		local kind, value = tostring(raw_line or ""):match("^([^\t]+)\t(.+)$")
		if kind == "SYSTEM" and type(value) == "string" and value ~= "" then
			result.system = value
		elseif kind == "ROOT" and type(value) == "string" and value ~= "" then
			result.root = value
		elseif kind == "BUILD_READY" then
			result.build_ready = value == "1"
		end
	end
	return result
end

---@param filepath string
---@return table|nil, string
local function get_c_family_cached_entry(filepath)
	local cache_key = normalize_path(filepath)
	local cached = cache_state.get_bounded_cache_entry(
		cache_state.c_family_project_cache,
		cache_state.c_family_project_cache_order,
		cache_key
	)
	return cached, cache_key
end

---@param cache_key string
---@param system string|nil
---@param root string
---@param commands table<string, string>
---@return nil
local function store_c_family_cached_entry(cache_key, system, root, commands)
	cache_state.set_bounded_cache_entry(
		cache_state.c_family_project_cache,
		cache_state.c_family_project_cache_order,
		cache_state.C_FAMILY_PROJECT_CACHE_MAX,
		cache_key,
		{
			system = system,
			root = root,
			detect_flag = system == "make" and "c_cpp_make" or nil,
			commands = cache_state.copy_string_map(commands),
		}
	)
end

---@param filepath string
---@return table<string, string>
function M.detect_package_scripts(filepath)
	local commands = detect_cached_backend_commands({
		kind = "package-json-auto",
		filepath = filepath,
		cache = cache_state.package_script_cache,
		order = cache_state.package_script_cache_order,
		max_entries = cache_state.PACKAGE_SCRIPT_CACHE_MAX,
		cache_key = normalize_path(filepath),
		mtime_key = "auto",
		is_fresh = function(_)
			return true
		end,
	})
	if next(commands) ~= nil then
		return commands
	end
	return {}
end

---@param filepath string
---@return table<string, string>
function M.detect_node_project_commands(filepath)
	return detect_simple_backend_commands("system", filepath, { "--query=node-root" })
end

---@param filepath string
---@return table<string, string>
function M.detect_node_project_commands_cached(filepath)
	return detect_warmed_or_backend_commands("node-root", filepath, M.detect_node_project_commands)
end

---@param filepath string
---@return table<string, string>, table|nil
function M.detect_cargo_project_commands(filepath)
	if not can_query_backend(filepath) then
		return {}, nil
	end
	local root = project_utils.get_project_root(filepath, config.options.project)
	if type(root) ~= "string" or root == "" then
		return {}, nil
	end
	local cargo_toml_path = vim.fs.joinpath(root, "Cargo.toml")
	if vim.fn.filereadable(cargo_toml_path) ~= 1 then
		return {}, nil
	end
	local mtime_key = cache_state.get_file_mtime_key(cargo_toml_path) or "missing"
	return detect_cached_backend_commands({
		kind = "cargo-auto",
		filepath = filepath,
		cache = cache_state.cargo_target_cache,
		order = cache_state.cargo_target_cache_order,
		max_entries = cache_state.CARGO_TARGET_CACHE_MAX,
		cache_key = cargo_toml_path,
		mtime_key = mtime_key,
		is_fresh = function(cached)
			return cached.mtime_key == mtime_key and cached.match_path == filepath
		end,
		extra_entry = {
			match_path = filepath,
		},
	})
end

---@param filepath string
---@return table<string, string>, table|nil
function M.detect_go_project_commands(filepath)
	if not can_query_backend(filepath) then
		return {}, nil
	end

	local root = project_utils.get_project_root(filepath, config.options.project)
	if type(root) ~= "string" or root == "" then
		return {}, nil
	end
	local normalized_filepath = normalize_path(filepath)
	local cache_key = normalize_path(root) .. "::" .. normalized_filepath
	root = normalize_path(root)
	local go_work_path = vim.fs.joinpath(root, "go.work")
	local go_mod_path = vim.fs.joinpath(root, "go.mod")
	local mtime_key = string.format(
		"%s|%s",
		cache_state.get_file_mtime_key(go_work_path) or "missing",
		cache_state.get_file_mtime_key(go_mod_path) or "missing"
	)
	return detect_cached_backend_commands({
		kind = "go-auto",
		filepath = filepath,
		cache = cache_state.go_project_cache,
		order = cache_state.go_project_cache_order,
		max_entries = cache_state.GO_PROJECT_CACHE_MAX,
		cache_key = cache_key,
		mtime_key = mtime_key,
		is_fresh = function(cached)
			return cached.mtime_key == mtime_key
		end,
	})
end

---@param filepath string
---@return table<string, string>
function M.detect_java_like_project_commands(filepath)
	return detect_simple_backend_commands("jvm-auto", filepath)
end

---@param filepath string
---@return table<string, string>
function M.detect_python_project_commands(filepath)
	return detect_simple_backend_commands("python-auto", filepath)
end

---@param filepath string
---@return table<string, string>
function M.detect_python_project_commands_cached(filepath)
	return detect_warmed_or_backend_commands("python-root", filepath, M.detect_python_project_commands)
end

---@param filepath string
---@return table<string, string>
function M.detect_java_like_project_commands_cached(filepath)
	return detect_warmed_or_backend_commands("jvm-root", filepath, M.detect_java_like_project_commands)
end

---@param filepath string
---@return table<string, string>
function M.detect_bazel_project_commands(filepath)
	if not can_query_backend(filepath) then
		return {}
	end

	if not systems.resolve_bazel_root(filepath) then
		return {}
	end

	return parse_backend_command_map("bazel-auto", filepath)
end

---@param filepath string
---@return table<string, string>
function M.detect_bazel_project_commands_cached(filepath)
	return detect_warmed_or_backend_commands("bazel-root", filepath, M.detect_bazel_project_commands)
end

PARSER_BACKED_BUILD_SOURCES = {
	go = {
		default_key = "go",
		detect = M.detect_go_project_commands,
	},
	rust = {
		default_key = "rust",
		detect = M.detect_cargo_project_commands,
		detect_flag = "rust",
	},
}

---@param filetype string
---@param filepath string
---@return table|nil
function M.detect_parser_backed_build_result(filetype, filepath)
	local source = PARSER_BACKED_BUILD_SOURCES[filetype]
	if not source then
		return nil
	end

	local commands, info = source.detect(filepath)
	return {
		filetype = filetype,
		default_key = source.default_key or filetype,
		detect_flag = source.detect_flag,
		commands = commands or {},
		info = info,
	}
end

---@param filepath string
---@return table|nil
function M.detect_c_family_build_result(filepath)
	if not filepath or filepath == "" then
		return nil
	end
	local local_system, local_root = systems.detect_c_family_build_system(filepath)
	if not local_system then
		return nil
	end
	if local_system == "bazel" then
		return {
			system = local_system,
			root = local_root,
			commands = {},
			info = nil,
		}
	end

	local root = local_root or systems.resolve_project_root_for_detection(filepath)
	local cached, cache_key = get_c_family_cached_entry(filepath)
	if cached then
		if type(cached.system) ~= "string" or cached.system == "" then
			return nil
		end
		return {
			system = cached.system,
			root = cached.root,
			detect_flag = cached.detect_flag,
			commands = cache_state.copy_string_map(cached.commands),
			info = nil,
		}
	end

	local zig_lines = tooling_transport.parse_project_lines_once("c-family-auto", filepath, {
		"--project-root=" .. root,
	})
	local decoded = decode_backend_project_result(zig_lines)
	local system = decoded.system
	if type(system) ~= "string" or system == "" then
		system = local_system
		decoded.system = local_system
		decoded.root = local_root or decoded.root or root
	end
	local detect_flag = system == "make" and "c_cpp_make" or nil
	store_c_family_cached_entry(cache_key, system, decoded.root or root, decoded.commands)
	if type(system) ~= "string" or system == "" then
		return nil
	end
	return {
		system = system,
		root = decoded.root or root,
		detect_flag = detect_flag,
		commands = decoded.commands or {},
		info = nil,
	}
end

---@param filepath string
---@return table|nil
function M.detect_c_family_build_result_cached(filepath)
	if not filepath or filepath == "" then
		return nil
	end
	local project_root = project_utils.get_project_root(filepath, config.options.project)
	local local_system, local_root = systems.detect_c_family_build_system(filepath)
	if not local_system then
		return nil
	end
	if local_system == "bazel" then
		return {
			system = local_system,
			root = local_root,
			commands = {},
			info = nil,
		}
	end

	local root = local_root or systems.resolve_project_root_for_detection(filepath)
	local cached, cache_key = get_c_family_cached_entry(filepath)
	if cached and type(cached.system) == "string" and cached.system ~= "" then
		return {
			system = cached.system,
			root = cached.root,
			detect_flag = cached.detect_flag,
			commands = cache_state.copy_string_map(cached.commands),
			info = nil,
		}
	end

	local warmed_system = systems.get_cached_system_query_result("c-family", filepath, project_root)
	if
		type(warmed_system) == "table"
		and type(warmed_system.system) == "string"
		and warmed_system.system ~= ""
		and type(warmed_system.commands) == "table"
		and next(warmed_system.commands) ~= nil
	then
		local warmed_root = warmed_system.root or root
		local warmed_commands = cache_state.copy_string_map(warmed_system.commands)
		store_c_family_cached_entry(cache_key, warmed_system.system, warmed_root, warmed_commands)
		return {
			system = warmed_system.system,
			root = warmed_root,
			detect_flag = warmed_system.system == "make" and "c_cpp_make" or nil,
			commands = warmed_commands,
			info = nil,
		}
	end

	return {
		system = local_system,
		root = root,
		detect_flag = local_system == "make" and "c_cpp_make" or nil,
		commands = {},
		info = nil,
	}
end

---@param filepath string
---@param on_done fun():nil
---@return boolean
function M.prime_c_family_project_commands_async(filepath, on_done)
	if not filepath or filepath == "" then
		return false
	end
	local local_system, local_root = systems.detect_c_family_build_system(filepath)
	if not local_system or local_system == "bazel" then
		return false
	end

	local root = local_root or systems.resolve_project_root_for_detection(filepath)
	local _, cache_key = get_c_family_cached_entry(filepath)

	return tooling_transport.parse_project_lines_async("c-family-auto", filepath, {
		"--project-root=" .. root,
	}, function(lines)
		local decoded = decode_backend_project_result(lines)
		local system = decoded.system
		if type(system) ~= "string" or system == "" then
			system = local_system
			decoded.system = local_system
			decoded.root = local_root or decoded.root or root
		end
		store_c_family_cached_entry(cache_key, system, decoded.root or root, decoded.commands or {})
		on_done()
	end)
end

---@param filetype string
---@param filepath string
---@param is_detection_enabled fun(flag: string): boolean
---@param cached boolean
---@return table<string, string>
local function collect_project_commands(filetype, filepath, is_detection_enabled, cached)
	---@type table<string, string>
	local commands = {}
	local c_family_detect = cached and M.detect_c_family_build_result_cached or M.detect_c_family_build_result
	local jvm_detect = cached and M.detect_java_like_project_commands_cached or M.detect_java_like_project_commands
	local python_detect = cached and M.detect_python_project_commands_cached or M.detect_python_project_commands
	local bazel_detect = cached and M.detect_bazel_project_commands_cached or M.detect_bazel_project_commands

	if filetype == "c" or filetype == "cpp" then
		local result = c_family_detect(filepath)
		if result and (not result.detect_flag or is_detection_enabled(result.detect_flag)) then
			extend_command_map(commands, result.commands)
		end
	end
	if (filetype == "javascript" or filetype == "typescript") and is_detection_enabled("js_package_scripts") then
		extend_command_map(commands, M.detect_package_scripts(filepath))
	end
	if filetype == "python" then
		extend_command_map(commands, python_detect(filepath))
	end
	if (filetype == "java" or filetype == "kotlin") and is_detection_enabled("java_kotlin_project") then
		extend_command_map(commands, jvm_detect(filepath))
	end
	if is_detection_enabled("bazel_project") and systems.supports_bazel_project_commands(filetype) then
		extend_command_map(commands, bazel_detect(filepath))
	end

	return commands
end

---@param filetype string
---@param filepath string
---@param is_detection_enabled fun(flag: string): boolean
---@return table<string, string>
function M.collect_sync_project_commands(filetype, filepath, is_detection_enabled)
	return collect_project_commands(filetype, filepath, is_detection_enabled, false)
end

---@param filetype string
---@param filepath string
---@param is_detection_enabled fun(flag: string): boolean
---@return table<string, string>
function M.collect_sync_project_commands_cached(filetype, filepath, is_detection_enabled)
	return collect_project_commands(filetype, filepath, is_detection_enabled, true)
end

return M
