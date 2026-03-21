local path_utils = require("zignite.utils.path")
local project = require("zignite.utils.project")

---@type table
local M = {}

local PYPROJECT_TOOL_PATTERNS = {
	uv = "%[tool%.uv%]",
	poetry = "%[tool%.poetry%]",
	pdm = "%[tool%.pdm%]",
	hatch = "%[tool%.hatch",
}

---@return table<string, boolean>
local function empty_tool_set()
	return {}
end

---@param payload string|nil
---@return table<string, boolean>
local function detect_pyproject_tools_from_payload(payload)
	local tools = empty_tool_set()
	if type(payload) ~= "string" then
		return tools
	end
	for tool_name, pattern in pairs(PYPROJECT_TOOL_PATTERNS) do
		if payload:find(pattern, 1, false) then
			tools[tool_name] = true
		end
	end
	return tools
end

---@param lines string[]|nil
---@return table<string, boolean>
local function detect_pyproject_tools_from_lines(lines)
	local tools = empty_tool_set()
	if type(lines) ~= "table" or #lines == 0 then
		return tools
	end
	for _, raw_line in ipairs(lines) do
		local line = tostring(raw_line or "")
		local kind, name = line:match("^([^\t]+)\t([^\t]+)$")
		if kind == "TOOL" and type(name) == "string" and name ~= "" then
			tools[name] = true
		end
	end
	return tools
end

---@param root string
---@return string
local function pyproject_path(root)
	return path_utils.join_path(root, "pyproject.toml")
end

---@param root string
---@return string|nil
local function read_pyproject_payload(root)
	return path_utils.read_text_file(pyproject_path(root))
end

---@param root string
---@return table<string, boolean>
local function detect_pyproject_tools_root_with_backend(root)
	local detect_backend = require("zignite.build.detect.backend")
	return detect_pyproject_tools_from_lines(detect_backend.parse_project_lines_once("pyproject", pyproject_path(root)))
end

---@param root string
---@param use_backend boolean
---@return table<string, boolean>
local function detect_pyproject_tools_root(root, use_backend)
	if type(root) ~= "string" or root == "" then
		return empty_tool_set()
	end

	if use_backend then
		local tools = detect_pyproject_tools_root_with_backend(root)
		if next(tools) ~= nil then
			return tools
		end
	end

	return detect_pyproject_tools_from_payload(read_pyproject_payload(root))
end

---@param filepath string
---@param project_config table|nil
---@return string
local function resolve_project_root(filepath, project_config)
	local root = project.get_project_root(filepath, project_config)
	if not root or root == "" then
		return vim.fn.fnamemodify(filepath, ":h")
	end
	return root
end

---@param root string|nil
---@param use_backend boolean
---@return boolean
local function is_uv_project_root_with(root, use_backend)
	if type(root) ~= "string" or root == "" then
		return false
	end
	if path_utils.file_exists(path_utils.join_path(root, "uv.lock")) then
		return true
	end
	return detect_pyproject_tools_root(root, use_backend).uv == true
end

---@param filepath string
---@param project_config table|nil
---@param use_backend boolean
---@return string
local function detect_python_project_tool_with(filepath, project_config, use_backend)
	local root = resolve_project_root(filepath, project_config)
	if is_uv_project_root_with(root, use_backend) then
		return "uv"
	end
	return "python"
end

---@param package_manager string
---@param script_name string
---@return string
function M.format_package_script_command(package_manager, script_name)
	local manager = tostring(package_manager or "npm")
	local script = tostring(script_name or "")
	if manager == "bun" then
		return "bun run " .. script
	end
	if manager == "yarn" then
		return "yarn " .. script
	end
	if manager == "pnpm" then
		if script == "start" then
			return "pnpm start"
		end
		if script == "test" then
			return "pnpm test"
		end
		return "pnpm run " .. script
	end
	if script == "start" then
		return "npm start"
	end
	if script == "test" then
		return "npm test"
	end
	return "npm run " .. script
end

---@param package_manager string
---@return string
function M.format_package_install_command(package_manager)
	local manager = tostring(package_manager or "npm")
	if manager == "bun" then
		return "bun install"
	end
	if manager == "yarn" then
		return "yarn install"
	end
	if manager == "pnpm" then
		return "pnpm install"
	end
	return "npm install"
end

---@param root string|nil
---@return string
function M.detect_node_package_manager_root(root)
	if type(root) ~= "string" or root == "" then
		return "npm"
	end

	local package_json_path = path_utils.join_path(root, "package.json")
	local payload = path_utils.read_text_file(package_json_path)
	local parsed = path_utils.decode_json_payload(payload or "")
	if type(parsed) == "table" and type(parsed.packageManager) == "string" then
		local manager_name = tostring(parsed.packageManager):match("^([%w_%-]+)@")
			or tostring(parsed.packageManager):match("^([%w_%-]+)")
		if manager_name == "npm" or manager_name == "pnpm" or manager_name == "yarn" or manager_name == "bun" then
			return manager_name
		end
	end

	if path_utils.file_exists(path_utils.join_path(root, "bun.lockb"))
		or path_utils.file_exists(path_utils.join_path(root, "bun.lock"))
	then
		return "bun"
	end
	if path_utils.file_exists(path_utils.join_path(root, "pnpm-lock.yaml")) then
		return "pnpm"
	end
	if path_utils.file_exists(path_utils.join_path(root, "yarn.lock")) then
		return "yarn"
	end
	return "npm"
end

---@param filepath string
---@param project_config table|nil
---@return string
function M.detect_node_package_manager(filepath, project_config)
	local root = resolve_project_root(filepath, project_config)
	return M.detect_node_package_manager_root(root)
end

---@param root string|nil
---@return boolean
function M.is_uv_project_root(root)
	return is_uv_project_root_with(root, true)
end

---@param root string|nil
---@return boolean
function M.is_uv_project_root_fast(root)
	return is_uv_project_root_with(root, false)
end

---@param filepath string
---@param project_config table|nil
---@return string
function M.detect_python_project_tool(filepath, project_config)
	return detect_python_project_tool_with(filepath, project_config, true)
end

---@param filepath string
---@param project_config table|nil
---@return string
function M.detect_python_project_tool_fast(filepath, project_config)
	return detect_python_project_tool_with(filepath, project_config, false)
end

return M
