local config = require("zignite.config")
local detect_backend = require("zignite.build.detect.backend")
local state = require("zignite.build.state")
local utils = require("zignite.utils")

---@type table
local M = {}

---@param info table|nil
---@return table|nil
local function copy_info(info)
	if type(info) ~= "table" then
		return nil
	end
	return {
		module_name = info.module_name,
		primary_selector = info.primary_selector,
		primary_build = info.primary_build,
		primary_run = info.primary_run,
		primary_test = info.primary_test,
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
	end
	return info
end

---@param commands table<string, string>
---@param info table
---@return nil
local function add_commands_from_info(commands, info)
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
	for _, raw_line in ipairs(zig_lines) do
		local line = tostring(raw_line or "")
		local kind, value = line:match("^([^\t]+)\t(.*)$")
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
		end
	end

	if next(info) == nil then
		return {}, nil
	end

	---@type table<string, string>
	local commands = {}
	add_commands_from_info(commands, info)
	return commands, copy_info(info)
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

	if type(vim.fn.readfile) ~= "function" or vim.fn.filereadable(go_mod_path) ~= 1 then
		return nil
	end
	for _, raw_line in ipairs(vim.fn.readfile(go_mod_path)) do
		local line = tostring(raw_line or ""):gsub("//.*$", ""):gsub("\r$", "")
		local name = line:match('^%s*module%s+([^%s]+)')
		if name and name ~= "" then
			return name:gsub('^["\'`]', ""):gsub('["\'`]$', "")
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

	if type(vim.fn.readfile) ~= "function" or vim.fn.filereadable(go_work_path) ~= 1 then
		return nil
	end

	local workspace_root = normalize_path(vim.fn.fnamemodify(go_work_path, ":h"))
	local candidate = normalize_path(filepath)
	local in_use_block = false
	local first_root = nil

	for _, raw_line in ipairs(vim.fn.readfile(go_work_path)) do
		local line = tostring(raw_line or ""):gsub("//.*$", ""):gsub("\r$", "")
		line = line:match("^%s*(.-)%s*$") or ""
		if line == "" then
			goto continue
		end
		if not in_use_block then
			if line == "use(" or line == "use (" then
				in_use_block = true
				goto continue
			end
			if line:match("^use%s+") then
				local value = (line:gsub("^use%s+", ""))
				local path = normalize_path(vim.fs.joinpath(workspace_root, value:gsub('^["\'`]', ""):gsub('["\'`]$', "")))
				first_root = first_root or path
				if candidate == path or candidate:sub(1, #path + 1) == (path .. "/") then
					return path
				end
			end
			goto continue
		end
		if line == ")" then
			in_use_block = false
			goto continue
		end
		local path = normalize_path(vim.fs.joinpath(workspace_root, line:gsub('^["\'`]', ""):gsub('["\'`]$', "")))
		first_root = first_root or path
		if candidate == path or candidate:sub(1, #path + 1) == (path .. "/") then
			return path
		end
		::continue::
	end

	return first_root
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
		return state.copy_string_map(cached.commands), copy_info(cached.info)
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
					info = copy_info(info),
				}
			)
			return state.copy_string_map(commands), copy_info(info)
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
					info = copy_info(info),
				}
			)
			return state.copy_string_map(commands), copy_info(info)
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
			info = copy_info(info),
		}
	)

	return commands, copy_info(info)
end

return M
