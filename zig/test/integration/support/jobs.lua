---@type table
local M = {}

---@class IntegrationSupportContext
---@field state table
---@field job_results table[]
---@field quickfix_results table[]
---@field notify_results table[]
---@field mock_jobs table

---@param ctx IntegrationSupportContext
---@param simulation table
---@return function
function M.attach(ctx, simulation)
	local original_jobstart = vim.fn.jobstart
	local original_jobstop = vim.fn.jobstop
	local original_chansend = vim.fn.chansend
	local original_chanclose = vim.fn.chanclose
	local original_setqflist = vim.fn.setqflist
	local original_cmd = vim.cmd
	local original_schedule = vim.schedule
	local original_notify = vim.notify
	local original_log = vim.log

	---@param lines string[]
	---@return string[]
	local function to_stdout_payload(lines)
		---@type string[]
		local payload = {}
		for _, line in ipairs(lines or {}) do
			payload[#payload + 1] = tostring(line or "")
		end
		payload[#payload + 1] = ""
		return payload
	end

	vim.fn.jobstart = function(cmd, opts)
		local job_id = ctx.state.next_job_id
		ctx.state.next_job_id = ctx.state.next_job_id + 1
		table.insert(ctx.job_results, { cmd = cmd, opts = opts, job_id = job_id })
		ctx.mock_jobs[job_id] = { cmd = cmd, opts = opts, input = "" }

		if simulation.is_quickfix_backend_cmd(cmd)
			or simulation.is_unified_daemon_cmd(cmd)
			or simulation.is_detect_daemon_cmd(cmd)
			or simulation.is_project_daemon_cmd(cmd)
		then
			return job_id
		end

		local tool_lines = simulation.simulated_tool_help_output(cmd)
		if tool_lines then
			if opts.on_stdout then
				vim.defer_fn(function()
					opts.on_stdout(job_id, tool_lines)
				end, 10)
			end
			if opts.on_exit then
				local exit_code = ctx.state.next_exit_code
				vim.defer_fn(function()
					opts.on_exit(job_id, exit_code)
				end, 10)
			end
			return job_id
		end

		if opts.on_exit then
			local exit_code = ctx.state.next_exit_code
			vim.defer_fn(function()
				opts.on_exit(job_id, exit_code)
			end, 10)
		end
		return job_id
	end

	vim.fn.chansend = function(job_id, data)
		local job = ctx.mock_jobs[job_id]
		if not job then
			return 0
		end

		if type(data) == "table" then
			for _, part in ipairs(data) do
				job.input = job.input .. tostring(part)
			end
		else
			job.input = job.input .. tostring(data or "")
		end

		if simulation.is_unified_daemon_cmd(job.cmd) then
			local text = type(data) == "table" and table.concat(data) or tostring(data or "")
			if text:match("^@@ZQF_BEGIN%s+") then
				ctx.state.quickfix_daemon_request_count = ctx.state.quickfix_daemon_request_count + 1
				if ctx.state.next_quickfix_backend_exit_code ~= 0 then
					local exit_code = ctx.state.next_quickfix_backend_exit_code
					ctx.state.next_quickfix_backend_exit_code = 0
					if job.opts and job.opts.on_exit then
						vim.defer_fn(function()
							job.opts.on_exit(job_id, exit_code)
						end, 10)
					end
					return 1
				end
				if type(ctx.state.next_quickfix_backend_error) == "string" and ctx.state.next_quickfix_backend_error ~= "" then
					local request_id = text:match("^@@ZQF_BEGIN%s+(%d+)%s+")
					local error_message = ctx.state.next_quickfix_backend_error
					ctx.state.next_quickfix_backend_error = nil
					if request_id and job.opts and job.opts.on_stdout then
						local response = {
							"@@ZQF_RES_BEGIN " .. request_id,
							"@@ZQF_RES_ERR " .. request_id .. " " .. error_message,
							"@@ZQF_RES_END " .. request_id,
						}
						ctx.state.quickfix_backend_invocations = ctx.state.quickfix_backend_invocations + 1
						vim.defer_fn(function()
							job.opts.on_stdout(job_id, to_stdout_payload(response))
						end, 10)
					end
					return 1
				end

				local response = simulation.parse_unified_daemon_request(text)
				if response and job.opts and job.opts.on_stdout then
					ctx.state.quickfix_backend_invocations = ctx.state.quickfix_backend_invocations + 1
					vim.defer_fn(function()
						job.opts.on_stdout(job_id, to_stdout_payload(response))
					end, 10)
				end
				return 1
			end

			if text:match("^@@ZDET_REQ_BEGIN%s+") then
				ctx.state.detect_backend_request_count = ctx.state.detect_backend_request_count + 1
				if ctx.state.next_detect_backend_exit_code ~= 0 then
					local exit_code = ctx.state.next_detect_backend_exit_code
					ctx.state.next_detect_backend_exit_code = 0
					if job.opts and job.opts.on_exit then
						vim.defer_fn(function()
							job.opts.on_exit(job_id, exit_code)
						end, 10)
					end
					return 1
				end
				if type(ctx.state.next_detect_backend_error) == "string" and ctx.state.next_detect_backend_error ~= "" then
					local request_id = text:match("^@@ZDET_REQ_BEGIN%s+(%d+)%s+[%w_%-]+")
					local error_message = ctx.state.next_detect_backend_error
					ctx.state.next_detect_backend_error = nil
					if request_id and job.opts and job.opts.on_stdout then
						local response = {
							"@@ZDET_RES_BEGIN " .. request_id,
							"@@ZDET_RES_ERR " .. request_id .. " " .. error_message,
							"@@ZDET_RES_END " .. request_id,
						}
						ctx.state.detect_backend_invocations = ctx.state.detect_backend_invocations + 1
						vim.defer_fn(function()
							job.opts.on_stdout(job_id, to_stdout_payload(response))
						end, 10)
					end
					return 1
				end

				local response = simulation.parse_unified_daemon_request(text)
				if response and job.opts and job.opts.on_stdout then
					ctx.state.detect_backend_invocations = ctx.state.detect_backend_invocations + 1
					vim.defer_fn(function()
						job.opts.on_stdout(job_id, to_stdout_payload(response))
					end, 10)
				end
				return 1
			end

			if text:match("^@@ZPRJ_REQ_BEGIN%s+") then
				ctx.state.project_backend_request_count = ctx.state.project_backend_request_count + 1
				if type(ctx.state.next_project_backend_error) == "string" and ctx.state.next_project_backend_error ~= "" then
					local request_id = text:match("^@@ZPRJ_REQ_BEGIN%s+(%d+)$") or text:match("^@@ZPRJ_REQ_BEGIN%s+(%d+)")
					local error_message = ctx.state.next_project_backend_error
					ctx.state.next_project_backend_error = nil
					if request_id and job.opts and job.opts.on_stdout then
						local response = {
							"@@ZPRJ_RES_BEGIN " .. request_id,
							"@@ZPRJ_RES_ERR " .. request_id .. " " .. error_message,
							"@@ZPRJ_RES_END " .. request_id,
						}
						ctx.state.project_backend_invocations = ctx.state.project_backend_invocations + 1
						vim.defer_fn(function()
							job.opts.on_stdout(job_id, to_stdout_payload(response))
						end, 10)
					end
					return 1
				end

				local response = simulation.parse_unified_daemon_request(text)
				if response and job.opts and job.opts.on_stdout then
					ctx.state.project_backend_invocations = ctx.state.project_backend_invocations + 1
					local chunk_sets = ctx.state.next_project_backend_stdout_chunks
					ctx.state.next_project_backend_stdout_chunks = nil
					if type(chunk_sets) == "table" and #chunk_sets > 0 then
						for _, chunk in ipairs(chunk_sets) do
							local payload = type(chunk) == "table" and chunk or { tostring(chunk or "") }
							vim.defer_fn(function()
								job.opts.on_stdout(job_id, payload)
							end, 10)
						end
					else
						vim.defer_fn(function()
							job.opts.on_stdout(job_id, to_stdout_payload(response))
						end, 10)
					end
				end
				return 1
			end

			if text:match("^@@ZHLT_REQ_BEGIN%s+") then
				local request_id = text:match("^@@ZHLT_REQ_BEGIN%s+(%d+)")
				if request_id and job.opts and job.opts.on_stdout then
					local response = {
						"@@ZHLT_RES_BEGIN " .. request_id,
						"@@ZHLT_RES_END " .. request_id,
					}
					vim.defer_fn(function()
						job.opts.on_stdout(job_id, to_stdout_payload(response))
					end, 10)
				end
				return 1
			end

			if
				text:match("^@@ZCFG_REQ_BEGIN%s+")
				or text:match("^@@ZBR_REQ_BEGIN%s+")
				or text:match("^@@ZBA_REQ_BEGIN%s+")
				or text:match("^@@ZRUN_REQ_BEGIN%s+")
			then
				local response = simulation.parse_unified_daemon_request(text)
				if response and job.opts and job.opts.on_stdout then
					vim.defer_fn(function()
						job.opts.on_stdout(job_id, to_stdout_payload(response))
					end, 10)
				end
				return 1
			end
		end

		if simulation.is_quickfix_daemon_cmd(job.cmd) then
			if ctx.state.next_quickfix_backend_exit_code ~= 0 then
				local exit_code = ctx.state.next_quickfix_backend_exit_code
				ctx.state.next_quickfix_backend_exit_code = 0
				if job.opts and job.opts.on_exit then
					vim.defer_fn(function()
						job.opts.on_exit(job_id, exit_code)
					end, 10)
				end
				return 1
			end

			local text = type(data) == "table" and table.concat(data) or tostring(data or "")
			local response = simulation.parse_daemon_request(text)
			if response and job.opts and job.opts.on_stdout then
				ctx.state.quickfix_backend_invocations = ctx.state.quickfix_backend_invocations + 1
				vim.defer_fn(function()
					job.opts.on_stdout(job_id, response)
				end, 10)
			end
			return 1
		end

		if simulation.is_detect_daemon_cmd(job.cmd) then
			ctx.state.detect_backend_request_count = ctx.state.detect_backend_request_count + 1
			if ctx.state.next_detect_backend_exit_code ~= 0 then
				local exit_code = ctx.state.next_detect_backend_exit_code
				ctx.state.next_detect_backend_exit_code = 0
				if job.opts and job.opts.on_exit then
					vim.defer_fn(function()
						job.opts.on_exit(job_id, exit_code)
					end, 10)
				end
				return 1
			end
			if type(ctx.state.next_detect_backend_error) == "string" and ctx.state.next_detect_backend_error ~= "" then
				local text = type(data) == "table" and table.concat(data) or tostring(data or "")
				local request_id = text:match("^@@ZDET_REQ_BEGIN%s+(%d+)%s+[%w_%-]+")
				local error_message = ctx.state.next_detect_backend_error
				ctx.state.next_detect_backend_error = nil
				if request_id and job.opts and job.opts.on_stdout then
					local response = {
						"@@ZDET_RES_BEGIN " .. request_id,
						"@@ZDET_RES_ERR " .. request_id .. " " .. error_message,
						"@@ZDET_RES_END " .. request_id,
					}
					ctx.state.detect_backend_invocations = ctx.state.detect_backend_invocations + 1
					vim.defer_fn(function()
						job.opts.on_stdout(job_id, response)
					end, 10)
				end
				return 1
			end

			local text = type(data) == "table" and table.concat(data) or tostring(data or "")
			local response = simulation.parse_detect_daemon_request(text)
			if response and job.opts and job.opts.on_stdout then
				ctx.state.detect_backend_invocations = ctx.state.detect_backend_invocations + 1
				vim.defer_fn(function()
					job.opts.on_stdout(job_id, response)
				end, 10)
			end
			return 1
		end

		if simulation.is_project_daemon_cmd(job.cmd) then
			ctx.state.project_backend_request_count = ctx.state.project_backend_request_count + 1
			if type(ctx.state.next_project_backend_error) == "string" and ctx.state.next_project_backend_error ~= "" then
				local text = type(data) == "table" and table.concat(data) or tostring(data or "")
				local request_id = text:match("^@@ZPRJ_REQ_BEGIN%s+(%d+)$") or text:match("^@@ZPRJ_REQ_BEGIN%s+(%d+)")
				local error_message = ctx.state.next_project_backend_error
				ctx.state.next_project_backend_error = nil
				if request_id and job.opts and job.opts.on_stdout then
					local response = {
						"@@ZPRJ_RES_BEGIN " .. request_id,
						"@@ZPRJ_RES_ERR " .. request_id .. " " .. error_message,
						"@@ZPRJ_RES_END " .. request_id,
					}
					ctx.state.project_backend_invocations = ctx.state.project_backend_invocations + 1
					vim.defer_fn(function()
						job.opts.on_stdout(job_id, response)
					end, 10)
				end
				return 1
			end
			local text = type(data) == "table" and table.concat(data) or tostring(data or "")
			local response = simulation.parse_project_daemon_request(text)
			if response and job.opts and job.opts.on_stdout then
				ctx.state.project_backend_invocations = ctx.state.project_backend_invocations + 1
				local chunk_sets = ctx.state.next_project_backend_stdout_chunks
				ctx.state.next_project_backend_stdout_chunks = nil
				if type(chunk_sets) == "table" and #chunk_sets > 0 then
					for _, chunk in ipairs(chunk_sets) do
						local payload = type(chunk) == "table" and chunk or { tostring(chunk or "") }
						vim.defer_fn(function()
							job.opts.on_stdout(job_id, payload)
						end, 10)
					end
				else
					vim.defer_fn(function()
						job.opts.on_stdout(job_id, response)
					end, 10)
				end
			end
			return 1
		end

		return 1
	end

	vim.fn.jobstop = function(job_id)
		ctx.state.jobstop_count = ctx.state.jobstop_count + 1
		local job = ctx.mock_jobs[job_id]
		if job and job.opts and job.opts.on_exit then
			vim.defer_fn(function()
				job.opts.on_exit(job_id, 1)
			end, 10)
		end
		return 1
	end

	vim.fn.chanclose = function(job_id, stream)
		local job = ctx.mock_jobs[job_id]
		if not job or stream ~= "stdin" or not simulation.is_quickfix_backend_cmd(job.cmd) then
			return 0
		end

		if ctx.state.next_quickfix_backend_exit_code ~= 0 then
			local exit_code = ctx.state.next_quickfix_backend_exit_code
			ctx.state.next_quickfix_backend_exit_code = 0
			if job.opts and job.opts.on_exit then
				vim.defer_fn(function()
					job.opts.on_exit(job_id, exit_code)
				end, 10)
			end
			return 1
		end
		if type(ctx.state.next_quickfix_backend_error) == "string" and ctx.state.next_quickfix_backend_error ~= "" then
			local error_message = ctx.state.next_quickfix_backend_error
			ctx.state.next_quickfix_backend_error = nil
			if job.opts and job.opts.on_stdout and simulation.is_quickfix_daemon_cmd(job.cmd) then
				local text = tostring(job.input or "")
				local request_id = text:match("^@@ZQF_BEGIN%s+(%d+)%s+")
				if request_id then
					local response = {
						"@@ZQF_RES_BEGIN " .. request_id,
						"@@ZQF_RES_ERR " .. request_id .. " " .. error_message,
						"@@ZQF_RES_END " .. request_id,
					}
					ctx.state.quickfix_backend_invocations = ctx.state.quickfix_backend_invocations + 1
					vim.defer_fn(function()
						job.opts.on_stdout(job_id, response)
					end, 10)
					return 1
				end
			end
		end

		local lines = simulation.simulate_quickfix_backend(job.input, job.cmd)
		if job.opts and job.opts.on_stdout then
			ctx.state.quickfix_backend_invocations = ctx.state.quickfix_backend_invocations + 1
			vim.defer_fn(function()
				job.opts.on_stdout(job_id, lines)
			end, 10)
		end
		if job.opts and job.opts.on_exit then
			vim.defer_fn(function()
				job.opts.on_exit(job_id, 0)
			end, 10)
		end
		return 1
	end

	vim.fn.setqflist = function(_, _, qf_opts)
		table.insert(ctx.quickfix_results, qf_opts)
	end
	vim.cmd = function() end
	vim.schedule = function(func)
		func()
	end
	vim.log = { levels = { INFO = 1, WARN = 2, ERROR = 3 } }
	vim.notify = function(msg, level, opts)
		table.insert(ctx.notify_results, { msg = tostring(msg), level = level, opts = opts })
	end

	return function()
			vim.fn.jobstart = original_jobstart
			vim.fn.jobstop = original_jobstop
			vim.fn.chansend = original_chansend
		vim.fn.chanclose = original_chanclose
		vim.fn.setqflist = original_setqflist
		vim.cmd = original_cmd
		vim.schedule = original_schedule
		vim.notify = original_notify
		vim.log = original_log
	end
end

return M
