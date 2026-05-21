local build_resolve = require("zignite.rpc.build_resolve")
local run_resolve = require("zignite.rpc.run_resolve")
local picker_controller = require("zignite.ui.build_picker.controller")
local ui_common = require("zignite.ui.common")
local config = require("zignite.config")
local ui_windows = require("zignite.ui.windows")

---@type table
local M = {}

local ERRORS = {
	VISUAL_EMPTY = "Error: Visual selection is empty.",
}

local table_unpack = unpack or (type(table) == "table" and table.unpack)

---@return nil
local function ensure_config()
	config.ensure()
end

---@param requested_filetype string|nil
---@return string, string
local function resolve_current_source_context(requested_filetype)
	local filetype = tostring(requested_filetype or vim.bo.filetype or "")
	filetype = (filetype:gsub("^%s+", ""):gsub("%s+$", ""))
	return vim.fn.expand("%:p"), filetype
end

---@return string
local function get_visual_selection()
	local _, start_line, start_col = table_unpack(vim.fn.getpos("'<"))
	local _, end_line, end_col = table_unpack(vim.fn.getpos("'>"))
	if start_line == 0 or end_line == 0 then
		return ""
	end
	return table.concat(vim.api.nvim_buf_get_text(0, start_line - 1, start_col, end_line - 1, end_col, {}), "\n")
end

---@return string
local function get_buffer_contents()
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	return table.concat(lines, "\n")
end

---@param filepath string
---@param filetype string
---@param mode string
---@param action "named"|"live"|"last"
---@param command_name string|nil
---@param provided_args string|nil
---@return nil
local function run_build_action_for(filepath, filetype, mode, action, command_name, provided_args)
	local plan = build_resolve.resolve_action_interactive(
		filepath,
		filetype,
		action,
		action == "named" and command_name or nil,
		provided_args,
		function(prompt_plan, current_args)
			return ui_windows.prompt_required_argument(
				tostring(prompt_plan.resolved_command_name or "build"),
				prompt_plan.argument_prompt,
				mode,
				current_args,
				prompt_plan.argument_help
			)
		end
	)
	if type(plan) ~= "table" then
		return
	end
	if plan.ok ~= true and plan.reason == "cancelled" then
		return
	end
	if plan.ok ~= true or plan.system_argv == nil then
		ui_windows.show_output(tostring(plan.message or "Failed to resolve build command."), mode)
		return
	end

	M.execute_command(plan.system_argv, mode, plan.name or "build", {
		cwd = plan.cwd,
	})
end

---@param mode string
---@param action "named"|"live"|"last"
---@param command_name string|nil
---@param provided_args string|nil
---@return nil
local function run_current_build_action(mode, action, command_name, provided_args)
	ensure_config()
	local filepath, filetype = resolve_current_source_context()
	run_build_action_for(filepath, filetype, mode, action, command_name, provided_args)
end

---@param range integer
---@param mode string
---@return nil
function M.run_code(range, mode)
	ensure_config()

	local buffer_path, filetype = resolve_current_source_context()
	local current_buf = 0
	if type(vim.api) == "table" and type(vim.api.nvim_get_current_buf) == "function" then
		current_buf = tonumber(vim.api.nvim_get_current_buf()) or 0
	end

	local request = {
		path = buffer_path,
		filetype = filetype,
		context_path = buffer_path ~= "" and buffer_path or nil,
		buffer_id = current_buf,
	}
	if range > 0 then
		local code_to_run = get_visual_selection()
		if code_to_run == "" then
			ui_windows.show_output(ERRORS.VISUAL_EMPTY, mode)
			return
		end
		request.selection_text = code_to_run
	elseif buffer_path == "" then
		request.selection_text = get_buffer_contents()
	end

	local execution = run_resolve.resolve_sync_request(request)
	local resolved_filetype = execution.filetype or filetype
	if type(execution.system_argv) ~= "table" then
		ui_windows.show_output(
			tostring(execution.message or string.format("Failed to resolve runner for filetype: %s", resolved_filetype)),
			mode
		)
		return
	end
	local planned_execution_path = type(execution.execution_path) == "string" and execution.execution_path or request.path

	M.execute_command(execution.system_argv, mode, execution.name or resolved_filetype, {
		cwd = execution.cwd,
	})
end

---@param system_command string|string[]
---@param mode string
---@param display_name string
---@param exec_opts table|nil
---@return nil
function M.execute_command(system_command, mode, display_name, exec_opts)
	ensure_config()
	mode = ui_common.normalize_mode(mode)

	if mode == "float" then
		ui_windows.run_in_float_terminal(system_command, nil, display_name, exec_opts)
	else
		ui_windows.run_in_split_terminal(mode, system_command, nil, exec_opts)
	end
end

---@return nil
function M.stop_code()
	ui_windows.close_output(true)
	vim.notify("Runner stopped.", vim.log.levels.INFO)
end

---@param command_name string
---@param mode string
---@param provided_args string|nil
---@return nil
function M.run_build_command(command_name, mode, provided_args)
	run_current_build_action(mode, "named", command_name, provided_args)
end

---@param mode string
---@return nil
function M.run_live(mode)
	run_current_build_action(mode, "live", nil, nil)
end

---@param mode string
---@return nil
function M.select_build_command(mode)
	ensure_config()

	local filepath, filetype = resolve_current_source_context()
	picker_controller.open({
		filetype = filetype,
		filepath = filepath,
		mode = mode,
		config_options = config.options,
		detect_runtime_opts = config.options.detect_runtime or {},
		get_build_commands_for_picker = build_resolve.resolve_for_picker,
		run_build_command = function(command_name, picker_mode, provided_args)
			run_build_action_for(filepath, filetype, picker_mode, "named", command_name, provided_args)
		end,
		run_last_build_command = function(picker_mode)
			run_build_action_for(filepath, filetype, picker_mode, "last", nil, nil)
		end,
	})
end

---@param mode string
---@return nil
function M.run_last_build_command(mode)
	run_current_build_action(mode, "last", nil, nil)
end

---@return nil
function M.close_runner()
	ensure_config()
	local should_stop = ui_common.should_stop_on_close(nil)
	ui_windows.close_output(should_stop)
	if not should_stop then
		vim.notify("Runner closed (hide mode). Use :StopCode to terminate active jobs.", vim.log.levels.INFO)
	end
end

---@param opts table|nil
---@return nil
function M.setup(opts)
	ui_windows.reset()
	config.setup(opts)
end

return M
