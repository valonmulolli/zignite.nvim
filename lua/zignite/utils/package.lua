local path_utils = require("zignite.utils.path")
local project = require("zignite.utils.project")

---@type table
local M = {}

---@param root string
---@return table<string, boolean>
local function detect_pyproject_tools_root(root)
	---@type table<string, boolean>
	local tools = {}
	if type(root) ~= "string" or root == "" then
		return tools
	end

	local pyproject_path = path_utils.join_path(root, "pyproject.toml")
	local detect_backend = require("zignite.build.detect.backend")
	local lines = detect_backend.parse_project_lines_once("pyproject", pyproject_path)
	if type(lines) == "table" and #lines > 0 then
		for _, raw_line in ipairs(lines) do
			local line = tostring(raw_line or "")
			local kind, name = line:match("^([^\t]+)\t([^\t]+)$")
			if kind == "TOOL" and type(name) == "string" and name ~= "" then
				tools[name] = true
			end
		end
		return tools
	end

	local pyproject_payload = path_utils.read_text_file(pyproject_path)
	if type(pyproject_payload) ~= "string" then
		return tools
	end
	if pyproject_payload:find("%[tool%.uv%]", 1, false) then
		tools.uv = true
	end
	if pyproject_payload:find("%[tool%.poetry%]", 1, false) then
		tools.poetry = true
	end
	if pyproject_payload:find("%[tool%.pdm%]", 1, false) then
		tools.pdm = true
	end
	if pyproject_payload:find("%[tool%.hatch", 1, false) then
		tools.hatch = true
	end
	return tools
end

---@param root string
---@return table<string, boolean>
local function detect_pyproject_tools_root_fast(root)
	---@type table<string, boolean>
	local tools = {}
	if type(root) ~= "string" or root == "" then
		return tools
	end

	local pyproject_path = path_utils.join_path(root, "pyproject.toml")
	local pyproject_payload = path_utils.read_text_file(pyproject_path)
	if type(pyproject_payload) ~= "string" then
		return tools
	end
	if pyproject_payload:find("%[tool%.uv%]", 1, false) then
		tools.uv = true
	end
	if pyproject_payload:find("%[tool%.poetry%]", 1, false) then
		tools.poetry = true
	end
	if pyproject_payload:find("%[tool%.pdm%]", 1, false) then
		tools.pdm = true
	end
	if pyproject_payload:find("%[tool%.hatch", 1, false) then
		tools.hatch = true
	end
	return tools
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
	local root = project.get_project_root(filepath, project_config)
	if not root or root == "" then
		root = vim.fn.fnamemodify(filepath, ":h")
	end
	return M.detect_node_package_manager_root(root)
end

---@param root string|nil
---@return boolean
function M.is_uv_project_root(root)
	if type(root) ~= "string" or root == "" then
		return false
	end
	if path_utils.file_exists(path_utils.join_path(root, "uv.lock")) then
		return true
	end
	return detect_pyproject_tools_root(root).uv == true
end

---@param root string|nil
---@return boolean
function M.is_uv_project_root_fast(root)
	if type(root) ~= "string" or root == "" then
		return false
	end
	if path_utils.file_exists(path_utils.join_path(root, "uv.lock")) then
		return true
	end
	return detect_pyproject_tools_root_fast(root).uv == true
end

---@param filepath string
---@param project_config table|nil
---@return string
function M.detect_python_project_tool(filepath, project_config)
	local root = project.get_project_root(filepath, project_config)
	if not root or root == "" then
		root = vim.fn.fnamemodify(filepath, ":h")
	end
	if M.is_uv_project_root(root) then
		return "uv"
	end
	return "python"
end

---@param filepath string
---@param project_config table|nil
---@return string
function M.detect_python_project_tool_fast(filepath, project_config)
	local root = project.get_project_root(filepath, project_config)
	if not root or root == "" then
		root = vim.fn.fnamemodify(filepath, ":h")
	end
	if M.is_uv_project_root_fast(root) then
		return "uv"
	end
	return "python"
end

return M
