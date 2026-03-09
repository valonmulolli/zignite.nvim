local spinner = require("zignite.ui.spinner")
local windows = require("zignite.ui.windows")

---@type table
local M = {}

M.close_output = windows.close_output
M.run_in_float_terminal = windows.run_in_float_terminal
M.run_in_split_terminal = windows.run_in_split_terminal
M.show_output = windows.show_output
M.start_title_spinner = spinner.start_title_spinner
M.stop_spinner = spinner.stop_spinner
M.set_exit_status = spinner.set_exit_status

return M
