local commands = require("zignite.build.project_commands")
local parsers = require("zignite.build.project_parsers")

---@type table
local M = {}

M.detect_cmake_project_commands = parsers.detect_cmake_project_commands
M.detect_meson_project_commands = parsers.detect_meson_project_commands
M.detect_makefile_targets = parsers.detect_makefile_targets
M.detect_package_scripts = parsers.detect_package_scripts
M.detect_java_like_project_commands = parsers.detect_java_like_project_commands
M.detect_bazel_project_commands = parsers.detect_bazel_project_commands

M.extend_string_map = commands.extend_string_map
M.collect_sync_detected_commands = commands.collect_sync_detected_commands
M.detect_tool_commands_for_filetype = commands.detect_tool_commands_for_filetype
M.detect_tool_commands_for_filetype_async = commands.detect_tool_commands_for_filetype_async
M.get_configured_build_commands = commands.get_configured_build_commands
M.merge_build_commands = commands.merge_build_commands
M.get_preferred_project_command = commands.get_preferred_project_command
M.select_live_command_name = commands.select_live_command_name

return M
