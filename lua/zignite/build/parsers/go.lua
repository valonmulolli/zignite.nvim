local config = require("zignite.config")
local detect_backend = require("zignite.build.detect.backend")
local state = require("zignite.build.state")
local utils = require("zignite.utils")

---@type table
local M = {}

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
---@return table<string, string>, string|nil, string|nil
function M.detect_go_project_commands(filepath)
	if not filepath or filepath == "" or type(vim.fn.filereadable) ~= "function" then
		return {}, nil, nil
	end

	local root = utils.get_project_root(filepath, config.options.project)
	if not root or root == "" then
		return {}, nil, nil
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
		return state.copy_string_map(cached.commands), cached.primary_selector, cached.module_name
	end

	local selector
	local module_name
	if vim.fn.filereadable(go_work_path) == 1 then
		local matched_root = detect_workspace_use_root(go_work_path, filepath)
		if matched_root and matched_root ~= "" then
			module_name = parse_go_module_name(vim.fs.joinpath(matched_root, "go.mod"))
		end
		selector = package_selector(root, filepath)
	elseif vim.fn.filereadable(go_mod_path) == 1 then
		module_name = parse_go_module_name(go_mod_path)
		selector = package_selector(root, filepath)
	else
		state.set_bounded_cache_entry(
			state.go_project_cache,
			state.go_project_cache_order,
			state.GO_PROJECT_CACHE_MAX,
			cache_key,
			{ mtime_key = mtime_key, commands = {}, primary_selector = nil, module_name = nil }
		)
		return {}, nil, nil
	end

	if type(selector) ~= "string" or selector == "" then
		selector = "."
	end

	local commands = {
		["go-build-package"] = "go build " .. selector,
		["go-run-package"] = "go run " .. selector,
		["go-test-package"] = "go test " .. selector,
	}

	state.set_bounded_cache_entry(
		state.go_project_cache,
		state.go_project_cache_order,
		state.GO_PROJECT_CACHE_MAX,
		cache_key,
		{
			mtime_key = mtime_key,
			commands = state.copy_string_map(commands),
			primary_selector = selector,
			module_name = module_name,
		}
	)

	return commands, selector, module_name
end

return M
