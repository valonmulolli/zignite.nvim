local config = require("zignite.config")
local detect = require("zignite.build_detect")
local utils = require("zignite.utils")

---@type table
local M = {}

local DETECT_RUNTIME_DEFAULT_TTL_MS = 15000
local DETECT_RUNTIME_FAILED_TTL_MS = 1000
local PACKAGE_SCRIPT_CACHE_MAX = 128
local MAKE_TARGET_CACHE_MAX = 128
local DETECT_RUNTIME_CACHE_MAX = 256
local LIVE_COMMAND_PRIORITY = { "live", "dev", "watch", "serve", "start", "preview" }

---@type table<string, string>
local last_build_command_by_filetype = {}
---@type table<string, table>
local package_script_cache = {}
---@type string[]
local package_script_cache_order = {}
---@type table<string, table>
local make_target_cache = {}
---@type string[]
local make_target_cache_order = {}
---@type table<string, table>
local detect_runtime_cache = {}
---@type string[]
local detect_runtime_cache_order = {}
---@type table<string, table>
local detect_runtime_inflight = {}

---@param value string
---@return string
local function trim_text(value)
	if type(value) ~= "string" then
		return ""
	end
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param order string[]
---@param key string
---@return nil
local function touch_cache_key(order, key)
	for index, existing in ipairs(order) do
		if existing == key then
			table.remove(order, index)
			break
		end
	end
	order[#order + 1] = key
end

---@param cache table<string, any>
---@param order string[]
---@param max_entries integer
---@param key string
---@param value any
---@return nil
local function set_bounded_cache_entry(cache, order, max_entries, key, value)
	if type(key) ~= "string" or key == "" then
		return
	end
	cache[key] = value
	touch_cache_key(order, key)
	while #order > max_entries do
		local oldest = table.remove(order, 1)
		if oldest ~= nil then
			cache[oldest] = nil
		end
	end
end

---@param cache table<string, any>
---@param order string[]
---@param key string
---@return any
local function get_bounded_cache_entry(cache, order, key)
	local value = cache[key]
	if value ~= nil and type(key) == "string" and key ~= "" then
		touch_cache_key(order, key)
	end
	return value
end

---@return number
local function now_ms()
	local uv = vim.uv or vim.loop
	if uv and type(uv.hrtime) == "function" then
		return uv.hrtime() / 1e6
	end
	return os.clock() * 1000
end

---@param tbl table<string, string>|nil
---@return table<string, string>
local function copy_string_map(tbl)
	---@type table<string, string>
	local out = {}
	if type(tbl) ~= "table" then
		return out
	end
	for key, value in pairs(tbl) do
		if type(key) == "string" and type(value) == "string" then
			out[key] = value
		end
	end
	return out
end

---@param path string
---@return string|nil
local function get_file_mtime_key(path)
	local uv = vim.uv or vim.loop
	if not uv or type(uv.fs_stat) ~= "function" then
		return nil
	end
	local stat = uv.fs_stat(path)
	if not stat then
		return nil
	end
	local mtime = stat.mtime or {}
	return string.format("%s:%s:%s", tostring(stat.size or 0), tostring(mtime.sec or 0), tostring(mtime.nsec or 0))
end

---@param filepath string
---@return string
local function resolve_project_root_for_detection(filepath)
	local root = utils.get_project_root(filepath, config.options.project)
	if root and root ~= "" then
		return vim.fs.normalize(root)
	end
	return vim.fs.normalize(vim.fn.fnamemodify(filepath, ":h"))
end

---@param filetype string
---@param filepath string
---@return string
local function detect_runtime_cache_key(filetype, filepath)
	return string.format("%s::%s", tostring(filetype or ""), resolve_project_root_for_detection(filepath))
end

---@param path string
---@return string
local function detect_file_signature(path)
	if type(vim.fn.filereadable) ~= "function" or vim.fn.filereadable(path) ~= 1 then
		return "missing"
	end
	return get_file_mtime_key(path) or "unknown"
end

---@param filetype string
---@param filepath string
---@return string|nil
local function get_mtime_signature_for_filetype(filetype, filepath)
	local root = resolve_project_root_for_detection(filepath)

	if filetype == "c" or filetype == "cpp" then
		return "makefile:" .. detect_file_signature(vim.fs.joinpath(root, "Makefile"))
	end
	if filetype == "javascript" or filetype == "typescript" then
		return "package.json:" .. detect_file_signature(vim.fs.joinpath(root, "package.json"))
	end
	if filetype == "java" or filetype == "kotlin" then
		local signatures = {
			"pom.xml:" .. detect_file_signature(vim.fs.joinpath(root, "pom.xml")),
			"gradlew:" .. detect_file_signature(vim.fs.joinpath(root, "gradlew")),
			"build.gradle:" .. detect_file_signature(vim.fs.joinpath(root, "build.gradle")),
			"build.gradle.kts:" .. detect_file_signature(vim.fs.joinpath(root, "build.gradle.kts")),
		}
		return table.concat(signatures, "|")
	end

	local tool_name = nil
	if filetype == "zig" then
		tool_name = "zig"
	elseif filetype == "go" then
		tool_name = "go"
	elseif filetype == "rust" then
		tool_name = "cargo"
	elseif filetype == "odin" then
		tool_name = "odin"
	end

	if tool_name then
		local executable_path = nil
		if type(vim.fn.exepath) == "function" then
			local resolved = vim.fn.exepath(tool_name)
			if type(resolved) == "string" and resolved ~= "" then
				executable_path = resolved
			end
		end
		if executable_path then
			return string.format(
				"tool:%s:%s:%s",
				tool_name,
				executable_path,
				get_file_mtime_key(executable_path) or "unknown"
			)
		end
		return "tool:" .. tool_name
	end

	return nil
end

---@param entry table|nil
---@param ttl_ms number
---@param mtime_signature string|nil
---@return boolean
local function is_cache_stale(entry, ttl_ms, mtime_signature)
	if type(entry) ~= "table" then
		return true
	end
	if mtime_signature ~= nil and entry.mtime_signature ~= mtime_signature then
		return true
	end
	local updated_at_ms = tonumber(entry.updated_at_ms) or 0
	local effective_ttl_ms = ttl_ms
	if entry.status == "failed" then
		effective_ttl_ms = math.min(ttl_ms, DETECT_RUNTIME_FAILED_TTL_MS)
	end
	return (now_ms() - updated_at_ms) > effective_ttl_ms
end

---@param payload string
---@return table<string, string|number|boolean|table|nil>|nil
local function decode_json_payload(payload)
	if type(payload) ~= "string" or payload == "" then
		return nil
	end
	if vim.json and type(vim.json.decode) == "function" then
		local ok, decoded = pcall(vim.json.decode, payload)
		if ok then
			return decoded
		end
	end
	if vim.fn and type(vim.fn.json_decode) == "function" then
		local ok, decoded = pcall(vim.fn.json_decode, payload)
		if ok then
			return decoded
		end
	end
	return nil
end

---@param flag string
---@return boolean
local function is_detection_enabled(flag)
	local detect_options = config.options.detect or {}
	local value = detect_options[flag]
	if value == nil then
		return true
	end
	return value == true
end

---@param lines string[]|nil
---@return table<string, string>
local function parse_makefile_targets(lines)
	---@type table<string, string>
	local commands = {}
	for _, raw_line in ipairs(lines or {}) do
		local line = tostring(raw_line or "")
		if line:match("^%s*$") or line:match("^%s*#") then
			goto continue
		end
		if line:match("^\t") then
			goto continue
		end
		if line:match("^%s*[%w%._%-]+%s*[:+?]?=") then
			goto continue
		end
		local target_segment = line:match("^%s*([^:]+)%s*:")
		if not target_segment then
			goto continue
		end
		for raw_target in target_segment:gmatch("%S+") do
			local target = trim_text(raw_target)
			if
				target ~= ""
				and target ~= "|"
				and not target:match("^%.")
				and not target:find("%%", 1, true)
				and not target:find("%$%(", 1, true)
			then
				commands[target] = "make " .. target
			end
		end
		::continue::
	end
	return commands
end

---@param filepath string
---@return table<string, string>
local function detect_makefile_targets(filepath)
	if not filepath or filepath == "" then
		return {}
	end
	if type(vim.fn.filereadable) ~= "function" or type(vim.fn.readfile) ~= "function" then
		return {}
	end

	local root = utils.get_project_root(filepath, config.options.project)
	if not root then
		root = vim.fn.fnamemodify(filepath, ":h")
	end
	local makefile_path = vim.fs.joinpath(root, "Makefile")
	if vim.fn.filereadable(makefile_path) ~= 1 then
		return {}
	end

	local mtime_key = get_file_mtime_key(makefile_path)
	local cached = get_bounded_cache_entry(make_target_cache, make_target_cache_order, makefile_path)
	if cached and cached.mtime_key == mtime_key then
		return copy_string_map(cached.commands)
	end

	local lines = vim.fn.readfile(makefile_path)
	if type(lines) ~= "table" then
		set_bounded_cache_entry(make_target_cache, make_target_cache_order, MAKE_TARGET_CACHE_MAX, makefile_path, {
			mtime_key = mtime_key,
			commands = {},
		})
		return {}
	end

	local commands = parse_makefile_targets(lines)
	set_bounded_cache_entry(make_target_cache, make_target_cache_order, MAKE_TARGET_CACHE_MAX, makefile_path, {
		mtime_key = mtime_key,
		commands = copy_string_map(commands),
	})
	return commands
end

---@param filepath string
---@return table<string, string>
local function detect_package_scripts(filepath)
	if not filepath or filepath == "" then
		return {}
	end
	if type(vim.fn.filereadable) ~= "function" or type(vim.fn.readfile) ~= "function" then
		return {}
	end

	local root = utils.get_project_root(filepath, config.options.project)
	if not root then
		root = vim.fn.fnamemodify(filepath, ":h")
	end
	local package_json_path = vim.fs.joinpath(root, "package.json")
	if vim.fn.filereadable(package_json_path) ~= 1 then
		return {}
	end

	local mtime_key = get_file_mtime_key(package_json_path)
	local cached = get_bounded_cache_entry(package_script_cache, package_script_cache_order, package_json_path)
	if cached and cached.mtime_key == mtime_key then
		return copy_string_map(cached.commands)
	end

	local lines = vim.fn.readfile(package_json_path)
	if type(lines) ~= "table" or #lines == 0 then
		set_bounded_cache_entry(
			package_script_cache,
			package_script_cache_order,
			PACKAGE_SCRIPT_CACHE_MAX,
			package_json_path,
			{
				mtime_key = mtime_key,
				commands = {},
			}
		)
		return {}
	end

	local parsed = decode_json_payload(table.concat(lines, "\n"))
	local scripts = parsed and parsed.scripts
	---@type table<string, string>
	local commands = {}
	if type(scripts) == "table" then
		for script_name, script_value in pairs(scripts) do
			if type(script_name) == "string" and type(script_value) == "string" then
				if script_name == "start" then
					commands.start = "npm start"
				elseif script_name == "test" then
					commands.test = "npm test"
				else
					commands[script_name] = "npm run " .. script_name
				end
			end
		end
	end

	set_bounded_cache_entry(
		package_script_cache,
		package_script_cache_order,
		PACKAGE_SCRIPT_CACHE_MAX,
		package_json_path,
		{
			mtime_key = mtime_key,
			commands = copy_string_map(commands),
		}
	)
	return commands
end

---@param filepath string
---@return table<string, string>
local function detect_java_like_project_commands(filepath)
	if not filepath or filepath == "" or type(vim.fn.filereadable) ~= "function" then
		return {}
	end

	---@param start_path string
	---@param candidates string[]
	---@param max_up integer
	---@return string|nil
	local function find_root_for_files(start_path, candidates, max_up)
		local dir = vim.fn.fnamemodify(start_path, ":h")
		local limit = max_up or 10
		for _ = 1, limit do
			for _, file_name in ipairs(candidates) do
				if vim.fn.filereadable(vim.fs.joinpath(dir, file_name)) == 1 then
					return dir
				end
			end
			local parent = vim.fn.fnamemodify(dir, ":h")
			if parent == dir then
				break
			end
			dir = parent
		end
		return nil
	end

	local root = utils.get_project_root(filepath, config.options.project)
	if not root then
		root = find_root_for_files(filepath, { "pom.xml", "gradlew", "build.gradle", "build.gradle.kts" }, 12)
			or vim.fn.fnamemodify(filepath, ":h")
	end

	---@type table<string, string>
	local commands = {}
	local pom_xml = vim.fs.joinpath(root, "pom.xml")
	local gradle_wrapper = vim.fs.joinpath(root, "gradlew")
	local gradle_build = vim.fs.joinpath(root, "build.gradle")
	local gradle_build_kts = vim.fs.joinpath(root, "build.gradle.kts")

	if vim.fn.filereadable(pom_xml) == 1 then
		commands["mvn-build"] = "mvn compile"
		commands["mvn-test"] = "mvn test"
		commands["mvn-package"] = "mvn package"
		commands["mvn-run"] = "mvn exec:java"
	end
	if vim.fn.filereadable(gradle_wrapper) == 1 then
		commands["gradle-build"] = "./gradlew build"
		commands["gradle-test"] = "./gradlew test"
		commands["gradle-clean"] = "./gradlew clean"
		commands["gradle-run"] = "./gradlew run"
	elseif vim.fn.filereadable(gradle_build) == 1 or vim.fn.filereadable(gradle_build_kts) == 1 then
		commands["gradle-build"] = "gradle build"
		commands["gradle-test"] = "gradle test"
		commands["gradle-clean"] = "gradle clean"
		commands["gradle-run"] = "gradle run"
	end
	return commands
end

---@param filetype string
---@param filepath string
---@return table<string, string>
local function detect_tool_commands_for_filetype(filetype, filepath)
	if filetype == "zig" and is_detection_enabled("zig") then
		return detect.detect_zig_tool_commands()
	end
	if filetype == "go" and is_detection_enabled("go") then
		return detect.detect_go_tool_commands()
	end
	if filetype == "rust" and is_detection_enabled("rust") then
		return detect.detect_rust_tool_commands()
	end
	if filetype == "odin" and is_detection_enabled("odin") then
		return detect.detect_odin_tool_commands()
	end
	if (filetype == "c" or filetype == "cpp") and is_detection_enabled("c_cpp_make") then
		return detect_makefile_targets(filepath)
	end
	if (filetype == "javascript" or filetype == "typescript") and is_detection_enabled("js_package_scripts") then
		return detect_package_scripts(filepath)
	end
	if (filetype == "java" or filetype == "kotlin") and is_detection_enabled("java_kotlin_project") then
		return detect_java_like_project_commands(filepath)
	end
	return {}
end

---@param filetype string
---@param filepath string
---@param on_done fun(commands: table<string, string>|nil):nil
---@param force_refresh boolean|nil
---@return nil
local function detect_tool_commands_for_filetype_async(filetype, filepath, on_done, force_refresh)
	if filetype == "zig" and is_detection_enabled("zig") then
		detect.detect_zig_tool_commands_async(on_done, force_refresh)
		return
	end
	if filetype == "go" and is_detection_enabled("go") then
		detect.detect_go_tool_commands_async(on_done, force_refresh)
		return
	end
	if filetype == "rust" and is_detection_enabled("rust") then
		detect.detect_rust_tool_commands_async(on_done, force_refresh)
		return
	end
	if filetype == "odin" and is_detection_enabled("odin") then
		detect.detect_odin_tool_commands_async(on_done, force_refresh)
		return
	end
	if (filetype == "c" or filetype == "cpp") and is_detection_enabled("c_cpp_make") then
		vim.schedule(function()
			on_done(detect_makefile_targets(filepath))
		end)
		return
	end
	if (filetype == "javascript" or filetype == "typescript") and is_detection_enabled("js_package_scripts") then
		vim.schedule(function()
			on_done(detect_package_scripts(filepath))
		end)
		return
	end
	if (filetype == "java" or filetype == "kotlin") and is_detection_enabled("java_kotlin_project") then
		vim.schedule(function()
			on_done(detect_java_like_project_commands(filepath))
		end)
		return
	end
	on_done({})
end

---@param filetype string
---@param detected table<string, string>|nil
---@return table<string, string>
local function merge_build_commands(filetype, detected)
	local merged = copy_string_map(detected)
	local configured = config.options.build_commands[filetype] or {}
	for key, value in pairs(configured) do
		if type(key) == "string" and type(value) == "string" then
			merged[key] = value
		end
	end
	return merged
end

---@param filetype string
---@param filepath string
---@return table<string, string>, table|nil, string, string|nil
local function get_cached_detected_commands(filetype, filepath)
	local cache_key = detect_runtime_cache_key(filetype, filepath)
	local mtime_signature = get_mtime_signature_for_filetype(filetype, filepath)
	local entry = get_bounded_cache_entry(detect_runtime_cache, detect_runtime_cache_order, cache_key)
	local cached_detected = {}
	if type(entry) == "table" and type(entry.commands) == "table" then
		cached_detected = copy_string_map(entry.commands)
	end
	return cached_detected, entry, cache_key, mtime_signature
end

---@param filetype string
---@param filepath string
---@param on_refresh fun(commands: table<string, string>):nil
---@return boolean
local function request_build_command_refresh(filetype, filepath, on_refresh)
	local runtime_opts = M.get_detect_runtime_options()
	if not M.can_detect_build_commands_for_filetype(filetype) then
		return false
	end

	local cached_detected, entry, cache_key, mtime_signature = get_cached_detected_commands(filetype, filepath)
	if not is_cache_stale(entry, runtime_opts.cache_ttl_ms, mtime_signature) then
		return false
	end

	local inflight = detect_runtime_inflight[cache_key]
	if inflight then
		if type(on_refresh) == "function" then
			table.insert(inflight.callbacks, on_refresh)
		end
		return true
	end

	detect_runtime_inflight[cache_key] = {
		callbacks = type(on_refresh) == "function" and { on_refresh } or {},
	}

	detect_tool_commands_for_filetype_async(filetype, filepath, function(detected_commands)
		local status = "ready"
		local updated_at_ms = now_ms()
		if detected_commands == nil then
			status = "failed"
			detected_commands = cached_detected
			updated_at_ms = updated_at_ms - (DETECT_RUNTIME_FAILED_TTL_MS + 1)
		end

		local detected_copy = copy_string_map(detected_commands)
		set_bounded_cache_entry(
			detect_runtime_cache,
			detect_runtime_cache_order,
			DETECT_RUNTIME_CACHE_MAX,
			cache_key,
			{
				commands = detected_copy,
				updated_at_ms = updated_at_ms,
				mtime_signature = mtime_signature,
				status = status,
			}
		)

		local merged_commands = merge_build_commands(filetype, detected_copy)
		local pending = detect_runtime_inflight[cache_key]
		detect_runtime_inflight[cache_key] = nil
		if not pending or type(pending.callbacks) ~= "table" then
			return
		end
		for _, callback in ipairs(pending.callbacks) do
			if type(callback) == "function" then
				pcall(callback, copy_string_map(merged_commands))
			end
		end
	end, true)

	return true
end

---@return table
function M.get_detect_runtime_options()
	local runtime = config.options.detect_runtime or {}
	local ttl = tonumber(runtime.cache_ttl_ms) or DETECT_RUNTIME_DEFAULT_TTL_MS
	if ttl <= 0 then
		ttl = DETECT_RUNTIME_DEFAULT_TTL_MS
	end
	return {
		async_picker = runtime.async_picker ~= false,
		cache_ttl_ms = ttl,
		live_merge = runtime.live_merge ~= false,
	}
end

---@param build_cmds table<string, string>
---@return string|nil
function M.select_live_command_name(build_cmds)
	for _, candidate in ipairs(LIVE_COMMAND_PRIORITY) do
		if build_cmds[candidate] then
			return candidate
		end
	end
	return nil
end

---@param filetype string
---@return boolean
function M.can_detect_build_commands_for_filetype(filetype)
	if filetype == "zig" and is_detection_enabled("zig") then
		return true
	end
	if filetype == "go" and is_detection_enabled("go") then
		return true
	end
	if filetype == "rust" and is_detection_enabled("rust") then
		return true
	end
	if filetype == "odin" and is_detection_enabled("odin") then
		return true
	end
	if (filetype == "c" or filetype == "cpp") and is_detection_enabled("c_cpp_make") then
		return true
	end
	if (filetype == "javascript" or filetype == "typescript") and is_detection_enabled("js_package_scripts") then
		return true
	end
	if (filetype == "java" or filetype == "kotlin") and is_detection_enabled("java_kotlin_project") then
		return true
	end
	return false
end

---@param filetype string
---@param filepath string
---@return table<string, string>
function M.get_build_commands_for_filetype(filetype, filepath)
	local detected_commands = detect_tool_commands_for_filetype(filetype, filepath)
	return merge_build_commands(filetype, detected_commands)
end

---@param filetype string
---@param filepath string
---@param on_refresh fun(commands: table<string, string>):nil
---@return table<string, string>, boolean
function M.get_build_commands_for_cached_lookup(filetype, filepath, on_refresh)
	local cached_detected = get_cached_detected_commands(filetype, filepath)
	local merged = merge_build_commands(filetype, cached_detected)
	local refresh_started = request_build_command_refresh(filetype, filepath, on_refresh)
	return merged, refresh_started
end

---@param filetype string
---@param filepath string
---@param on_refresh fun(commands: table<string, string>):nil
---@return table<string, string>
function M.get_build_commands_for_picker(filetype, filepath, on_refresh)
	local runtime_opts = M.get_detect_runtime_options()
	if runtime_opts.async_picker == false then
		return M.get_build_commands_for_filetype(filetype, filepath)
	end
	local merged = M.get_build_commands_for_cached_lookup(filetype, filepath, on_refresh)
	return merged
end

---@param filetype string
---@param command_name string
---@return nil
function M.set_last_build_command(filetype, command_name)
	if type(filetype) == "string" and filetype ~= "" and type(command_name) == "string" and command_name ~= "" then
		last_build_command_by_filetype[filetype] = command_name
	end
end

---@param filetype string
---@return string|nil
function M.get_last_build_command(filetype)
	return last_build_command_by_filetype[filetype]
end

---@return nil
function M.reset()
	last_build_command_by_filetype = {}
	package_script_cache = {}
	package_script_cache_order = {}
	make_target_cache = {}
	make_target_cache_order = {}
	detect_runtime_cache = {}
	detect_runtime_cache_order = {}
	detect_runtime_inflight = {}
end

---@return table
function M._debug_state()
	return {
		detect_runtime_cache = detect_runtime_cache,
		detect_runtime_cache_order = detect_runtime_cache_order,
	}
end

return M
