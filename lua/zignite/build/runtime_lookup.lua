local config = require("zignite.config")
local backend = require("zignite.build.project_query")
local commands = require("zignite.build.command_policy")
local state = require("zignite.build.cache_state")
local systems = require("zignite.build.system_runtime")

---@type table
local M = {}

local DIRECT_DETECT_FLAGS = {
	go = "go",
	odin = "odin",
	rust = "rust",
	zig = "zig",
}

local C_FAMILY_FILETYPES = {
	c = true,
	cpp = true,
}

local JS_FILETYPES = {
	javascript = true,
	typescript = true,
}

local JVM_FILETYPES = {
	java = true,
	kotlin = true,
}

local PYTHON_FILETYPES = {
	python = true,
}

local BAZEL_FILETYPES = {
	bazel = true,
	bzl = true,
}

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

---@param filetype string
---@return boolean
local function is_c_family(filetype)
	return C_FAMILY_FILETYPES[filetype] == true
end

---@param filetype string
---@return boolean
local function is_js_like(filetype)
	return JS_FILETYPES[filetype] == true
end

---@param filetype string
---@return boolean
local function is_jvm_filetype(filetype)
	return JVM_FILETYPES[filetype] == true
end

---@param filetype string
---@return boolean
local function is_python_filetype(filetype)
	return PYTHON_FILETYPES[filetype] == true
end

---@param filetype string
---@return boolean
local function is_bazel_filetype(filetype)
	return BAZEL_FILETYPES[filetype] == true
end

---@param filetype string
---@return boolean
local function uses_cached_detect_async(filetype)
	return is_c_family(filetype)
		or is_jvm_filetype(filetype)
		or is_python_filetype(filetype)
		or is_bazel_filetype(filetype)
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
local function get_cached_build_commands(filetype, filepath)
	local cache_key = detect_runtime_cache_key(filetype, filepath)
	local mtime_signature = systems.get_mtime_signature_for_filetype(filetype, filepath, is_detection_enabled)
	local entry = state.get_bounded_cache_entry(
		state.detect_runtime_cache,
		state.detect_runtime_cache_order,
		cache_key
	)
	local cached_commands = {}
	if type(entry) == "table" and type(entry.commands) == "table" then
		cached_commands = state.copy_string_map(entry.commands)
	end
	return cached_commands, entry, cache_key, mtime_signature
end

---@param cache_key string
---@param build_commands table<string, string>
---@param status string
---@param mtime_signature string|nil
---@return nil
local function store_detect_runtime_entry(cache_key, build_commands, status, mtime_signature)
	local updated_at_ms = state.now_ms()
	if status == "failed" then
		updated_at_ms = updated_at_ms - (state.DETECT_RUNTIME_FAILED_TTL_MS + 1)
	end

	state.set_bounded_cache_entry(
		state.detect_runtime_cache,
		state.detect_runtime_cache_order,
		state.DETECT_RUNTIME_CACHE_MAX,
		cache_key,
		{
			commands = state.copy_string_map(build_commands),
			updated_at_ms = updated_at_ms,
			mtime_signature = mtime_signature,
			status = status,
		}
	)
end

---@param filetype string
---@param filepath string
---@param cached_commands table<string, string>
---@return table<string, string>
local function get_refresh_fallback_commands(filetype, filepath, cached_commands)
	if next(cached_commands or {}) ~= nil then
		return state.copy_string_map(cached_commands)
	end
	return commands.merge_build_commands_cached(filetype, filepath, {})
end

---@param filetype string
---@param resolved_commands table<string, string>|nil
---@return table<string, string>
local function merge_backend_refresh_commands(filetype, resolved_commands)
	local merged = commands.detect_direct_tool_commands_for_filetype(filetype, is_detection_enabled)
	for key, value in pairs(resolved_commands or {}) do
		if type(key) == "string" and type(value) == "string" then
			merged[key] = value
		end
	end
	return merged
end

---@param cache_key string
---@param merged_commands table<string, string>
---@return nil
local function flush_detect_runtime_callbacks(cache_key, merged_commands)
	local pending_callbacks = state.detect_runtime_inflight[cache_key]
	state.detect_runtime_inflight[cache_key] = nil
	if not pending_callbacks or type(pending_callbacks.callbacks) ~= "table" then
		return
	end
	for _, callback in ipairs(pending_callbacks.callbacks) do
		if type(callback) == "function" then
			pcall(callback, state.copy_string_map(merged_commands))
		end
	end
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

	local cached_commands, entry, cache_key, mtime_signature = get_cached_build_commands(filetype, filepath)
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

	local fallback_commands = get_refresh_fallback_commands(filetype, filepath, cached_commands)
	if commands.can_resolve_backend_build_commands(filetype, filepath) and DIRECT_DETECT_FLAGS[filetype] == nil then
		if commands.resolve_backend_build_commands_async(filetype, filepath, function(resolved)
			if type(resolved) == "table" and type(resolved.commands) == "table" and next(resolved.commands) ~= nil then
				local merged_commands = merge_backend_refresh_commands(filetype, resolved.commands)
				store_detect_runtime_entry(cache_key, merged_commands, "ready", mtime_signature)
				flush_detect_runtime_callbacks(cache_key, merged_commands)
				return
			end
			store_detect_runtime_entry(cache_key, fallback_commands, "failed", mtime_signature)
			flush_detect_runtime_callbacks(cache_key, fallback_commands)
		end) then
			return true
		end
	end

	local latest_commands = fallback_commands
	local latest_status = "ready"
	local latest_mtime_signature = mtime_signature
	local pending = 1
	local detect_async = commands.detect_tool_commands_for_filetype_async
	local merge_build_commands = uses_cached_detect_async(filetype) and commands.merge_build_commands_cached
		or commands.merge_build_commands

	local function complete_refresh()
		pending = pending - 1
		if pending > 0 then
			return
		end

		store_detect_runtime_entry(cache_key, latest_commands, latest_status, latest_mtime_signature)
		flush_detect_runtime_callbacks(cache_key, latest_commands)
	end

	pending = pending + 1
	if not systems.prime_system_detection_async(filetype, filepath, is_detection_enabled, function()
		latest_mtime_signature = systems.get_mtime_signature_for_filetype(filetype, filepath, is_detection_enabled)
		complete_refresh()
	end) then
		pending = pending - 1
	end

	if is_c_family(filetype) then
		detect_async = commands.detect_tool_commands_for_filetype_async_cached
		pending = pending + 1
		if not backend.prime_c_family_project_commands_async(filepath, function()
			latest_commands = merge_build_commands(
				filetype,
				filepath,
				commands.collect_sync_detected_commands_cached(filetype, filepath, is_detection_enabled)
			)
			latest_status = "ready"
			latest_mtime_signature = systems.get_mtime_signature_for_filetype(filetype, filepath, is_detection_enabled)
			complete_refresh()
		end) then
			pending = pending - 1
		end
	elseif uses_cached_detect_async(filetype) then
		detect_async = commands.detect_tool_commands_for_filetype_async_cached
	end

	detect_async(
		filetype,
		filepath,
		function(detected_commands)
			if detected_commands == nil then
				latest_status = "failed"
				latest_commands = fallback_commands
			else
				latest_status = "ready"
				latest_commands = merge_build_commands(filetype, filepath, detected_commands)
			end
			complete_refresh()
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
	return commands.select_live_command_name(build_cmds)
end

---@param filetype string
---@param filepath string
---@param build_cmds table<string, string>
---@return string|nil
function M.select_live_command_name_for_filetype(filetype, filepath, build_cmds)
	return commands.select_live_command_name_for_filetype(filetype, filepath, build_cmds, is_detection_enabled)
end

---@param filetype string
---@return boolean
function M.can_detect_build_commands_for_filetype(filetype)
	local direct_flag = DIRECT_DETECT_FLAGS[filetype]
	if direct_flag and is_detection_enabled(direct_flag) then
		return true
	end
	if is_c_family(filetype) and is_detection_enabled("c_cpp_make") then
		return true
	end
	if is_js_like(filetype) and is_detection_enabled("js_package_scripts") then
		return true
	end
	if is_jvm_filetype(filetype) and is_detection_enabled("java_kotlin_project") then
		return true
	end
	if is_python_filetype(filetype) then
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
	local backend_resolved = commands.resolve_backend_build_commands(filetype, filepath)
	if backend_resolved then
		local direct_commands = commands.detect_direct_tool_commands_for_filetype(filetype, is_detection_enabled)
		local merged = state.copy_string_map(direct_commands)
		for key, value in pairs(backend_resolved.commands or {}) do
			if type(key) == "string" and type(value) == "string" then
				merged[key] = value
			end
		end
		return merged
	end

	local detected_commands = commands.detect_tool_commands_for_filetype(
		filetype,
		filepath,
		is_detection_enabled
	)
	return commands.merge_build_commands(filetype, filepath, detected_commands)
end

---@param filetype string
---@param filepath string
---@param on_refresh fun(commands: table<string, string>):nil
---@return table<string, string>, boolean
function M.get_build_commands_for_cached_lookup(filetype, filepath, on_refresh)
	local cached_commands = get_cached_build_commands(filetype, filepath)
	local immediate_commands = next(cached_commands) ~= nil and cached_commands
		or commands.merge_build_commands_cached(filetype, filepath, {})
	local refresh_started = request_build_command_refresh(filetype, filepath, on_refresh)
	return immediate_commands, refresh_started
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
	return commands.get_preferred_project_command(filetype, filepath)
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
