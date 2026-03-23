---@type table
local M = {}

M.detect_backend_tool_commands = {
	zig = {
		"build\tzig build",
		"fmt\tzig fmt $file",
		"fetch\tzig fetch $zignite_args",
		"run\tzig run $file",
	},
	go = {
		"build\tgo build",
		"env\tgo env",
		"fmt\tgo fmt ./...",
	},
	cargo = {
		"build\tcargo build",
		"check\tcargo check",
		"run\tcargo run",
	},
	odin = {
		"build\todin build .",
		"run\todin run .",
		"test\todin test .",
	},
}

M.project_backend_lines = {
	make = {
		"COMMAND\tbench\tmake bench",
		"COMMAND\ttest\tmake test",
	},
	["package-json"] = {
		"COMMAND\tdev\tnpm run dev",
		"COMMAND\tbuild\tnpm run build",
	},
	maven = {
		"COMMAND\tmvn-build\tmvn compile",
		"COMMAND\tmvn-test\tmvn test",
		"COMMAND\tmvn-package\tmvn package",
		"COMMAND\tmvn-run\tmvn spring-boot:run",
		"COMMAND\tbuild\tmvn compile",
		"COMMAND\ttest\tmvn test",
		"COMMAND\trun\tmvn spring-boot:run",
		"PRIMARY_RUN\tmvn spring-boot:run",
		"PREFERRED\tbuild\tmvn compile",
		"PREFERRED\ttest\tmvn test",
		"PREFERRED\trun\tmvn spring-boot:run",
	},
	gradle = {
		"COMMAND\tgradle-build\t./gradlew build",
		"COMMAND\tgradle-test\t./gradlew test",
		"COMMAND\tgradle-clean\t./gradlew clean",
		"COMMAND\tgradle-run\t./gradlew bootRun",
		"COMMAND\tbuild\t./gradlew build",
		"COMMAND\ttest\t./gradlew test",
		"COMMAND\tclean\t./gradlew clean",
		"COMMAND\trun\t./gradlew bootRun",
		"PRIMARY_RUN\t./gradlew bootRun",
		"PREFERRED\tbuild\t./gradlew build",
		"PREFERRED\ttest\t./gradlew test",
		"PREFERRED\trun\t./gradlew bootRun",
	},
	cmake = {
		"COMMAND\tcmake-config\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1",
		"COMMAND\tcmake-clean\tcmake --build build --target clean",
		"COMMAND\tcmake-debug\t"
			.. "cmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
		"COMMAND\tcmake-release\t"
			.. "cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
		"COMMAND\tcmake-test\tctest --test-dir build",
		"COMMAND\tinstall\tcmake --build build --target install",
		"TARGET\tapp\t1",
		"COMMAND\tcmake-build\tcmake --build build",
		"COMMAND\tcmake-run\tcmake --build build --target app && ./build/bin/app",
		"COMMAND\tcmake-build-app\tcmake --build build --target app",
		"COMMAND\tcmake-run-app\tcmake --build build --target app && ./build/bin/app",
		"RUN_PATH\tapp\t./build/bin/app",
		"PREFERRED\tbuild\tcmake --build build",
		"PRIMARY_TARGET\tapp",
		"PRIMARY_RUN_PATH\t./build/bin/app",
		"PREFERRED\trun\tcmake --build build --target app && ./build/bin/app",
	},
	bazel = {
		"COMMAND\tbazel-query\tbazel query $zignite_args",
		"COMMAND\tbazel-clean\tbazel clean",
		"COMMAND\tbazel-build-all\tbazel build //...",
		"COMMAND\tbazel-test-all\tbazel test //...",
		"TARGET\tcc_binary\tapp\t1\t0\tmain.cc",
		"COMMAND\tbazel-build-app\tbazel build //:app",
		"COMMAND\tbazel-run-app\tbazel run //:app",
		"COMMAND\tbazel-build\tbazel build //:app",
		"COMMAND\tbazel-run\tbazel run //:app",
		"COMMAND\tbuild\tbazel build //:app",
		"COMMAND\trun\tbazel run //:app",
		"PRIMARY_BUILD\tbazel build //:app",
		"PRIMARY_RUN\tbazel run //:app",
		"PREFERRED\tbuild\tbazel build //:app",
		"PREFERRED\trun\tbazel run //:app",
	},
	meson = {
		"COMMAND\tmeson-setup\tmeson setup build",
		"COMMAND\tmeson-clean\tmeson compile -C build --clean",
		"COMMAND\tmeson-test\tmeson test -C build",
		"COMMAND\tinstall\tmeson install -C build",
		"TARGET\tapp\t1",
		"COMMAND\tmeson-build\tmeson compile -C build",
		"COMMAND\tmeson-run\tmeson compile -C build app && ./build/app",
		"COMMAND\tmeson-build-app\tmeson compile -C build app",
		"COMMAND\tmeson-run-app\tmeson compile -C build app && ./build/app",
		"RUN_PATH\tapp\t./build/app",
		"PREFERRED\tbuild\tmeson compile -C build",
		"PRIMARY_TARGET\tapp",
		"PRIMARY_RUN_PATH\t./build/app",
		"PREFERRED\trun\tmeson compile -C build app && ./build/app",
	},
	cargo = {
		"BIN\tapp\t1",
		"COMMAND\tcargo-build-app\tcargo build --bin 'app'",
		"COMMAND\tcargo-run-app\tcargo run --bin 'app'",
		"COMMAND\tcargo-test-app\tcargo test --bin 'app'",
		"PRIMARY_BIN\tapp",
		"PRIMARY_RUN\tcargo run --bin 'app'",
		"PRIMARY_RELEASE_RUN\tcargo run --release --bin 'app'",
		"PREFERRED\trun\tcargo run --bin 'app'",
		"PREFERRED\trelease-run\tcargo run --release --bin 'app'",
	},
	go = {
		"MODULE\texample.com/app",
		"PRIMARY_SELECTOR\t./cmd/app",
		"COMMAND\tgo-build-package\tgo build './cmd/app'",
		"COMMAND\tgo-run-package\tgo run './cmd/app'",
		"COMMAND\tgo-test-package\tgo test './cmd/app'",
		"PRIMARY_BUILD\tgo build './cmd/app'",
		"PRIMARY_RUN\tgo run './cmd/app'",
		"PRIMARY_TEST\tgo test './cmd/app'",
		"PREFERRED\tbuild\tgo build './cmd/app'",
		"PREFERRED\trun\tgo run './cmd/app'",
		"PREFERRED\ttest\tgo test './cmd/app'",
	},
	pyproject = { "TOOL\tuv" },
}

---@param text string
---@return string[]
local function split_lines(text)
	---@type string[]
	local lines = {}
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		if line ~= "" then
			table.insert(lines, line)
		end
	end
	return lines
end

---@param path string
---@return string
local function dirname(path)
	return vim.fn.fnamemodify(path, ":h")
end

---@param path string
---@return boolean
local function filereadable(path)
	return type(vim.fn.filereadable) == "function" and vim.fn.filereadable(path) == 1
end

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
		if filereadable(vim.fs.joinpath(root, relative_path:gsub("^%./", ""))) then
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
	return filereadable(vim.fs.joinpath(root, "build", "CMakeCache.txt"))
end

---@param root string
---@return boolean
local function has_meson_build_tree(root)
	return filereadable(vim.fs.joinpath(root, "build", "build.ninja"))
		or filereadable(vim.fs.joinpath(root, "build", "meson-private", "coredata.dat"))
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

---@param root string
---@param markers string[]
---@return boolean
local function has_any_marker(root, markers)
	for _, marker in ipairs(markers or {}) do
		if filereadable(vim.fs.joinpath(root, marker)) then
			return true
		end
	end
	return false
end

---@param start_path string
---@param markers string[]
---@param max_up integer
---@return string|nil
local function find_root_for_markers(start_path, markers, max_up)
	local dir = dirname(start_path)
	local limit = max_up or 12
	for _ = 1, limit do
		if has_any_marker(dir, markers) then
			return dir
		end
		local parent = dirname(dir)
		if parent == dir then
			break
		end
		dir = parent
	end
	return nil
end

---@param request_text string
---@return table<string, string>|nil
local function parse_project_request_args(request_text)
	local req_lines = split_lines(request_text or "")
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
local function build_system_backend_lines(path, query, project_root)
	local bazel_markers = { "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE" }
	local gradle_markers = { "gradlew", "settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle" }
	local root = (type(project_root) == "string" and project_root ~= "") and project_root or dirname(path)

	if query == "c-family" then
		if has_any_marker(root, bazel_markers) then
			return { "ROOT\t" .. root, "SYSTEM\tbazel" }
		end
		if has_any_marker(root, { "meson.build" }) then
			local ready = filereadable(vim.fs.joinpath(root, "build", "build.ninja"))
				or filereadable(vim.fs.joinpath(root, "build", "meson-private", "coredata.dat"))
			return { "ROOT\t" .. root, "SYSTEM\tmeson", "BUILD_READY\t" .. (ready and "1" or "0") }
		end
		if has_any_marker(root, { "CMakeLists.txt" }) then
			local ready = filereadable(vim.fs.joinpath(root, "build", "CMakeCache.txt"))
			return { "ROOT\t" .. root, "SYSTEM\tcmake", "BUILD_READY\t" .. (ready and "1" or "0") }
		end
		if filereadable(vim.fs.joinpath(root, "Makefile")) then
			return { "ROOT\t" .. root, "SYSTEM\tmake" }
		end
		return { "ROOT\t" .. root }
	end

	if query == "bazel-root" then
		if has_any_marker(root, bazel_markers) then
			return { "ROOT\t" .. root, "SYSTEM\tbazel" }
		end
		local found = find_root_for_markers(path, bazel_markers, 12)
		if found then
			return { "ROOT\t" .. found, "SYSTEM\tbazel" }
		end
		return {}
	end

	if query == "jvm-root" then
		if filereadable(vim.fs.joinpath(root, "pom.xml")) then
			return { "ROOT\t" .. root, "SYSTEM\tmaven" }
		end
		if has_any_marker(root, gradle_markers) then
			return { "ROOT\t" .. root, "SYSTEM\tgradle" }
		end
		local jvm_markers = {
			"pom.xml",
			"gradlew",
			"settings.gradle.kts",
			"settings.gradle",
			"build.gradle.kts",
			"build.gradle",
		}
		local found = find_root_for_markers(path, jvm_markers, 12)
		if found then
			if filereadable(vim.fs.joinpath(found, "pom.xml")) then
				return { "ROOT\t" .. found, "SYSTEM\tmaven" }
			end
			return { "ROOT\t" .. found, "SYSTEM\tgradle" }
		end
	end

	return {}
end

---@param cmd string[]|string
---@param prefix string
---@param default string|boolean|nil
---@return string|boolean|nil
local function parse_backend_flag(cmd, prefix, default)
	if type(cmd) ~= "table" then
		return default
	end
	for _, arg in ipairs(cmd) do
		if type(arg) == "string" and arg:sub(1, #prefix) == prefix then
			return arg:sub(#prefix + 1)
		end
	end
	return default
end

---@param cmd string[]|string
---@param prefix string
---@param default boolean
---@return boolean
local function parse_backend_bool(cmd, prefix, default)
	local value = parse_backend_flag(cmd, prefix, nil)
	if value == nil then
		return default
	end
	return value == "1" or value == "true"
end

---@param line string
---@return string|nil
local function canonicalize_diag(line)
	local trimmed = line:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^%-%->%s*", "")
	local path, row, col, msg = trimmed:match("^([^:]+):(%d+):(%d+):%s*(.+)$")
	if path and row and col then
		return string.format("%s:%d:%d: %s", path, tonumber(row), tonumber(col), msg ~= "" and msg or "diagnostic")
	end

	local path0, row0, col0 = trimmed:match("^([^:]+):(%d+):(%d+)$")
	if path0 and row0 and col0 then
		return string.format("%s:%d:%d: diagnostic", path0, tonumber(row0), tonumber(col0))
	end

	local path2, row2, msg2 = trimmed:match("^([^:]+):(%d+):%s*(.+)$")
	if path2 and row2 then
		return string.format("%s:%d:%d: %s", path2, tonumber(row2), 1, msg2 ~= "" and msg2 or "diagnostic")
	end

	local path3, row3, col3, msg3 = trimmed:match("^(.+)%((%d+):(%d+)%)%s*(.*)$")
	if path3 and row3 and col3 then
		local normalized = msg3 ~= "" and msg3 or "diagnostic"
		return string.format("%s:%d:%d: %s", path3, tonumber(row3), tonumber(col3), normalized)
	end

	return nil
end

---@param input string
---@param cmd string[]
---@return string[]
function M.simulate_quickfix_backend(input, cmd)
	local lines = split_lines(input or "")
	local max_lines = tonumber(parse_backend_flag(cmd, "--max-lines=", "1000")) or 1000
	local max_bytes = tonumber(parse_backend_flag(cmd, "--max-bytes=", "262144")) or 262144
	local strip_ansi = parse_backend_bool(cmd, "--strip-ansi=", true)
	local strip_max_lines = tonumber(parse_backend_flag(cmd, "--strip-max-lines=", "400")) or 400
	local parse_diagnostics = parse_backend_bool(cmd, "--parse-diagnostics=", true)

	if max_lines < 1 then
		max_lines = 1
	end
	if max_bytes < 1 then
		max_bytes = 1
	end

	local truncated = false
	local used = 0
	local start_idx = #lines + 1
	for index = #lines, 1, -1 do
		used = used + #lines[index] + 1
		if used > max_bytes then
			truncated = true
			break
		end
		start_idx = index
	end

	if #lines > 0 then
		if start_idx > #lines then
			lines = { lines[#lines] }
		elseif start_idx > 1 then
			---@type string[]
			local sliced = {}
			for index = start_idx, #lines do
				table.insert(sliced, lines[index])
			end
			lines = sliced
		end
	end

	if #lines > max_lines then
		truncated = true
		---@type string[]
		local sliced = {}
		for index = #lines - max_lines + 1, #lines do
			table.insert(sliced, lines[index])
		end
		lines = sliced
	end

	if strip_ansi and strip_max_lines > 0 then
		local strip_start_idx = math.max(1, #lines - strip_max_lines + 1)
		for index = strip_start_idx, #lines do
			lines[index] = lines[index]:gsub("\27%[[0-9;]*m", "")
		end
	end

	if parse_diagnostics then
		for index = 1, #lines do
			local normalized = canonicalize_diag(lines[index])
			if normalized then
				lines[index] = normalized
			end
		end
	end

	if truncated then
		table.insert(lines, 1, "[zignite] quickfix output truncated")
	end

	return lines
end

---@param cmd string[]|string
---@return boolean
function M.is_quickfix_daemon_cmd(cmd)
	if type(cmd) ~= "table" then
		return false
	end
	for _, arg in ipairs(cmd) do
		if arg == "--quickfix-daemon" or arg == "--daemon" then
			return true
		end
	end
	return false
end

---@param cmd string[]|string
---@return boolean
function M.is_detect_daemon_cmd(cmd)
	if type(cmd) ~= "table" then
		return false
	end
	for _, arg in ipairs(cmd) do
		if arg == "--detect-daemon" or arg == "--daemon" then
			return true
		end
	end
	return false
end

---@param cmd string[]|string
---@return boolean
function M.is_project_daemon_cmd(cmd)
	if type(cmd) ~= "table" then
		return false
	end
	for _, arg in ipairs(cmd) do
		if arg == "--project-parse-daemon" or arg == "--daemon" then
			return true
		end
	end
	return false
end

---@param cmd string[]|string
---@return boolean
function M.is_unified_daemon_cmd(cmd)
	if type(cmd) ~= "table" then
		return false
	end
	for _, arg in ipairs(cmd) do
		if arg == "--daemon" then
			return true
		end
	end
	return false
end

---@param cmd string[]|string
---@return boolean
function M.is_quickfix_backend_cmd(cmd)
	if type(cmd) ~= "table" then
		return false
	end
	for _, arg in ipairs(cmd) do
		if arg == "--quickfix" or arg == "--quickfix-daemon" then
			return true
		end
	end
	return false
end

---@param request_text string
---@return string[]|nil
function M.parse_daemon_request(request_text)
	local req_lines = split_lines(request_text or "")
	if #req_lines < 2 then
		return nil
	end

	local begin_line = req_lines[1]
	local request_id, max_lines, max_bytes, strip_ansi, strip_max_lines, parse_diagnostics =
		begin_line:match("^@@ZQF_BEGIN%s+(%d+)%s+(%d+)%s+(%d+)%s+([01])%s+(%d+)%s+([01])$")
	if not request_id then
		return nil
	end

	local end_line = req_lines[#req_lines]
	local end_id = end_line:match("^@@ZQF_END%s+(%d+)$")
	if not end_id or tonumber(end_id) ~= tonumber(request_id) then
		return nil
	end

	---@type string[]
	local payload_lines = {}
	for index = 2, #req_lines - 1 do
		local line = req_lines[index]
		if line:sub(1, 1) == "\t" then
			payload_lines[#payload_lines + 1] = line:sub(2)
		else
			payload_lines[#payload_lines + 1] = line
		end
	end

	local cmd = {
		"--quickfix",
		"--max-lines=" .. max_lines,
		"--max-bytes=" .. max_bytes,
		"--strip-ansi=" .. strip_ansi,
		"--strip-max-lines=" .. strip_max_lines,
		"--parse-diagnostics=" .. parse_diagnostics,
	}

	local backend_lines = M.simulate_quickfix_backend(table.concat(payload_lines, "\n"), cmd)
	local response = { "@@ZQF_RES_BEGIN " .. request_id }
	for _, line in ipairs(backend_lines) do
		response[#response + 1] = "\t" .. line
	end
	response[#response + 1] = "@@ZQF_RES_END " .. request_id
	return response
end

---@param request_text string
---@return string[]|nil
function M.parse_detect_daemon_request(request_text)
	local req_lines = split_lines(request_text or "")
	if #req_lines < 2 then
		return nil
	end

	local begin_line = req_lines[1]
	local request_id, tool = begin_line:match("^@@ZDET_REQ_BEGIN%s+(%d+)%s+([%w_%-]+)$")
	if not request_id or not tool then
		return nil
	end

	local end_line = req_lines[#req_lines]
	local end_id = end_line:match("^@@ZDET_REQ_END%s+(%d+)$")
	if not end_id or tonumber(end_id) ~= tonumber(request_id) then
		return nil
	end

	local response = { "@@ZDET_RES_BEGIN " .. request_id }
	local commands = M.detect_backend_tool_commands[tool] or {}
	for _, command in ipairs(commands) do
		response[#response + 1] = "\t" .. command
	end
	response[#response + 1] = "@@ZDET_RES_END " .. request_id
	return response
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
		local system_lines = build_system_backend_lines(args.path or "", "jvm-root", args["project-root"])
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
			and build_system_backend_lines(args.path or "", args.query, args["project-root"])
		or (args.kind == "cmake" and build_cmake_backend_lines(dirname(args.path or "")))
		or (args.kind == "meson" and build_meson_backend_lines(dirname(args.path or "")))
		or (args.kind == "cargo-auto" and (M.project_backend_lines.cargo or {}))
		or (args.kind == "bazel-workspace" and (M.project_backend_lines.bazel or {}))
		or jvm_auto_lines
		or (M.project_backend_lines[args.kind] or {})
	for _, line in ipairs(lines) do
		response[#response + 1] = "\t" .. line
	end
	response[#response + 1] = "@@ZPRJ_RES_END " .. args.request_id
	return response
end

---@param request_text string
---@return string[]|nil
function M.parse_unified_daemon_request(request_text)
	local begin_line = split_lines(request_text or "")[1] or ""
	if begin_line:match("^@@ZQF_BEGIN%s+") then
		return M.parse_daemon_request(request_text)
	end
	if begin_line:match("^@@ZDET_REQ_BEGIN%s+") then
		return M.parse_detect_daemon_request(request_text)
	end
	if begin_line:match("^@@ZPRJ_REQ_BEGIN%s+") then
		return M.parse_project_daemon_request(request_text)
	end
	return nil
end

---@param cmd string[]|string
---@return string[]|nil
function M.simulated_tool_help_output(cmd)
	if type(cmd) ~= "table" or type(cmd[1]) ~= "string" then
		return nil
	end

	if cmd[2] == "--detect" and type(cmd[3]) == "string" then
		local tool = cmd[3]:match("^%-%-tool=(.+)$")
		if tool then
			return M.detect_backend_tool_commands[tool] or {}
		end
	end

	if cmd[1] == "zig" and cmd[2] == "--help" then
		return {
			"Usage: zig [command] [options]",
			"",
			"Commands:",
			"",
			"  build            Build project from build.zig",
			"  fetch            Copy a package into global cache and print its hash",
			"  fmt              Reformat Zig source into canonical form",
			"  run              Create executable and run immediately",
			"",
			"General Options:",
			"  -h, --help       Print command-specific usage",
		}
	end

	if cmd[1] == "go" and cmd[2] == "help" then
		return {
			"The commands are:",
			"",
			"    build       compile packages and dependencies",
			"    env         print Go environment information",
			"    fmt         gofmt package sources",
			"",
			"Additional help topics:",
		}
	end

	if cmd[1] == "cargo" and cmd[2] == "--list" then
		return {
			"Installed Commands:",
			"    build      Compile a local package and all of its dependencies",
			"    check      Analyze the current package and report errors",
			"    run        Run a binary or example of the local package",
		}
	end

	if cmd[1] == "odin" and cmd[2] == "help" then
		return {
			"Commands:",
			"  build      Build an Odin package",
			"  run        Build and run an Odin package",
			"  test       Build and run tests for an Odin package",
			"Flags:",
		}
	end

	return nil
end

return M
