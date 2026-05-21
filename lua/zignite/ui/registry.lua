---@class ZigniteUiRunner
---@field win_id integer
---@field buf_id integer
---@field job_id integer|nil

---@type table
local M = {}

---@type ZigniteUiRunner[]
local runners = {}

---@param win_id integer
---@param buf_id integer
---@return ZigniteUiRunner
function M.track(win_id, buf_id)
	---@type ZigniteUiRunner
	local runner = { win_id = win_id, buf_id = buf_id, job_id = nil }
	table.insert(runners, runner)
	return runner
end

---@param index integer
---@return nil
local function remove_runner(index)
	table.remove(runners, index)
end

---@param index integer
---@param stop_job boolean
---@return nil
local function close_at_index(index, stop_job)
	local runner = runners[index]
	if not runner then
		return
	end

	if stop_job and type(vim.fn.jobstop) == "function" then
		local job_id = runner.job_id
		if type(job_id) == "number" and job_id > 0 then
			pcall(vim.fn.jobstop, job_id)
		end
	end

	if vim.api.nvim_win_is_valid(runner.win_id) then
		pcall(vim.api.nvim_win_close, runner.win_id, true)
	end
	if vim.api.nvim_buf_is_valid(runner.buf_id) then
		pcall(vim.api.nvim_buf_delete, runner.buf_id, { force = true })
	end

	remove_runner(index)
end

---@param win_id integer
---@param stop_job boolean
---@return boolean
function M.close_by_win_id(win_id, stop_job)
	for idx, runner in ipairs(runners) do
		if runner.win_id == win_id then
			close_at_index(idx, stop_job)
			return true
		end
	end
	return false
end

---@return nil
function M.clean_invalid()
	---@type ZigniteUiRunner[]
	local valid = {}
	for _, runner in ipairs(runners) do
		if vim.api.nvim_win_is_valid(runner.win_id) then
			table.insert(valid, runner)
		elseif vim.api.nvim_buf_is_valid(runner.buf_id) then
			pcall(vim.api.nvim_buf_delete, runner.buf_id, { force = true })
		end
	end
	runners = valid
end

---@param stop_jobs boolean
---@return nil
function M.close_all(stop_jobs)
	for idx = #runners, 1, -1 do
		close_at_index(idx, stop_jobs)
	end
	runners = {}
end

return M
