local command = require("zignite.utils.command")
local package_utils = require("zignite.utils.package")
local project = require("zignite.utils.project")

---@type table
local M = {}

M.clear_project_cache = project.clear_project_cache
M.detect_project = project.detect_project
M.get_project_root = project.get_project_root

M.format_package_script_command = package_utils.format_package_script_command
M.format_package_install_command = package_utils.format_package_install_command
M.detect_node_package_manager_root = package_utils.detect_node_package_manager_root
M.detect_node_package_manager = package_utils.detect_node_package_manager
M.is_uv_project_root = package_utils.is_uv_project_root
M.is_uv_project_root_fast = package_utils.is_uv_project_root_fast
M.detect_python_project_tool = package_utils.detect_python_project_tool
M.detect_python_project_tool_fast = package_utils.detect_python_project_tool_fast

M.substitute_variables = command.substitute_variables
M.substitute_variables_raw = command.substitute_variables_raw
M.normalize_command = command.normalize_command

return M
