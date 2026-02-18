-- Simple benchmark harness for Zignite.nvim internals.
-- Run with: lua test/benchmark.lua [iterations]

local project_root = arg[1] and tonumber(arg[1]) and "." or (arg[1] or ".")
local iterations = tonumber(arg[1]) or tonumber(arg[2]) or 10000

package.path = package.path .. ";" .. project_root .. "/lua/?.lua"
package.path = package.path .. ";" .. project_root .. "/lua/?/init.lua"

_G.vim = _G.vim or {}
vim.bo = vim.bo or { filetype = "zig" }
vim.o = vim.o or { columns = 120, lines = 40 }
vim.log = vim.log or { levels = { INFO = 1, WARN = 2, ERROR = 3 } }
vim.notify = vim.notify or function() end
vim.cmd = vim.cmd or function() end
vim.schedule = vim.schedule or function(fn) fn() end
vim.schedule_wrap = vim.schedule_wrap or function(fn) return fn end
vim.keymap = vim.keymap or { set = function() end }
vim.tbl_isempty = vim.tbl_isempty or function(tbl) return next(tbl) == nil end
vim.tbl_contains = vim.tbl_contains or function(tbl, value)
	for _, v in ipairs(tbl) do
		if v == value then
			return true
		end
	end
	return false
end
vim.tbl_extend = vim.tbl_extend or function(behavior, ...)
	local result = {}
	for i = 1, select("#", ...) do
		local tbl = select(i, ...)
		for k, v in pairs(tbl) do
			if type(v) == "table" and type(result[k]) == "table" then
				result[k] = vim.tbl_extend(behavior, result[k], v)
			else
				result[k] = v
			end
		end
	end
	return result
end
vim.tbl_deep_extend = vim.tbl_deep_extend or function(behavior, ...)
	return vim.tbl_extend(behavior, ...)
end

local current_file = "/tmp/bench-zig/src/main.zig"
local marker_files = {
	["/tmp/bench-zig/build.zig"] = true,
}

vim.fs = vim.fs or {}
vim.fs.normalize = vim.fs.normalize or function(path) return path end
vim.fs.joinpath = vim.fs.joinpath or function(a, b) return a .. "/" .. b end

vim.fn = vim.fn or {}
vim.fn.expand = function(expr)
	if expr == "%:p" then
		return current_file
	end
	return expr
end
vim.fn.fnamemodify = function(path, modifier)
	if modifier == ":h" then
		return path:gsub("/[^/]+$", "")
	elseif modifier == ":e" then
		return path:match("%.([^%.]+)$") or ""
	elseif modifier == ":t" then
		return path:match("([^/]+)$") or path
	elseif modifier == ":t:r" then
		local name = path:match("([^/]+)$") or path
		return name:gsub("%.([^%.]+)$", "")
	elseif modifier == ":." then
		return path
	elseif modifier == ":p:h:h:h" then
		return project_root
	end
	return path
end
vim.fn.filereadable = function(path)
	return marker_files[path] and 1 or 0
end
vim.fn.executable = function(path)
	return 0
end
vim.fn.shellescape = function(str)
	return "'" .. tostring(str) .. "'"
end

local config = require("zignite.config")
local init = require("zignite.init")
local utils = require("zignite.utils")

config.setup({
	project = {},
	enable_animations = false,
})

local function now_ms()
	return os.clock() * 1000
end

local function bench(name, fn)
	local start_ms = now_ms()
	fn()
	local elapsed = now_ms() - start_ms
	print(string.format("%-34s %10.2f ms", name .. ":", elapsed))
end

local function quickfix_simulation(lines, max_lines, strip_ansi)
	local start_line = math.max(1, #lines - max_lines + 1)
	local out = {}
	for i = start_line, #lines do
		local line = lines[i]
		if strip_ansi then
			line = line:gsub("\27%[[0-9;]*m", "")
		end
		out[#out + 1] = line
	end
	return out
end

print(string.format("Zignite benchmark (iterations=%d)", iterations))
print(string.rep("-", 52))

bench("detect_project (cold-ish)", function()
	utils.clear_project_cache()
	for i = 1, iterations do
		local path = string.format("/tmp/bench-zig/src/module_%d/main.zig", i)
		utils.detect_project(path, config.options.project)
	end
end)

bench("detect_project (hot)", function()
	utils.clear_project_cache()
	local path = "/tmp/bench-zig/src/main.zig"
	utils.detect_project(path, config.options.project) -- warm cache
	for _ = 1, iterations do
		utils.detect_project(path, config.options.project)
	end
end)

bench("get_command (hot)", function()
	utils.clear_project_cache()
	current_file = "/tmp/bench-zig/src/main.zig"
	for _ = 1, iterations do
		init.get_command()
	end
end)

local large_lines = {}
for i = 1, 20000 do
	large_lines[i] = string.format("\27[31merror line %d\27[0m", i)
end

bench("quickfix tail+strip (20k -> 1k)", function()
	for _ = 1, math.max(1, math.floor(iterations / 20)) do
		quickfix_simulation(large_lines, 1000, true)
	end
end)

