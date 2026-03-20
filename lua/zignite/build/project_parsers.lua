local bazel = require("zignite.build.parsers.bazel")
local cmake = require("zignite.build.parsers.cmake")
local jvm = require("zignite.build.parsers.jvm")
local make = require("zignite.build.parsers.make")
local meson = require("zignite.build.parsers.meson")
local package_json = require("zignite.build.parsers.package_json")

---@type table
local M = {}

M.detect_cmake_project_commands = cmake.detect_cmake_project_commands
M.detect_meson_project_commands = meson.detect_meson_project_commands
M.detect_makefile_targets = make.detect_makefile_targets
M.detect_package_scripts = package_json.detect_package_scripts
M.detect_java_like_project_commands = jvm.detect_java_like_project_commands
M.detect_bazel_project_commands = bazel.detect_bazel_project_commands

return M
