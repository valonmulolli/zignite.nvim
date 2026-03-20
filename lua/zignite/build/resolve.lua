local config = require("zignite.config")
local state = require("zignite.build.state")
local systems = require("zignite.build.systems")
local targets = require("zignite.build.targets")

---@type table
local M = {}

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

---@param filetype string
---@param filepath string
---@return string
local function detect_runtime_cache_key(filetype, filepath)
	local normalized_path = systems.resolve_project_root_for_detection(filepath)
	return string.format("%s::%s", tostring(filetype or ""), normalized_path)
end

---@param entry table|nil
---@param ttl_ms number
---@param mtime_signature string|nil
---@return boolean
local function is_cache_stale(entry, ttl_ms, mtime_signature)
	if type(entry) ~= "table" then
		return true
	end
	if entry.status ~= "ready" and entry.status ~= "failed" then
		return true
	end
	local updated_at_ms = tonumber(entry.updated_at_ms)
	if not updated_at_ms then
		return true
	end
	local age_ms = state.now_ms() - updated_at_ms
	local effective_ttl_ms = entry.status == "failed" and state.DETECT_RUNTIME_FAILED_TTL_MS or ttl_ms
	if age_ms >= effective_ttl_ms then
		return true
	end
	if entry.mtime_signature ~= mtime_signature then
		return true
	end
	return false
end

---@param filetype string
---@param filepath string
---@return table<string, string>, table|nil, string, string|nil
local function get_cached_detected_commands(filetype, filepath)
	local cache_key = detect_runtime_cache_key(filetype, filepath)
	local mtime_signature = systems.get_mtime_signature_for_filetype(filetype, filepath, is_detection_enabled)
	local entry = state.get_bounded_cache_entry(
		state.detect_runtime_cache,
		state.detect_runtime_cache_order,
		cache_key
	)
	local cached_detected = {}
	if type(entry) == "table" and type(entry.commands) == "table" then
		cached_detected = state.copy_string_map(entry.commands)
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

	local inflight = state.detect_runtime_inflight[cache_key]
	if inflight then
		if type(on_refresh) == "function" then
			table.insert(inflight.callbacks, on_refresh)
		end
		return true
	end

	state.detect_runtime_inflight[cache_key] = {
		callbacks = type(on_refresh) == "function" and { on_refresh } or {},
	}

	targets.detect_tool_commands_for_filetype_async(
		filetype,
		filepath,
		function(detected_commands)
			local status = "ready"
			local updated_at_ms = state.now_ms()
			if detected_commands == nil then
				status = "failed"
				detected_commands = cached_detected
				updated_at_ms = updated_at_ms - (state.DETECT_RUNTIME_FAILED_TTL_MS + 1)
			end

			local detected_copy = state.copy_string_map(detected_commands)
			state.set_bounded_cache_entry(
				state.detect_runtime_cache,
				state.detect_runtime_cache_order,
				state.DETECT_RUNTIME_CACHE_MAX,
				cache_key,
				{
					commands = detected_copy,
					updated_at_ms = updated_at_ms,
					mtime_signature = mtime_signature,
					status = status,
				}
			)

			local merged_commands = targets.merge_build_commands(filetype, filepath, detected_copy)
			local pending = state.detect_runtime_inflight[cache_key]
			state.detect_runtime_inflight[cache_key] = nil
			if not pending or type(pending.callbacks) ~= "table" then
				return
			end
			for _, callback in ipairs(pending.callbacks) do
				if type(callback) == "function" then
					pcall(callback, state.copy_string_map(merged_commands))
				end
			end
		end,
		true,
		is_detection_enabled
	)

	return true
end

---@return table
function M.get_detect_runtime_options()
	local runtime_options = config.options.detect_runtime or {}
	local ttl = tonumber(runtime_options.cache_ttl_ms) or state.DETECT_RUNTIME_DEFAULT_TTL_MS
	if ttl <= 0 then
		ttl = state.DETECT_RUNTIME_DEFAULT_TTL_MS
	end
	return {
		async_picker = runtime_options.async_picker ~= false,
		cache_ttl_ms = ttl,
		live_merge = runtime_options.live_merge ~= false,
	}
end

---@param build_cmds table<string, string>
---@return string|nil
function M.select_live_command_name(build_cmds)
	return targets.select_live_command_name(build_cmds)
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
	if is_detection_enabled("bazel_project") and systems.supports_bazel_project_commands(filetype) then
		return true
	end
	return false
end

---@param filetype string
---@param filepath string
---@return table<string, string>
function M.get_build_commands_for_filetype(filetype, filepath)
	local detected_commands = targets.detect_tool_commands_for_filetype(
		filetype,
		filepath,
		is_detection_enabled
	)
	return targets.merge_build_commands(filetype, filepath, detected_commands)
end

---@param filetype string
---@param filepath string
---@param on_refresh fun(commands: table<string, string>):nil
---@return table<string, string>, boolean
function M.get_build_commands_for_cached_lookup(filetype, filepath, on_refresh)
	local cached_detected = get_cached_detected_commands(filetype, filepath)
	local merged = targets.merge_build_commands(filetype, filepath, cached_detected)
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
---@param filepath string
---@return table|nil
function M.get_preferred_project_command(filetype, filepath)
	return targets.get_preferred_project_command(filetype, filepath)
end

---@param filetype string
---@param command_name string
---@return nil
function M.set_last_build_command(filetype, command_name)
	state.set_last_build_command(filetype, command_name)
end

---@param filetype string
---@return string|nil
function M.get_last_build_command(filetype)
	return state.get_last_build_command(filetype)
end

---@return nil
function M.reset()
	state.reset()
end

---@return table
function M._debug_state()
	return state.debug_state()
end

return M
