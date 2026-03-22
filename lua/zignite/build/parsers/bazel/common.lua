local parser_common = require("zignite.build.parsers.common")

---@type table
local M = {}

---@class ZigniteBazelBuildFile
---@field build_file string
---@field package_dir string
---@field package_path string

---@param build_dir string
---@param workspace_root string
---@return string
function M.package_path_from_dir(build_dir, workspace_root)
	local normalized_dir = parser_common.normalize_path_text(build_dir)
	local normalized_root = parser_common.normalize_path_text(workspace_root)
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
---@return ZigniteBazelBuildFile[]
function M.find_build_files_for_path(start_path, workspace_root)
	---@type ZigniteBazelBuildFile[]
	local build_files = {}
	local dir = vim.fn.fnamemodify(start_path, ":h")
	local normalized_root = parser_common.normalize_path_text(workspace_root)

	while type(dir) == "string" and dir ~= "" do
		for _, file_name in ipairs({ "BUILD.bazel", "BUILD" }) do
			local candidate = vim.fs.joinpath(dir, file_name)
			if vim.fn.filereadable(candidate) == 1 then
				build_files[#build_files + 1] = {
					build_file = candidate,
					package_dir = dir,
					package_path = M.package_path_from_dir(dir, workspace_root),
				}
				break
			end
		end

		local normalized_dir = parser_common.normalize_path_text(dir)
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

return M
