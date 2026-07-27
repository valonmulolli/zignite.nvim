local M = {}

function M.check()
	vim.health.start("zignite")

	do
		local ok = vim.fn.has("nvim-0.10") == 1
		if ok then
			vim.health.ok(("Neovim >= 0.10: %s"):format(vim.version()))
		else
			vim.health.error(("Neovim >= 0.10 required, got %s"):format(vim.version()))
		end
	end

	do
		local is_linux = vim.fn.has("linux") == 1
		local is_macos = vim.fn.has("mac") == 1 or vim.fn.has("macunix") == 1
		if is_linux or is_macos then
			vim.health.ok(("Platform: %s"):format(is_linux and "Linux" or "macOS"))
		else
			vim.health.warn("Windows is not officially supported")
		end
	end

	do
		local ok = type(vim.fn.jobstart) == "function"
		if ok then
			vim.health.ok("vim.fn.jobstart available")
		else
			vim.health.error("vim.fn.jobstart not available, cannot run backend processes")
		end
	end

	do
		local ok = type(vim.fn.chansend) == "function" and type(vim.fn.chanclose) == "function"
		if ok then
			vim.health.ok("vim.fn.chansend/chanclose available (daemon mode)")
		else
			vim.health.warn("vim.fn.chansend/chanclose not available, daemon communication disabled")
		end
	end

	local ok, transport = pcall(require, "zignite.rpc.transport")
	if not ok or type(transport) ~= "table" then
		vim.health.error("Failed to load zignite.rpc.transport, cannot determine backend path")
		return
	end
	local backend = transport.ZIG_EXECUTABLE
	if type(backend) ~= "string" or backend == "" then
		vim.health.error("Backend path not configured")
		return
	end
	local exists = vim.fn.filereadable(backend) == 1 or (vim.uv and vim.uv.fs_stat(backend) ~= nil)
	if not exists then
		vim.health.error(
			("Backend binary not found: %s\nRun `zig build install` from the plugin root to build it"):format(backend)
		)
	else
		local executable = vim.fn.executable(backend) == 1
		if executable then
			vim.health.ok(("Backend binary found and executable: %s"):format(backend))
		else
			vim.health.warn(("Backend binary exists but may not be executable: %s"):format(backend))
		end
	end

	if ok and type(transport) == "table" and transport.has_backend then
		local has_backend = transport.has_backend()
		local supports_stream = false
		local s_ok, streaming = pcall(transport.supports_stream_backend, transport, true)
		if s_ok then
			supports_stream = streaming
		end
		if has_backend and supports_stream then
			vim.health.ok("Backend is functional (executable + streaming)")
		elseif has_backend then
			vim.health.warn("Backend exists but streaming (daemon) mode is unavailable")
		else
			vim.health.warn("Backend not available, plugin will fall back to Lua-only operations")
		end
	end

	do
		-- Ping the daemon to verify it is responsive (not just alive).
		-- Uses the build_resolve client to send a @@ZHLT_ frame.
		local ping_ok, ping_result = pcall(function()
			local build_resolve = require("zignite.rpc.build_resolve")
			if type(build_resolve.ping_async) ~= "function" then
				return nil
			end
			local healthy = false
			local completed = false
			build_resolve.ping_async(function(success)
				healthy = success
				completed = true
			end, 3000)
			if type(vim.wait) == "function" then
				vim.wait(3500, function()
					return completed
				end, 50)
			end
			return healthy
		end)
		if ping_ok and ping_result == true then
			vim.health.ok("Daemon process is responsive (ping/pong)")
		elseif ping_ok and ping_result == nil then
			-- ping_async not available (old client), skip
		else
			vim.health.warn("Daemon process did not respond to health ping (may be starting or busy)")
		end
	end

	do
		local ok, config = pcall(require, "zignite.config")
		if ok and type(config) == "table" then
			vim.health.ok("Config module loaded")
			local opts = config.options
			if opts and not vim.tbl_isempty(opts) then
				vim.health.info(string.format("Config initialized with %d options", vim.tbl_count(opts)))
			end
		end
	end
end

return M
