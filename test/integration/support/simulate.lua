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
		"COMMAND\tbuild\tmake",
		"COMMAND\tbench\tmake bench",
		"COMMAND\ttest\tmake test",
	},
	["make-auto"] = {
		"COMMAND\tbuild\tmake",
		"COMMAND\tbench\tmake bench",
		"COMMAND\ttest\tmake test",
	},
	["package-json"] = {
		"COMMAND\tinstall\tnpm install",
		"COMMAND\tdev\tnpm run dev",
		"COMMAND\tlive\tnpm run dev",
		"COMMAND\tbuild\tnpm run build",
	},
	["package-json-auto"] = {
		"COMMAND\tinstall\tnpm install",
		"COMMAND\tdev\tnpm run dev",
		"COMMAND\tlive\tnpm run dev",
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
	["bazel-auto"] = {
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
---@return string[]|nil
local function read_file_lines_direct(path)
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local contents = file:read("*a")
	file:close()
	if type(contents) ~= "string" then
		return nil
	end
	return split_lines(contents)
end

---@param path string
---@return string
local function dirname(path)
	return vim.fn.fnamemodify(path, ":h")
end

---@param path string
---@return boolean
local function filereadable(path)
	if type(vim.fn.filereadable) == "function" and vim.fn.filereadable(path) == 1 then
		return true
	end
	local file = io.open(path, "r")
	if file then
		file:close()
		return true
	end
	return false
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
			local build_command = ready and "meson compile -C build" or "meson setup build && meson compile -C build"
			local clean_command = ready and "meson compile -C build --clean" or "cmake -E rm -rf build"
			return {
				"ROOT\t" .. root,
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
		if has_any_marker(root, { "CMakeLists.txt" }) then
			local ready = filereadable(vim.fs.joinpath(root, "build", "CMakeCache.txt"))
			local build_command = ready and "cmake --build build"
				or "cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build"
			local clean_command = ready and "cmake --build build --target clean" or "cmake -E rm -rf build"
			local debug_command = "cmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1"
				.. " && cmake --build build"
			local release_command = "cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1"
				.. " && cmake --build build"
			return {
				"ROOT\t" .. root,
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
			if filereadable(vim.fs.joinpath(root, "Makefile")) then
				return {
					"ROOT\t" .. root,
					"SYSTEM\tmake",
					"COMMAND\tbuild\tmake",
				}
			end
		return { "ROOT\t" .. root }
	end

	if query == "bazel-root" then
		if has_any_marker(root, bazel_markers) then
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
		local found = find_root_for_markers(path, bazel_markers, 12)
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
		local found = has_any_marker(root, markers) and root or find_root_for_markers(path, markers, 12)
		if not found then
			return {}
		end
		local manager = "npm"
		if filereadable(vim.fs.joinpath(found, "bun.lockb")) or filereadable(vim.fs.joinpath(found, "bun.lock")) then
			manager = "bun"
		elseif filereadable(vim.fs.joinpath(found, "pnpm-lock.yaml")) then
			manager = "pnpm"
		elseif filereadable(vim.fs.joinpath(found, "yarn.lock")) then
			manager = "yarn"
		end
		local start_command = manager == "bun" and "bun run start"
			or manager == "yarn" and "yarn start"
			or manager == "pnpm" and "pnpm start"
			or "npm start"
		local dev_command = manager == "bun" and "bun run dev"
			or manager == "yarn" and "yarn dev"
			or manager == "pnpm" and "pnpm run dev"
			or "npm run dev"
		local build_command = manager == "bun" and "bun run build"
			or manager == "yarn" and "yarn build"
			or manager == "pnpm" and "pnpm run build"
			or "npm run build"
		local test_command = manager == "bun" and "bun run test"
			or manager == "yarn" and "yarn test"
			or manager == "pnpm" and "pnpm test"
			or "npm test"
		local install_command = manager == "bun" and "bun install"
			or manager == "yarn" and "yarn install"
			or manager == "pnpm" and "pnpm install"
			or "npm install"
		return {
			"ROOT\t" .. found,
			"SYSTEM\tnode",
			"COMMAND\tstart\t" .. start_command,
			"COMMAND\tdev\t" .. dev_command,
			"COMMAND\tbuild\t" .. build_command,
			"COMMAND\ttest\t" .. test_command,
			"COMMAND\tinstall\t" .. install_command,
		}
	end

	if query == "python-root" then
		local markers = { "pyproject.toml", "uv.lock" }
		local found = has_any_marker(root, markers) and root or find_root_for_markers(path, markers, 12)
		if not found then
			return {}
		end
		local pyproject_payload = read_file_lines_direct(vim.fs.joinpath(found, "pyproject.toml"))
		local uses_uv = filereadable(vim.fs.joinpath(found, "uv.lock"))
			or (type(pyproject_payload) == "table" and vim.tbl_contains(pyproject_payload, "[tool.uv]"))
		local lines = {
			"ROOT\t" .. found,
			"SYSTEM\tpython",
		}
		if uses_uv then
			lines[#lines + 1] = "COMMAND\trun\tuv run -m main"
			lines[#lines + 1] = "COMMAND\ttest\tuv run pytest"
			lines[#lines + 1] = "COMMAND\tinstall\tuv sync"
		end
		return lines
	end

	if query == "jvm-root" then
		if filereadable(vim.fs.joinpath(root, "pom.xml")) then
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
		if has_any_marker(root, gradle_markers) then
			local gradle_prefix = filereadable(vim.fs.joinpath(root, "gradlew")) and "./gradlew" or "gradle"
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
		local found = find_root_for_markers(path, jvm_markers, 12)
		if found then
			if filereadable(vim.fs.joinpath(found, "pom.xml")) then
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
			local gradle_prefix = filereadable(vim.fs.joinpath(found, "gradlew")) and "./gradlew" or "gradle"
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
local function build_c_family_auto_lines(path, project_root)
	local system_lines = build_system_backend_lines(path, "c-family", project_root)
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
		local root = detected_root or dirname(path)
		local lines = vim.deepcopy(system_lines)
		for _, line in ipairs(build_cmake_backend_lines(root)) do
			lines[#lines + 1] = line
		end
		return lines
	end
	if detected_system == "meson" then
		local root = detected_root or dirname(path)
		local lines = vim.deepcopy(system_lines)
		for _, line in ipairs(build_meson_backend_lines(root)) do
			lines[#lines + 1] = line
		end
		return lines
	end

	return system_lines
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

---@param request_text string
---@param begin_marker string
---@param end_marker string
---@return table<string, string>|nil
local function parse_flag_request_args(request_text, begin_marker, end_marker)
	local req_lines = split_lines(request_text or "")
	if #req_lines < 3 then
		return nil
	end

	local begin_line = req_lines[1]
	local request_id = begin_line:match("^" .. begin_marker .. "%s+(%d+)$")
	if not request_id then
		return nil
	end

	local end_line = req_lines[#req_lines]
	local end_id = end_line:match("^" .. end_marker .. "%s+(%d+)$")
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
	return args
end

---@param lines string[]
---@return table, table, table
local function decode_build_resolve_lines(lines)
	local meta = {}
	local commands = {}
	local preferred = {}
	for _, line in ipairs(lines or {}) do
		local kind, name, value = line:match("^([^\t]+)\t([^\t]+)\t(.+)$")
		if kind == "COMMAND" then
			commands[name] = value
		elseif kind == "PREFERRED" then
			preferred[name] = value
		else
			kind, value = line:match("^([^\t]+)\t(.+)$")
			if kind == "ROOT" then
				meta.root = value
			elseif kind == "SYSTEM" then
				meta.system = value
			elseif kind == "BUILD_READY" then
				meta.build_ready = value
			end
		end
	end
	return meta, commands, preferred
end

---@param preferred table<string, string>
---@param commands table<string, string>
---@return nil
local function append_implicit_preferred(preferred, commands)
	for _, key in ipairs({ "build", "run", "live", "test", "clean" }) do
		if preferred[key] == nil and type(commands[key]) == "string" then
			preferred[key] = commands[key]
		end
	end
end

---@param value string|nil
---@return string
local function trim_text(value)
	return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param value string
---@return string
local function quote_shell_arg(value)
	return "'" .. tostring(value or ""):gsub("'", "'\"'\"'") .. "'"
end

---@param command string
---@return boolean
local function command_requires_arguments(command)
	return type(command) == "string" and command:find("$zignite_args", 1, true) ~= nil
end

---@param command string
---@return string
local function command_display(command)
	return tostring(command or ""):gsub("%$zignite_args", "<args>")
end

---@param filetype string
---@param command_name string
---@return string
local function command_arg_prompt(filetype, command_name)
	if filetype == "zig" and command_name == "fetch" then
		return "zig fetch url/path"
	end
	return string.format("%s %s args", filetype, command_name)
end

---@param filetype string
---@param command_name string
---@return string
local function command_arg_help(filetype, command_name)
	if filetype == "zig" and command_name == "fetch" then
		return "Paste GitHub URL only | Enter: run | Esc: cancel | Backspace: edit"
	end
	return "Type arguments | Enter: run | Esc: cancel | Backspace: edit"
end

---@param value string
---@return string
local function normalize_github_repo_reference(value)
	local trimmed = trim_text(value)
	if trimmed == "" or trimmed:match("^%-%-") then
		return trimmed
	end

	local shorthand_repo, shorthand_ref = trimmed:match("^([%w%._%-]+/[%w%._%-]+)#(.+)$")
	if shorthand_repo then
		return string.format("--save git+https://github.com/%s#%s", shorthand_repo:gsub("%.git$", ""), shorthand_ref)
	end

	local shorthand = trimmed:match("^([%w%._%-]+/[%w%._%-]+)$")
	if shorthand then
		return string.format("--save git+https://github.com/%s", shorthand:gsub("%.git$", ""))
	end

	local url_repo, url_ref = trimmed:match("^https?://github%.com/([%w%._%-]+/[%w%._%-]+)[/#]?tree/?(.+)$")
	if url_repo then
		return string.format("--save git+https://github.com/%s#%s", url_repo:gsub("%.git$", ""), url_ref)
	end

	local url_plain = trimmed:match("^https?://github%.com/([%w%._%-]+/[%w%._%-]+)/*$")
	if url_plain then
		return string.format("--save git+https://github.com/%s", url_plain:gsub("%.git$", ""))
	end

	if trimmed:match("^git%+https://github%.com/") then
		return "--save " .. trimmed
	end

	return trimmed
end

---@param filetype string
---@param command_name string
---@param template string
---@param command_args string|nil
---@return string|nil
local function resolve_command_template(filetype, command_name, template, command_args)
	if not command_requires_arguments(template) then
		return template
	end

	local trimmed = trim_text(command_args)
	if trimmed == "" then
		return nil
	end

	local replacement
	if filetype == "zig" and command_name == "fetch" then
		replacement = normalize_github_repo_reference(trimmed)
	else
		replacement = quote_shell_arg(trimmed)
	end

	return template:gsub("%$zignite_args", replacement)
end

---@param path string
---@param cwd string|nil
---@param shell_escape boolean
---@return string
local function substitute_runner_variables(template, path, cwd, shell_escape)
	local file = path
	local dir = dirname(path)
	local file_name = vim.fn.fnamemodify(path, ":t")
	local file_name_without_ext = vim.fn.fnamemodify(path, ":t:r")
	local file_ext = vim.fn.fnamemodify(path, ":e")
	local root = cwd or dir
	local dir_name = vim.fn.fnamemodify(root, ":t")

	local replacements = {
		["%%"] = file,
		["$dir"] = dir,
		["$file"] = file,
		["$fileName"] = file_name,
		["$fileNameWithoutExt"] = file_name_without_ext,
		["$fileExt"] = file_ext,
		["$dirName"] = dir_name,
	}

	local result = tostring(template or "")
	for key, value in pairs(replacements) do
		local replacement = shell_escape and quote_shell_arg(value) or value
		result = result:gsub(key:gsub("%%", "%%%%"), replacement)
	end
	return result
end

---@param command string
---@return boolean
local function has_unsupported_shell_syntax(command)
	if type(command) ~= "string" or command == "" then
		return true
	end
	return command:find("[`|;&<>]") ~= nil
		or command:find("%$%(") ~= nil
		or command:find("%$[%a_][%w_]*") ~= nil
		or command:find("%$%b{}") ~= nil
end

---@param command string
---@return string[]
local function tokenize_command(command)
	if has_unsupported_shell_syntax(command) then
		return {}
	end

	local tokens = {}
	local i = 1
	local len = #command
	while i <= len do
		while i <= len and command:sub(i, i):match("%s") do
			i = i + 1
		end
		if i > len then
			break
		end

		local ch = command:sub(i, i)
		if ch == "'" or ch == '"' then
			local quote = ch
			local j = i + 1
			while j <= len and command:sub(j, j) ~= quote do
				j = j + 1
			end
			if j > len then
				return {}
			end
			tokens[#tokens + 1] = command:sub(i + 1, j - 1)
			i = j + 1
		else
			local j = i
			while j <= len and not command:sub(j, j):match("%s") do
				j = j + 1
			end
			tokens[#tokens + 1] = command:sub(i, j - 1)
			i = j
		end
	end

	return tokens
end

---@param filetype string
---@param name string
---@param configured string
---@param commands table<string, string>
---@return boolean
local function should_overlay_configured_command(filetype, name, configured, commands)
	if type(commands[name]) ~= "string" then
		return true
	end
	local config = require("zignite.config")
	local defaults = type(config.defaults.build_commands) == "table" and config.defaults.build_commands[filetype] or nil
	if type(defaults) ~= "table" then
		return true
	end
	return defaults[name] ~= configured
end

---@param filetype string
---@param path string
---@param project_root string|nil
---@param include_configured boolean|nil
---@return string[]
local function collect_build_resolve_lines(filetype, path, project_root, include_configured)
	local lines = {}
	if filetype == "c" or filetype == "cpp" then
		lines = build_c_family_auto_lines(path, project_root)
	elseif filetype == "rust" then
		lines = M.project_backend_lines.cargo or {}
	elseif filetype == "go" then
		lines = M.project_backend_lines.go or {}
	elseif filetype == "java" or filetype == "kotlin" then
		local system_lines = build_system_backend_lines(path, "jvm-root", project_root)
		local detected_system = nil
		for _, line in ipairs(system_lines) do
			detected_system = line:match("^SYSTEM\t(.+)$") or detected_system
		end
		if detected_system == "maven" then
			lines = M.project_backend_lines.maven or {}
		elseif detected_system == "gradle" then
			lines = M.project_backend_lines.gradle or {}
		else
			lines = system_lines
		end
	elseif filetype == "javascript" or filetype == "typescript" then
		local system_lines = build_system_backend_lines(path, "node-root", project_root)
		if #system_lines > 0 then
			lines = vim.deepcopy(system_lines)
			for _, line in ipairs(M.project_backend_lines["package-json-auto"] or {}) do
				lines[#lines + 1] = line
			end
		end
	elseif filetype == "python" then
		lines = build_system_backend_lines(path, "python-root", project_root)
	elseif filetype == "bzl" then
		lines = M.project_backend_lines["bazel-auto"] or {}
	end

	local config = require("zignite.config")
	local configured = include_configured ~= false
		and type(config.options.build_commands) == "table"
		and config.options.build_commands[filetype]
		or nil
	if type(configured) == "table" then
		local meta, commands, preferred = decode_build_resolve_lines(lines)
		for name, command in pairs(configured) do
			if should_overlay_configured_command(filetype, name, command, commands) then
				commands[name] = command
			end
		end

		local merged = {}
		if type(meta.root) == "string" then
			merged[#merged + 1] = "ROOT\t" .. meta.root
		end
		if type(meta.system) == "string" then
			merged[#merged + 1] = "SYSTEM\t" .. meta.system
		end
		if type(meta.build_ready) == "string" then
			merged[#merged + 1] = "BUILD_READY\t" .. meta.build_ready
		end
		for name, command in pairs(commands) do
			merged[#merged + 1] = string.format("COMMAND\t%s\t%s", name, command)
		end
		for name, command in pairs(preferred) do
			merged[#merged + 1] = string.format("PREFERRED\t%s\t%s", name, command)
		end
		return merged
	end

	return lines
end

---@param request_text string
---@return string[]|nil
local function parse_config_daemon_request(request_text)
	local req_lines = split_lines(request_text or "")
	if #req_lines < 2 then
		return nil
	end
	local begin_line = req_lines[1]
	local request_id = begin_line:match("^@@ZCFG_REQ_BEGIN%s+(%d+)%s+%d+$")
	if not request_id then
		return nil
	end
	local end_line = req_lines[#req_lines]
	local end_id = end_line:match("^@@ZCFG_REQ_END%s+(%d+)$")
	if not end_id or tonumber(end_id) ~= tonumber(request_id) then
		return nil
	end
	return {
		"@@ZCFG_RES_BEGIN " .. request_id,
		"@@ZCFG_RES_END " .. request_id,
	}
end

---@param request_text string
---@return string[]|nil
local function parse_build_resolve_daemon_request(request_text)
	local args = parse_flag_request_args(request_text, "@@ZBR_REQ_BEGIN", "@@ZBR_REQ_END")
	if not args or not args.path or not args.filetype then
		return nil
	end

	local config = require("zignite.config")
	local response = { "@@ZBR_RES_BEGIN " .. args.request_id }
	local lines = collect_build_resolve_lines(args.filetype, args.path, args["project-root"], true)
	local meta, commands, preferred = decode_build_resolve_lines(lines)
	append_implicit_preferred(preferred, commands)

	if type(args["command-name"]) == "string" and args["command-name"] ~= "" then
		local command_name = args["command-name"]
		local command_template = commands[command_name]
		if type(command_template) == "string" and command_template ~= "" then
			local resolved = resolve_command_template(
				args.filetype,
				command_name,
				command_template,
				args["command-args"]
			)
			if type(resolved) == "string" and resolved ~= "" then
				response[#response + 1] = "\tFILETYPE\t" .. args.filetype
				response[#response + 1] = "\tCWD\t" .. (meta.root or dirname(args.path))
				response[#response + 1] = "\tNAME\t" .. string.format("%s: %s", args.filetype, command_name)
				response[#response + 1] = "\tEXEC_COMMAND\t" .. resolved
			end
		end
	else
		for _, line in ipairs(lines) do
			response[#response + 1] = "\t" .. line
			local kind, name, value = line:match("^([^\t]+)\t([^\t]+)\t(.+)$")
			if kind == "COMMAND" then
				response[#response + 1] = "\tCOMMAND_DISPLAY\t" .. name .. "\t" .. command_display(value)
				if command_requires_arguments(value) then
					response[#response + 1] = "\tCOMMAND_ARGS_REQUIRED\t" .. name .. "\t1"
					response[#response + 1] = "\tCOMMAND_ARG_PROMPT\t" .. name .. "\t" .. command_arg_prompt(args.filetype, name)
					response[#response + 1] = "\tCOMMAND_ARG_HELP\t" .. name .. "\t" .. command_arg_help(args.filetype, name)
				end
			end
		end
		for name, command in pairs(preferred) do
			response[#response + 1] = "\tPREFERRED\t" .. name .. "\t" .. command
		end
	end
	response[#response + 1] = "\tCONFIG_REVISION\t" .. tostring(config.revision or 0)
	response[#response + 1] = "@@ZBR_RES_END " .. args.request_id
	return response
end

---@param runner any
---@return string|nil, string|nil, string|nil
local function parse_runner_value(runner)
	if type(runner) == "string" and runner ~= "" then
		return runner, nil, nil
	end
	if type(runner) ~= "table" then
		return nil, nil, nil
	end
	if type(runner.cmd) == "string" and runner.cmd ~= "" then
		return runner.cmd, runner.cleanup_command, runner.cwd
	end
	if type(runner.cmd) == "table" and #runner.cmd > 0 then
		return table.concat(runner.cmd, " && "), runner.cleanup_command, runner.cwd
	end
	if #runner > 0 then
		return table.concat(runner, " && "), nil, nil
	end
	return nil, nil, nil
end

---@param request_text string
---@return string[]|nil
local function parse_run_resolve_daemon_request(request_text)
	local args = parse_flag_request_args(request_text, "@@ZRUN_REQ_BEGIN", "@@ZRUN_REQ_END")
	if not args or not args.path or not args.filetype then
		return nil
	end

	local config = require("zignite.config")
	local defaults = config.defaults or {}
	local options = config.options or {}
	local filetype = args.filetype
	local filepath = args.path
	local project_root = args["project-root"]
	local resolved_build_lines = collect_build_resolve_lines(filetype, filepath, project_root, false)
	local meta, commands, preferred = decode_build_resolve_lines(resolved_build_lines)

	local response = { "@@ZRUN_RES_BEGIN " .. args.request_id }
	local runner = type(options.runners) == "table" and options.runners[filetype] or nil
	local default_runner = type(defaults.runners) == "table" and defaults.runners[filetype] or nil

	if filetype == "zig" then
		local root = meta.root or project_root or find_root_for_markers(filepath, { "build.zig" }, 12)
		if type(root) == "string" and filereadable(vim.fs.joinpath(root, "build.zig")) then
			response[#response + 1] = "\tCOMMAND\tzig build run"
			response[#response + 1] = "\tARGV\tzig"
			response[#response + 1] = "\tARGV\tbuild"
			response[#response + 1] = "\tARGV\trun"
			response[#response + 1] = "\tSOURCE\tproject"
			response[#response + 1] = "\tFILETYPE\t" .. filetype
			response[#response + 1] = "\tCONFIG_REVISION\t" .. tostring(config.revision or 0)
			response[#response + 1] = "\tCWD\t" .. root
			response[#response + 1] = "\tNAME\tZig Project"
			response[#response + 1] = "@@ZRUN_RES_END " .. args.request_id
			return response
		end
	end

	local command, cleanup_command, cwd = parse_runner_value(runner)
	if type(command) == "string" and filetype == "python" and command == default_runner then
		local project_run = preferred.run or commands.run
		if type(project_run) == "string" and project_run:match("^uv run ") then
			command = project_run
		end
	end
	if type(command) == "string" and filetype == "go" and command == default_runner then
		local project_run = preferred.run or commands.run
		if type(project_run) == "string" and project_run ~= "" then
			command = project_run
			cwd = cwd or "$dir"
		end
	end

	if type(command) == "string" and command ~= "" then
		local resolved_command = substitute_runner_variables(command, filepath, cwd, true)
		local argv = tokenize_command(substitute_runner_variables(command, filepath, cwd, false))
		response[#response + 1] = "\tCOMMAND\t" .. resolved_command
		for _, arg in ipairs(argv) do
			response[#response + 1] = "\tARGV\t" .. arg
		end
		response[#response + 1] = "\tSOURCE\tfiletype"
		response[#response + 1] = "\tFILETYPE\t" .. filetype
		response[#response + 1] = "\tCONFIG_REVISION\t" .. tostring(config.revision or 0)
		if type(cleanup_command) == "string" and cleanup_command ~= "" then
			response[#response + 1] = "\tCLEANUP_COMMAND\t" .. substitute_runner_variables(cleanup_command, filepath, cwd, true)
		end
		if type(cwd) == "string" and cwd ~= "" then
			response[#response + 1] = "\tCWD\t" .. substitute_runner_variables(cwd, filepath, nil, false)
		end
		response[#response + 1] = "\tNAME\t" .. filetype
		response[#response + 1] = "@@ZRUN_RES_END " .. args.request_id
		return response
	end

	local project_run = preferred.run or commands.run or preferred.live or commands.live or commands.build
	if type(project_run) == "string" and project_run ~= "" then
		response[#response + 1] = "\tCOMMAND\t" .. project_run
		for _, arg in ipairs(tokenize_command(project_run)) do
			response[#response + 1] = "\tARGV\t" .. arg
		end
		response[#response + 1] = "\tSOURCE\tproject"
		response[#response + 1] = "\tFILETYPE\t" .. filetype
		response[#response + 1] = "\tCONFIG_REVISION\t" .. tostring(config.revision or 0)
		if type(meta.root) == "string" and meta.root ~= "" then
			response[#response + 1] = "\tCWD\t" .. meta.root
		end
		response[#response + 1] = "\tNAME\t" .. (filetype:gsub("^%l", string.upper) .. " Project")
	end

	response[#response + 1] = "@@ZRUN_RES_END " .. args.request_id
	return response
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
		or (args.kind == "c-family-auto" and build_c_family_auto_lines(args.path or "", args["project-root"]))
		or (args.kind == "cmake" and build_cmake_backend_lines(dirname(args.path or "")))
		or (args.kind == "meson" and build_meson_backend_lines(dirname(args.path or "")))
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

---@param request_text string
---@return string[]|nil
function M.parse_unified_daemon_request(request_text)
	local begin_line = split_lines(request_text or "")[1] or ""
	if begin_line:match("^@@ZCFG_REQ_BEGIN%s+") then
		return parse_config_daemon_request(request_text)
	end
	if begin_line:match("^@@ZBR_REQ_BEGIN%s+") then
		return parse_build_resolve_daemon_request(request_text)
	end
	if begin_line:match("^@@ZRUN_REQ_BEGIN%s+") then
		return parse_run_resolve_daemon_request(request_text)
	end
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
