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
vim.fn.executable = function(_path)
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

local time_source = "os.clock"
local function now_ms()
	if vim and vim.loop and type(vim.loop.hrtime) == "function" then
		time_source = "vim.loop.hrtime"
		return vim.loop.hrtime() / 1e6
	end

	local ok_socket, socket = pcall(require, "socket")
	if ok_socket and socket and type(socket.gettime) == "function" then
		time_source = "socket.gettime"
		return socket.gettime() * 1000
	end

	return os.clock() * 1000
end

local function bench(name, fn)
	local start_ms = now_ms()
	fn()
	local elapsed = now_ms() - start_ms
	print(string.format("%-34s %10.2f ms", name .. ":", elapsed))
end

local function bench_ms(fn)
	local start_ms = now_ms()
	fn()
	return now_ms() - start_ms
end

local function tail_lines(lines, max_lines)
	local start_line = math.max(1, #lines - max_lines + 1)
	local out = {}
	for i = start_line, #lines do
		out[#out + 1] = lines[i]
	end
	return out, start_line > 1
end

local function quickfix_lua_path(lines, opts)
	local out, truncated = tail_lines(lines, opts.max_lines)
	if opts.strip_ansi then
		for i = 1, #out do
			out[i] = out[i]:gsub("\27%[[0-9;]*m", "")
		end
	end
	if truncated then
		table.insert(out, 1, "[zignite] quickfix output truncated")
	end
	return out
end

local function canonicalize_diag(line)
	local trimmed = line:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^%-%->%s*", "")
	local path, row, col, msg = trimmed:match("^([^:]+):(%d+):(%d+):%s*(.+)$")
	if path then
		return string.format("%s:%d:%d: %s", path, tonumber(row), tonumber(col), msg ~= "" and msg or "diagnostic")
	end
	local path2, row2, msg2 = trimmed:match("^([^:]+):(%d+):%s*(.+)$")
	if path2 then
		return string.format("%s:%d:%d: %s", path2, tonumber(row2), 1, msg2 ~= "" and msg2 or "diagnostic")
	end
	local path3, row3, col3, msg3 = trimmed:match("^(.+)%((%d+):(%d+)%)%s*(.*)$")
	if path3 then
		return string.format("%s:%d:%d: %s", path3, tonumber(row3), tonumber(col3), msg3 ~= "" and msg3 or "diagnostic")
	end
	return line
end

local function quickfix_zig_path_sim(lines, opts)
	local out, truncated = tail_lines(lines, opts.max_lines)
	local strip_from = math.max(1, #out - opts.strip_ansi_max_lines + 1)
	for i = strip_from, #out do
		if opts.strip_ansi then
			out[i] = out[i]:gsub("\27%[[0-9;]*m", "")
		end
		if opts.parse_diagnostics then
			out[i] = canonicalize_diag(out[i])
		end
	end
	if truncated then
		table.insert(out, 1, "[zignite] quickfix output truncated")
	end
	return out
end

local function shell_quote(value)
	local s = tostring(value or "")
	if package.config:sub(1, 1) == "\\" then
		return '"' .. s:gsub('"', '\\"') .. '"'
	end
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function command_ok(ok, _, code)
	if type(ok) == "number" then
		return ok == 0
	end
	if ok == true then
		return code == nil or code == 0
	end
	return false
end

local function file_exists(path)
	local f = io.open(path, "rb")
	if f then
		f:close()
		return true
	end
	return false
end

local function write_tempfile(text)
	local path = os.tmpname()
	local f = assert(io.open(path, "wb"))
	f:write(text)
	f:close()
	return path
end

local function write_file(path, text)
	local f = assert(io.open(path, "wb"))
	f:write(text)
	f:close()
end

now_ms() -- prime timer source detection
print(string.format("Zignite benchmark (iterations=%d)", iterations))
print(string.format("Timer source: %s", time_source))
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

local picker_iters = math.max(1, math.floor(iterations / 50))
init.get_build_commands_for_completion("zig") -- warm non-blocking build list path
local picker_ms = bench_ms(function()
	for _ = 1, picker_iters do
		init.get_build_commands_for_completion("zig")
	end
end)
print(string.format("%-34s %10.2f ms", "build list (nonblocking cache-first):", picker_ms))
print(string.format("%-34s %10.2f ms", "build list avg/run:", picker_ms / picker_iters))

local large_lines = {}
for i = 1, 20000 do
	large_lines[i] = string.format("\27[31merror line %d\27[0m", i)
end

local diag_lines = {}
for i = 1, 20000 do
	if i % 3 == 0 then
		diag_lines[i] = string.format("src/main.c:%d:5: error: failed", i)
	elseif i % 3 == 1 then
		diag_lines[i] = string.format(" --> src/lib.rs:%d:3", i)
	else
		diag_lines[i] = string.format("/tmp/sample.odin(%d:1) Error: redeclaration", i)
	end
end

local quickfix_iters = math.max(1, math.floor(iterations / 20))
local quickfix_opts = {
	max_lines = 1000,
	strip_ansi = true,
	strip_ansi_max_lines = 400,
	parse_diagnostics = false,
}

local lua_ms = bench_ms(function()
	for _ = 1, math.max(1, math.floor(iterations / 20)) do
		quickfix_lua_path(large_lines, quickfix_opts)
	end
end)
print(string.format("%-34s %10.2f ms", "quickfix lua (20k -> 1k):", lua_ms))

local zig_ms = bench_ms(function()
	for _ = 1, quickfix_iters do
		quickfix_zig_path_sim(large_lines, quickfix_opts)
	end
end)
print(string.format("%-34s %10.2f ms", "quickfix zig-sim (20k -> 1k):", zig_ms))

local zig_diag_ms = bench_ms(function()
	for _ = 1, quickfix_iters do
		quickfix_zig_path_sim(diag_lines, {
			max_lines = 1000,
			strip_ansi = true,
			strip_ansi_max_lines = 400,
			parse_diagnostics = true,
		})
	end
end)
print(string.format("%-34s %10.2f ms", "quickfix zig-sim + parser:", zig_diag_ms))

if lua_ms > 0 then
	local improvement = ((lua_ms - zig_ms) / lua_ms) * 100
	print(string.format("%-34s %9.2f%%", "quickfix zig speedup vs lua:", improvement))
	if improvement < 30 then
		print(string.format("WARN: quickfix zig speedup below target (30%%): %.2f%%", improvement))
		if os.getenv("ZIGNITE_BENCH_HARD_FAIL") == "1" then
			error(string.format("quickfix zig regression: speedup %.2f%% < 30%%", improvement))
		end
	end
end

local backend_path = project_root .. "/zig/zig-out/bin/zignite"
if file_exists(backend_path) then
	local large_input = write_tempfile(table.concat(large_lines, "\n") .. "\n")
	local diag_input = write_tempfile(table.concat(diag_lines, "\n") .. "\n")
	local null_sink = package.config:sub(1, 1) == "\\" and "NUL" or "/dev/null"
	local backend_iters = math.max(1, math.floor(quickfix_iters / 10))

	local backend_cmd = string.format(
		"%s --quickfix --max-lines=1000 --max-bytes=262144 --strip-ansi=1 --strip-max-lines=400 --parse-diagnostics=0 < %s > %s 2> %s",
		shell_quote(backend_path),
		shell_quote(large_input),
		shell_quote(null_sink),
		shell_quote(null_sink)
	)

	local backend_diag_cmd = string.format(
		"%s --quickfix --max-lines=1000 --max-bytes=262144 --strip-ansi=1 --strip-max-lines=400 --parse-diagnostics=1 < %s > %s 2> %s",
		shell_quote(backend_path),
		shell_quote(diag_input),
		shell_quote(null_sink),
		shell_quote(null_sink)
	)

	local probe_cmd = string.format(
		"%s --quickfix < %s > %s 2> %s",
		shell_quote(backend_path),
		shell_quote(diag_input),
		shell_quote(null_sink),
		shell_quote(null_sink)
	)
	local first_ok = command_ok(os.execute(probe_cmd))
	if first_ok then
		local zig_real_ms = bench_ms(function()
			for _ = 1, backend_iters do
				assert(command_ok(os.execute(backend_cmd)), "zig backend quickfix command failed")
			end
		end)
		print(string.format("%-34s %10.2f ms", "quickfix zig-backend (real):", zig_real_ms))
		print(string.format("%-34s %10.2f ms", "quickfix zig-backend avg/run:", zig_real_ms / backend_iters))

		local zig_real_diag_ms = bench_ms(function()
			for _ = 1, backend_iters do
				assert(command_ok(os.execute(backend_diag_cmd)), "zig backend diagnostics command failed")
			end
		end)
		print(string.format("%-34s %10.2f ms", "quickfix zig-backend + parser:", zig_real_diag_ms))
		print(string.format("%-34s %10.2f ms", "quickfix zig-backend+parser avg:", zig_real_diag_ms / backend_iters))
	else
		print("WARN: zig backend binary exists but quickfix command failed; skipping real backend benchmark")
	end

	os.remove(large_input)
	os.remove(diag_input)

	local parser_root = os.tmpname() .. "_zignite_parser_bench"
	local parser_src_dir = parser_root .. "/src"
	assert(command_ok(os.execute("mkdir -p " .. shell_quote(parser_src_dir))), "failed to create parser benchmark dir")

	local makefile_path = parser_root .. "/Makefile"
	local package_json_path = parser_root .. "/package.json"
	local cmake_lists_path = parser_root .. "/CMakeLists.txt"
	local cmake_match_path = parser_src_dir .. "/main.cpp"

	write_file(makefile_path, "all: app\nbench test: app\n")
	write_file(package_json_path, '{ "scripts": { "dev": "vite", "build": "vite build" } }\n')
	write_file(cmake_lists_path, 'project(demo)\nadd_executable(app src/main.cpp)\n')
	write_file(cmake_match_path, "int main() { return 0; }\n")

	local parser_iters = math.max(1, math.floor(iterations / 50))
	local make_cmd = string.format(
		"%s --project-parse --kind=make --path=%s > %s 2> %s",
		shell_quote(backend_path),
		shell_quote(makefile_path),
		shell_quote(null_sink),
		shell_quote(null_sink)
	)
	local package_cmd = string.format(
		"%s --project-parse --kind=package-json --path=%s > %s 2> %s",
		shell_quote(backend_path),
		shell_quote(package_json_path),
		shell_quote(null_sink),
		shell_quote(null_sink)
	)
	local cmake_cmd = string.format(
		"%s --project-parse --kind=cmake --path=%s --match-path=%s > %s 2> %s",
		shell_quote(backend_path),
		shell_quote(cmake_lists_path),
		shell_quote(cmake_match_path),
		shell_quote(null_sink),
		shell_quote(null_sink)
	)

	local parser_make_ms = bench_ms(function()
		for _ = 1, parser_iters do
			assert(command_ok(os.execute(make_cmd)), "zig make parser command failed")
		end
	end)
	print(string.format("%-34s %10.2f ms", "project parse make (real):", parser_make_ms))
	print(string.format("%-34s %10.2f ms", "project parse make avg/run:", parser_make_ms / parser_iters))

	local parser_package_ms = bench_ms(function()
		for _ = 1, parser_iters do
			assert(command_ok(os.execute(package_cmd)), "zig package-json parser command failed")
		end
	end)
	print(string.format("%-34s %10.2f ms", "project parse package-json:", parser_package_ms))
	print(string.format("%-34s %10.2f ms", "project parse package avg/run:", parser_package_ms / parser_iters))

	local parser_cmake_ms = bench_ms(function()
		for _ = 1, parser_iters do
			assert(command_ok(os.execute(cmake_cmd)), "zig cmake parser command failed")
		end
	end)
	print(string.format("%-34s %10.2f ms", "project parse cmake (real):", parser_cmake_ms))
	print(string.format("%-34s %10.2f ms", "project parse cmake avg/run:", parser_cmake_ms / parser_iters))

	assert(command_ok(os.execute("rm -rf " .. shell_quote(parser_root))), "failed to clean parser benchmark dir")
else
	print("NOTE: zig backend binary not found; skipping real backend benchmark")
end
