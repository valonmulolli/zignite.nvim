local data = require("integration.support.simulate.data")
local util = require("integration.support.simulate.util")

---@type table
local M = {
	project_backend_lines = data.project_backend_lines,
}

---@param root string
---@param target string
---@return string|nil
local function discover_build_run_path(root, target)
	local target_exe = target .. ".exe"
	local candidates = {
		"./build/" .. target,
		"./build/" .. target_exe,
		"./build/bin/" .. target,
		"./build/bin/" .. target_exe,
		"./build/Debug/" .. target,
		"./build/Debug/" .. target_exe,
		"./build/Release/" .. target,
		"./build/Release/" .. target_exe,
		"./build/RelWithDebInfo/" .. target,
		"./build/RelWithDebInfo/" .. target_exe,
		"./build/MinSizeRel/" .. target,
		"./build/MinSizeRel/" .. target_exe,
		"./build/bin/Debug/" .. target,
		"./build/bin/Debug/" .. target_exe,
		"./build/bin/Release/" .. target,
		"./build/bin/Release/" .. target_exe,
		"./build/bin/RelWithDebInfo/" .. target,
		"./build/bin/RelWithDebInfo/" .. target_exe,
		"./build/bin/MinSizeRel/" .. target,
		"./build/bin/MinSizeRel/" .. target_exe,
	}
	for _, relative_path in ipairs(candidates) do
		if util.filereadable(vim.fs.joinpath(root, relative_path:gsub("^%./", ""))) then
			return relative_path
		end
	end
	return nil
end

---@param target string
---@param run_path string|nil
---@return string
local function build_discovered_run_suffix(target, run_path)
	if type(run_path) == "string" and run_path ~= "" then
		return run_path
	end
	local target_exe = target .. ".exe"
	local candidate_paths = table.concat({
		"./build/" .. target,
		"./build/" .. target_exe,
		"./build/bin/" .. target,
		"./build/bin/" .. target_exe,
		"./build/Debug/" .. target,
		"./build/Debug/" .. target_exe,
		"./build/Release/" .. target,
		"./build/Release/" .. target_exe,
		"./build/RelWithDebInfo/" .. target,
		"./build/RelWithDebInfo/" .. target_exe,
		"./build/MinSizeRel/" .. target,
		"./build/MinSizeRel/" .. target_exe,
		"./build/bin/Debug/" .. target,
		"./build/bin/Debug/" .. target_exe,
		"./build/bin/Release/" .. target,
		"./build/bin/Release/" .. target_exe,
		"./build/bin/RelWithDebInfo/" .. target,
		"./build/bin/RelWithDebInfo/" .. target_exe,
		"./build/bin/MinSizeRel/" .. target,
		"./build/bin/MinSizeRel/" .. target_exe,
	}, " ")
	return string.format(
		"for ZIGNITE_CANDIDATE in %s; do "
			.. "if [ -x \"$ZIGNITE_CANDIDATE\" ]; then \"$ZIGNITE_CANDIDATE\"; exit $?; fi; "
			.. "done; "
			.. "ZIGNITE_BIN=$(find build -type f \\( -name %s -o -name %s \\) "
			.. "! -path '*/CMakeFiles/*' ! -path '*/meson-private/*' ! -path '*/meson-logs/*' "
			.. "| head -n 1) && "
			.. "if [ -n \"$ZIGNITE_BIN\" ] && [ -x \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; "
			.. "elif [ -n \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; "
			.. "else %s; fi",
		candidate_paths,
		target,
		target_exe,
		"./build/" .. target
	)
end

---@param root string
---@return boolean
local function has_cmake_build_tree(root)
	return util.filereadable(vim.fs.joinpath(root, "build", "CMakeCache.txt"))
end

---@param root string
---@return boolean
local function has_meson_build_tree(root)
	return util.filereadable(vim.fs.joinpath(root, "build", "build.ninja"))
		or util.filereadable(vim.fs.joinpath(root, "build", "meson-private", "coredata.dat"))
end

---@param root string
---@return string[]
local function build_cmake_backend_lines(root)
	local ready = has_cmake_build_tree(root)
	local target = "app"
	local run_path = discover_build_run_path(root, target)
	local target_build = ready and "cmake --build build --target app"
		or "cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build --target app"
	local generic_build = ready and "cmake --build build"
		or "cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build"
	local target_run = target_build .. " && " .. build_discovered_run_suffix(target, run_path)
	local lines = {
		"COMMAND\tcmake-config\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1",
		"COMMAND\tcmake-clean\t" .. (ready and "cmake --build build --target clean" or "cmake -E rm -rf build"),
		"COMMAND\tcmake-debug\t"
			.. "cmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
		"COMMAND\tcmake-release\t"
			.. "cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
		"COMMAND\tcmake-test\tctest --test-dir build",
		"COMMAND\tinstall\tcmake --build build --target install",
		"TARGET\tapp\t1",
		"COMMAND\tcmake-build\t" .. generic_build,
		"COMMAND\tcmake-run\t" .. target_run,
		"COMMAND\tcmake-build-app\t" .. target_build,
		"COMMAND\tcmake-run-app\t" .. target_run,
		"PREFERRED\tbuild\t" .. generic_build,
		"PRIMARY_TARGET\tapp",
		"PREFERRED\trun\t" .. target_run,
	}
	if run_path then
		lines[#lines + 1] = "RUN_PATH\tapp\t" .. run_path
		lines[#lines + 1] = "PRIMARY_RUN_PATH\t" .. run_path
	end
	return lines
end

---@param root string
---@return string[]
local function build_meson_backend_lines(root)
	local ready = has_meson_build_tree(root)
	local target = "demo-app"
	local run_path = discover_build_run_path(root, target)
	local target_build = ready and "meson compile -C build demo-app"
		or "meson setup build && meson compile -C build demo-app"
	local generic_build = ready and "meson compile -C build" or "meson setup build && meson compile -C build"
	local target_run = target_build .. " && " .. build_discovered_run_suffix(target, run_path)
	local lines = {
		"COMMAND\tmeson-setup\tmeson setup build",
		"COMMAND\tmeson-clean\t" .. (ready and "meson compile -C build --clean" or "cmake -E rm -rf build"),
		"COMMAND\tmeson-test\tmeson test -C build",
		"COMMAND\tinstall\tmeson install -C build",
		"TARGET\tdemo-app\t1",
		"COMMAND\tmeson-build\t" .. generic_build,
		"COMMAND\tmeson-run\t" .. target_run,
		"COMMAND\tmeson-build-demo-app\t" .. target_build,
		"COMMAND\tmeson-run-demo-app\t" .. target_run,
		"PREFERRED\tbuild\t" .. generic_build,
		"PRIMARY_TARGET\tdemo-app",
		"PREFERRED\trun\t" .. target_run,
	}
	if run_path then
		lines[#lines + 1] = "RUN_PATH\tdemo-app\t" .. run_path
		lines[#lines + 1] = "PRIMARY_RUN_PATH\t" .. run_path
	end
	return lines
end

---@param request_text string
---@return table<string, string>|nil
local function parse_project_request_args(request_text)
	local req_lines = util.split_lines(request_text or "")
	if #req_lines < 3 then
		return nil
	end

	local begin_line = req_lines[1]
	local request_id = begin_line:match("^@@ZPRJ_REQ_BEGIN%s+(%d+)$")
	if not request_id then
		return nil
	end

	local end_line = req_lines[#req_lines]
	local end_id = end_line:match("^@@ZPRJ_REQ_END%s+(%d+)$")
	if not end_id or tonumber(end_id) ~= tonumber(request_id) then
		return nil
	end

	---@type table<string, string>
	local args = { request_id = request_id }
	for index = 2, #req_lines - 1 do
		local line = req_lines[index]
		if line:sub(1, 1) == "\t" then
			line = line:sub(2)
		end
		local key, value = line:match("^%-%-([^=]+)=(.+)$")
		if key and value and value ~= "" then
			args[key] = value
		end
	end
	return args.kind and args or nil
end

---@param path string
---@param query string|nil
---@param project_root string|nil
---@return string[]
function M.build_system_backend_lines(path, query, project_root)
	local bazel_markers = { "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE" }
	local gradle_markers = { "gradlew", "settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle" }
	local root = (type(project_root) == "string" and project_root ~= "") and project_root or util.dirname(path)

	if query == "c-family" then
		local bazel_root = util.has_any_marker(root, bazel_markers) and root or util.find_root_for_markers(path, bazel_markers, 12)
		if bazel_root then
			return {
				"ROOT\t" .. bazel_root,
				"SYSTEM\tbazel",
				"COMMAND\tbazel-query\tbazel query $zignite_args",
				"COMMAND\tbazel-clean\tbazel clean",
				"COMMAND\tbazel-build-all\tbazel build //...",
				"COMMAND\tbazel-test-all\tbazel test //...",
				"COMMAND\tbuild\tbazel build //...",
				"COMMAND\ttest\tbazel test //...",
			}
		end
		local meson_root = util.has_any_marker(root, { "meson.build" }) and root or util.find_root_for_markers(path, { "meson.build" }, 12)
		if meson_root then
			local ready = util.filereadable(vim.fs.joinpath(meson_root, "build", "build.ninja"))
				or util.filereadable(vim.fs.joinpath(meson_root, "build", "meson-private", "coredata.dat"))
			local build_command = ready and "meson compile -C build" or "meson setup build && meson compile -C build"
			local clean_command = ready and "meson compile -C build --clean" or "cmake -E rm -rf build"
			return {
				"ROOT\t" .. meson_root,
				"SYSTEM\tmeson",
				"BUILD_READY\t" .. (ready and "1" or "0"),
				"COMMAND\tmeson-setup\tmeson setup build",
				"COMMAND\tmeson-build\t" .. build_command,
				"COMMAND\tmeson-clean\t" .. clean_command,
				"COMMAND\tmeson-test\tmeson test -C build",
				"COMMAND\tinstall\tmeson install -C build",
				"COMMAND\tsetup\tmeson setup build",
				"COMMAND\tbuild\t" .. build_command,
				"COMMAND\tclean\t" .. clean_command,
				"COMMAND\ttest\tmeson test -C build",
			}
		end
		local cmake_root = util.has_any_marker(root, { "CMakeLists.txt" }) and root
			or util.find_root_for_markers(path, { "CMakeLists.txt" }, 12)
		if cmake_root then
			local ready = util.filereadable(vim.fs.joinpath(cmake_root, "build", "CMakeCache.txt"))
			local build_command = ready and "cmake --build build"
				or "cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build"
			local clean_command = ready and "cmake --build build --target clean" or "cmake -E rm -rf build"
			local debug_command = "cmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1"
				.. " && cmake --build build"
			local release_command = "cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1"
				.. " && cmake --build build"
			return {
				"ROOT\t" .. cmake_root,
				"SYSTEM\tcmake",
				"BUILD_READY\t" .. (ready and "1" or "0"),
				"COMMAND\tcmake-config\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1",
				"COMMAND\tcmake-build\t" .. build_command,
				"COMMAND\tcmake-clean\t" .. clean_command,
				"COMMAND\tcmake-debug\t" .. debug_command,
				"COMMAND\tcmake-release\t" .. release_command,
				"COMMAND\tcmake-test\tctest --test-dir build",
				"COMMAND\tinstall\tcmake --build build --target install",
				"COMMAND\tconfig\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1",
				"COMMAND\tbuild\t" .. build_command,
				"COMMAND\tclean\t" .. clean_command,
				"COMMAND\tdebug\t" .. debug_command,
				"COMMAND\trelease\t" .. release_command,
				"COMMAND\ttest\tctest --test-dir build",
			}
		end
		local make_root = util.filereadable(vim.fs.joinpath(root, "Makefile")) and root
			or util.find_root_for_markers(path, { "Makefile" }, 12)
		if make_root then
			return {
				"ROOT\t" .. make_root,
				"SYSTEM\tmake",
				"COMMAND\tbuild\tmake",
			}
		end
		return { "ROOT\t" .. root }
	end

	if query == "bazel-root" then
		if util.has_any_marker(root, bazel_markers) then
			return {
				"ROOT\t" .. root,
				"SYSTEM\tbazel",
				"COMMAND\tbazel-query\tbazel query $zignite_args",
				"COMMAND\tbazel-clean\tbazel clean",
				"COMMAND\tbazel-build-all\tbazel build //...",
				"COMMAND\tbazel-test-all\tbazel test //...",
				"COMMAND\tbuild\tbazel build //...",
				"COMMAND\ttest\tbazel test //...",
			}
		end
		local found = util.find_root_for_markers(path, bazel_markers, 12)
		if found then
			return {
				"ROOT\t" .. found,
				"SYSTEM\tbazel",
				"COMMAND\tbazel-query\tbazel query $zignite_args",
				"COMMAND\tbazel-clean\tbazel clean",
				"COMMAND\tbazel-build-all\tbazel build //...",
				"COMMAND\tbazel-test-all\tbazel test //...",
				"COMMAND\tbuild\tbazel build //...",
				"COMMAND\ttest\tbazel test //...",
			}
		end
		return {}
	end

	if query == "node-root" then
		local markers = { "package.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock" }
		local found = util.has_any_marker(root, markers) and root or util.find_root_for_markers(path, markers, 12)
		if not found then
			return {}
		end
		local manager = "npm"
		if util.filereadable(vim.fs.joinpath(found, "bun.lockb")) or util.filereadable(vim.fs.joinpath(found, "bun.lock")) then
			manager = "bun"
		elseif util.filereadable(vim.fs.joinpath(found, "pnpm-lock.yaml")) then
			manager = "pnpm"
		elseif util.filereadable(vim.fs.joinpath(found, "yarn.lock")) then
			manager = "yarn"
		end
		local install_command = manager == "bun" and "bun install"
			or manager == "yarn" and "yarn install"
			or manager == "pnpm" and "pnpm install"
			or "npm install"
		return {
			"ROOT\t" .. found,
			"SYSTEM\tnode",
			"COMMAND\tinstall\t" .. install_command,
		}
	end

	if query == "python-root" then
		local markers = { "pyproject.toml", "uv.lock", "requirements.txt", "environment.yml", "environment.yaml" }
		local found = util.has_any_marker(root, markers) and root or util.find_root_for_markers(path, markers, 12)
		if not found then
			return {}
		end
		local pyproject_payload = util.read_file_lines_direct(vim.fs.joinpath(found, "pyproject.toml"))
		local conda_env_path = util.filereadable(vim.fs.joinpath(found, "environment.yml"))
				and vim.fs.joinpath(found, "environment.yml")
			or util.filereadable(vim.fs.joinpath(found, "environment.yaml"))
				and vim.fs.joinpath(found, "environment.yaml")
			or nil
		local conda_payload = type(conda_env_path) == "string" and util.read_file_lines_direct(conda_env_path) or nil
		local uses_uv = util.filereadable(vim.fs.joinpath(found, "uv.lock"))
			or (type(pyproject_payload) == "table" and vim.tbl_contains(pyproject_payload, "[tool.uv]"))
		local uses_requirements = util.filereadable(vim.fs.joinpath(found, "requirements.txt"))
		local lines = {
			"ROOT\t" .. found,
			"SYSTEM\tpython",
		}
		if uses_uv then
			lines[#lines + 1] = "COMMAND\trun\tuv run -m main"
			lines[#lines + 1] = "COMMAND\ttest\tuv run pytest"
			lines[#lines + 1] = "COMMAND\tinstall\tuv sync"
		elseif type(conda_payload) == "table" then
			local env_name
			for _, raw_line in ipairs(conda_payload) do
				local line = util.trim_text((raw_line or ""):gsub("#.*$", ""))
				local value = line:match("^name:%s*(.+)$")
				if type(value) == "string" and value ~= "" then
					env_name = util.trim_text(value)
					break
				end
			end
			local run_prefix = env_name and ("conda run -n " .. env_name) or "conda run"
			lines[#lines + 1] = "COMMAND\trun\t" .. run_prefix .. " python -m main"
			lines[#lines + 1] = "COMMAND\ttest\t" .. run_prefix .. " pytest"
			lines[#lines + 1] = "COMMAND\tinstall\tconda env update -f " .. vim.fs.basename(conda_env_path) .. " --prune"
		elseif uses_requirements then
			lines[#lines + 1] = "COMMAND\trun\tpython -m main"
			lines[#lines + 1] = "COMMAND\ttest\tpytest"
			lines[#lines + 1] = "COMMAND\tinstall\tpip install -r requirements.txt"
		end
		return lines
	end

	if query == "jvm-root" then
		if util.filereadable(vim.fs.joinpath(root, "pom.xml")) then
			return {
				"ROOT\t" .. root,
				"SYSTEM\tmaven",
				"COMMAND\tmvn-build\tmvn compile",
				"COMMAND\tmvn-test\tmvn test",
				"COMMAND\tmvn-package\tmvn package",
				"COMMAND\tbuild\tmvn compile",
				"COMMAND\ttest\tmvn test",
			}
		end
		if util.has_any_marker(root, gradle_markers) then
			local gradle_prefix = util.filereadable(vim.fs.joinpath(root, "gradlew")) and "./gradlew" or "gradle"
			return {
				"ROOT\t" .. root,
				"SYSTEM\tgradle",
				"COMMAND\tgradle-build\t" .. gradle_prefix .. " build",
				"COMMAND\tgradle-test\t" .. gradle_prefix .. " test",
				"COMMAND\tgradle-clean\t" .. gradle_prefix .. " clean",
				"COMMAND\tbuild\t" .. gradle_prefix .. " build",
				"COMMAND\ttest\t" .. gradle_prefix .. " test",
				"COMMAND\tclean\t" .. gradle_prefix .. " clean",
			}
		end
		local jvm_markers = {
			"pom.xml",
			"gradlew",
			"settings.gradle.kts",
			"settings.gradle",
			"build.gradle.kts",
			"build.gradle",
		}
		local found = util.find_root_for_markers(path, jvm_markers, 12)
		if found then
			if util.filereadable(vim.fs.joinpath(found, "pom.xml")) then
				return {
					"ROOT\t" .. found,
					"SYSTEM\tmaven",
					"COMMAND\tmvn-build\tmvn compile",
					"COMMAND\tmvn-test\tmvn test",
					"COMMAND\tmvn-package\tmvn package",
					"COMMAND\tbuild\tmvn compile",
					"COMMAND\ttest\tmvn test",
				}
			end
			local gradle_prefix = util.filereadable(vim.fs.joinpath(found, "gradlew")) and "./gradlew" or "gradle"
			return {
				"ROOT\t" .. found,
				"SYSTEM\tgradle",
				"COMMAND\tgradle-build\t" .. gradle_prefix .. " build",
				"COMMAND\tgradle-test\t" .. gradle_prefix .. " test",
				"COMMAND\tgradle-clean\t" .. gradle_prefix .. " clean",
				"COMMAND\tbuild\t" .. gradle_prefix .. " build",
				"COMMAND\ttest\t" .. gradle_prefix .. " test",
				"COMMAND\tclean\t" .. gradle_prefix .. " clean",
			}
		end
	end

	return {}
end

---@param path string
---@param project_root string|nil
---@return string[]
function M.build_c_family_auto_lines(path, project_root)
	local system_lines = M.build_system_backend_lines(path, "c-family", project_root)
	local detected_system = nil
	local detected_root = nil
	for _, line in ipairs(system_lines) do
		detected_system = line:match("^SYSTEM\t(.+)$") or detected_system
		detected_root = line:match("^ROOT\t(.+)$") or detected_root
	end

	if detected_system == "make" then
		local lines = vim.deepcopy(system_lines)
		for _, line in ipairs(M.project_backend_lines["make-auto"] or {}) do
			lines[#lines + 1] = line
		end
		return lines
	end
	if detected_system == "cmake" then
		local root = detected_root or util.dirname(path)
		local lines = vim.deepcopy(system_lines)
		for _, line in ipairs(build_cmake_backend_lines(root)) do
			lines[#lines + 1] = line
		end
		return lines
	end
	if detected_system == "meson" then
		local root = detected_root or util.dirname(path)
		local lines = vim.deepcopy(system_lines)
		for _, line in ipairs(build_meson_backend_lines(root)) do
			lines[#lines + 1] = line
		end
		return lines
	end
	if detected_system == "bazel" then
		local lines = vim.deepcopy(system_lines)
		for _, line in ipairs(M.project_backend_lines["bazel-auto"] or {}) do
			lines[#lines + 1] = line
		end
		return lines
	end

	return system_lines
end

---@param request_text string
---@return string[]|nil
function M.parse_project_daemon_request(request_text)
	local args = parse_project_request_args(request_text)
	if not args then
		return nil
	end

	local response = { "@@ZPRJ_RES_BEGIN " .. args.request_id }
	local jvm_auto_lines = nil
	if args.kind == "jvm-auto" then
		local system_lines = M.build_system_backend_lines(args.path or "", "jvm-root", args["project-root"])
		local detected_system = nil
		for _, line in ipairs(system_lines) do
			detected_system = line:match("^SYSTEM\t(.+)$") or detected_system
		end
		if detected_system == "maven" then
			jvm_auto_lines = M.project_backend_lines.maven or {}
		elseif detected_system == "gradle" then
			jvm_auto_lines = M.project_backend_lines.gradle or {}
		else
			jvm_auto_lines = {}
		end
	end
	local lines = args.kind == "system"
			and M.build_system_backend_lines(args.path or "", args.query, args["project-root"])
		or (args.kind == "c-family-auto" and M.build_c_family_auto_lines(args.path or "", args["project-root"]))
		or (args.kind == "cmake" and build_cmake_backend_lines(util.dirname(args.path or "")))
		or (args.kind == "meson" and build_meson_backend_lines(util.dirname(args.path or "")))
		or (args.kind == "cargo-auto" and (M.project_backend_lines.cargo or {}))
		or (args.kind == "go-auto" and (M.project_backend_lines.go or {}))
		or (args.kind == "bazel-workspace" and (M.project_backend_lines.bazel or {}))
		or jvm_auto_lines
		or (M.project_backend_lines[args.kind] or {})
	for _, line in ipairs(lines) do
		response[#response + 1] = "\t" .. line
	end
	response[#response + 1] = "@@ZPRJ_RES_END " .. args.request_id
	return response
end

return M
