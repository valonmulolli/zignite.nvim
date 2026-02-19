local M = {}

-- Default configuration
M.defaults = {
	keymaps = {
		{ "n", "<leader>r",  ":RunFile<CR>",        { desc = "Run file" } },
		{ "n", "<leader>rq", ":RunClose<CR>",       { desc = "Close runner" } },
		{ "n", "<leader>rt", ":RunFile tab<CR>",    { desc = "Run file in new tab" } },
		{ "n", "<leader>rv", ":RunFile vsplit<CR>", { desc = "Run file in vertical split" } },
		{ "n", "<leader>rh", ":RunFile split<CR>",  { desc = "Run file in horizontal split" } },
		{ "n", "<leader>rp", ":RunProject<CR>",     { desc = "Run project" } },
		{ "n", "<leader>rb", ":RunBuildSelect<CR>", { desc = "Select build command" } },
	},

	-- Default output mode: "float", "tab", "split", "vsplit"
	mode = "float",

	-- Default runners for specific filetypes.
	-- Inspired by code_runner.nvim's configuration style
	-- Available variables:
	--   $file              - Full absolute path
	--   $fileName          - Just the filename with extension
	--   $fileNameWithoutExt - Filename without extension
	--   $dir               - Full directory path
	--   $fileExt           - File extension
	--   $dirName           - Just the directory name (not full path)
	runners = {
		-- Compiled languages - optimized for speed
		c = {
			cmd = {
				"cd $dir",
				"gcc $fileName -o /tmp/$fileNameWithoutExt",
				"/tmp/$fileNameWithoutExt",
			},
			cleanup_command = "rm /tmp/$fileNameWithoutExt",
		},
		cpp = {
			cmd = {
				"cd $dir",
				"clang++ $fileName -o /tmp/$fileNameWithoutExt",
				"/tmp/$fileNameWithoutExt",
			},
			cleanup_command = "rm /tmp/$fileNameWithoutExt",
		},
		rust = {
			cmd = {
				"cd $dir",
				"rustc $fileName -o /tmp/$fileNameWithoutExt",
				"/tmp/$fileNameWithoutExt",
			},
			cleanup_command = "rm /tmp/$fileNameWithoutExt",
		},
		go = "go run $file",
		zig = "zig run $file",
		java = {
			"cd $dir",
			"javac $fileName",
			"java $fileNameWithoutExt",
		},
		kotlin = {
			cmd = {
				"cd $dir",
				"kotlinc $fileName -include-runtime -d /tmp/$fileNameWithoutExt.jar",
				"java -jar /tmp/$fileNameWithoutExt.jar",
			},
			cleanup_command = "rm /tmp/$fileNameWithoutExt.jar",
		},

		-- Interpreted languages
		python = "python3 -u $file",
		javascript = "node $file",
		typescript = "bun $file",
		lua = "lua $file",
		ruby = "ruby $file",
		php = "php $file",
		perl = "perl $file",
		r = "Rscript $file",
		julia = "julia $file",

		-- Shell scripts
		sh = "bash $file",
		zsh = "zsh $file",

		-- Web and markup
		html = "xdg-open $file",

		-- Other languages
		dart = "dart run $file",
		swift = "swift $file",
		elixir = "elixir $file",
		haskell = {
			cmd = {
				"cd $dir",
				"ghc -o /tmp/$fileNameWithoutExt $fileName",
				"/tmp/$fileNameWithoutExt",
			},
			cleanup_command = "rm /tmp/$fileNameWithoutExt",
		},
			odin = "odin run $file -file",
		fortran = {
			cmd = {
				"cd $dir",
				"gfortran $fileName -o /tmp/$fileNameWithoutExt",
				"/tmp/$fileNameWithoutExt",
			},
			cleanup_command = "rm /tmp/$fileNameWithoutExt",
		},
	},

	-- Build commands for different languages
	-- These are project-level commands (cargo build, zig build, etc.)
	build_commands = {
		rust = {
			build = "cargo build",
			run = "cargo run",
			test = "cargo test",
			release = "cargo build --release",
			["release-run"] = "cargo run --release",
			check = "cargo check",
			clean = "cargo clean",
		},
		zig = {
			build = "zig build",
			run = "zig build run",
			test = "zig build test",
			release = "zig build -Doptimize=ReleaseFast",
			["release-run"] = "zig build run -Doptimize=ReleaseFast",
		},
		odin = {
			build = "odin build .",
			run = "odin run .",
			test = "odin test .",
			release = "odin build . -o:speed",
			check = "odin check .",
		},
		fortran = {
			build = "gfortran *.f90 -o main",
			run = "gfortran *.f90 -o main && ./main",
			clean = "rm main",
		},
		go = {
			build = "go build",
			run = "go run .",
			test = "go test ./...",
			clean = "go clean",
			mod = "go mod tidy",
		},
		javascript = {
			start = "npm start",
			dev = "npm run dev",
			build = "npm run build",
			test = "npm test",
			install = "npm install",
		},
		typescript = {
			start = "npm start",
			dev = "npm run dev",
			build = "npm run build",
			test = "npm test",
		},
		python = {
			run = "python -m main",
			test = "pytest",
			install = "pip install -r requirements.txt",
		},
		c = {
			-- Make commands
			build = "make",
			run = "make run",
			clean = "make clean",
			test = "make test",
			install = "make install",
			debug = "make debug",

			-- CMake commands
			["cmake-config"] = "cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1",
			["cmake-build"] =
			"[ ! -f build/Makefile ] && [ ! -f build/build.ninja ] && cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1; cmake --build build",
			["cmake-run"] =
			"[ ! -f build/Makefile ] && [ ! -f build/build.ninja ] && cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1; cmake --build build && \"$(find ./build -maxdepth 1 -type f -executable ! -name '*.so' | head -1)\"",
			["cmake-clean"] = "rm -rf build",
			["cmake-debug"] =
			"cmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
			["cmake-release"] =
			"cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",

			-- Meson commands
			["meson-setup"] = "meson setup build",
			["meson-build"] = "[ ! -f build/build.ninja ] && meson setup build; meson compile -C build",
			["meson-run"] =
			"[ ! -f build/build.ninja ] && meson setup build; meson compile -C build && \"$(find ./build -maxdepth 1 -type f -executable ! -name '*.so' | head -1)\"",
			["meson-clean"] = "rm -rf build",
			["meson-test"] = "meson test -C build",
		},
		cpp = {
			-- Make commands
			build = "make",
			run = "make run",
			clean = "make clean",
			test = "make test",
			install = "make install",
			debug = "make debug",

			-- CMake commands
			["cmake-config"] = "cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1",
			["cmake-build"] =
			"[ ! -f build/Makefile ] && [ ! -f build/build.ninja ] && cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1; cmake --build build",
			["cmake-run"] =
			"[ ! -f build/Makefile ] && [ ! -f build/build.ninja ] && cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1; cmake --build build && \"$(find ./build -maxdepth 1 -type f -executable ! -name '*.so' | head -1)\"",
			["cmake-clean"] = "rm -rf build",
			["cmake-debug"] =
			"cmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
			["cmake-release"] =
			"cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
			["cmake-test"] = "ctest --test-dir build",

			-- Meson commands
			["meson-setup"] = "meson setup build",
			["meson-build"] = "[ ! -f build/build.ninja ] && meson setup build; meson compile -C build",
			["meson-run"] =
			"[ ! -f build/build.ninja ] && meson setup build; meson compile -C build && \"$(find ./build -maxdepth 1 -type f -executable ! -name '*.so' | head -1)\"",
			["meson-clean"] = "rm -rf build",
			["meson-test"] = "meson test -C build",
		},
	},

	-- Spinner configuration
	spinner = "dots",      -- Spinner type: "dots", "line", "bar", "arrows", "dots2", "triangle", "square", "circle", "arrow", "box"
	spinner_speed = 80,    -- Speed in milliseconds
	enable_animations = true, -- Enable/disable animations and spinners

	-- Execution configuration
	timeout = nil, -- Timeout in milliseconds (e.g., 10000 for 10s). nil = no timeout. Only works with Zig backend.

	-- Output configuration
	show_stderr_prefix = false,                    -- Whether to prefix stderr output with [STDERR] (default: false for better UX)
	no_stderr_prefix_types = { "zig", "go", "rust" }, -- Filetypes that commonly output to stderr normally

	-- Quickfix behavior on command errors
	quickfix = {
		enabled = true,              -- Populate quickfix when command exits with non-zero status
		processor = "auto",          -- "auto", "lua", or "zig"
		zig_min_lines = 300,         -- In auto mode, switch to zig processor when output reaches this line count
		max_lines = 1000,            -- Tail limit for large outputs (performance guard)
		max_bytes = 262144,          -- Byte cap for quickfix payload
		strip_ansi = true,           -- Remove ANSI escape codes from quickfix lines
		strip_ansi_max_lines = 400,  -- Strip ANSI only on the most recent N lines
		parse_diagnostics = true,    -- Canonicalize parseable diagnostics in zig processor mode
		async_strip = true,          -- Strip ANSI in scheduled chunks to reduce UI stutter
		strip_chunk_size = 200,      -- Lines processed per chunk when async_strip=true
	},

	-- Filter patterns for stderr (hide these warnings/info messages)
	stderr_filters = {
		"MODULE_TYPELESS_PACKAGE_JSON", -- Node.js module type warnings
		"ExperimentalWarning",    -- Node.js experimental feature warnings
		"DeprecationWarning",     -- Deprecation warnings
		"Use `node --trace%-warnings", -- Node.js trace suggestion
		"To eliminate this warning", -- Generic warning elimination suggestions
	},

	-- Project configuration
	-- Pattern matching for project root detection
	project = {},

	-- UI configuration for the floating window
	float = {
		border = "rounded",            -- Border style: "none", "single", "double", "rounded", "solid", "shadow"
		height = 0.8,                  -- Window height (0.0 to 1.0 = percentage of editor height)
		width = 0.8,                   -- Window width (0.0 to 1.0 = percentage of editor width)
		x = 0.5,                       -- Horizontal position (0.0 = left, 0.5 = center, 1.0 = right)
		y = 0.5,                       -- Vertical position (0.0 = top, 0.5 = center, 1.0 = bottom)
		border_hl = "FloatBorder",     -- Highlight group for the border
		close_key = "<Esc>",           -- Key to close the window
		focus = true,                  -- Auto-focus the window on open
		startinsert = false,           -- Enter insert mode when the window opens
		border_hl_success = "DiagnosticOk", -- Highlight group for success border (e.g., "DiagnosticOk", "String", "DiffAdd")
		border_hl_error = "DiagnosticError", -- Highlight group for error border (e.g., "DiagnosticError", "Error", "DiffDelete")
	},

	-- Terminal configuration for split/vsplit/tab modes
	term = {
		position = "bot", -- Position: "bot", "top", "left", "right"
		size = 15,    -- Size in lines (for horizontal) or columns (for vertical)
		focus = true, -- Focus on terminal after opening
		startinsert = true, -- Start in insert mode
	},

	-- Build picker configuration
	picker = {
		focus = true, -- Focus the interactive build picker window when opening
	},

	-- Execution behavior
	singleton = true, -- If true, only one runner window can be open at a time (previous one is closed)
}

-- This will hold the merged user and default configuration
M.options = {}

-- Validate configuration options
local function validate_config(opts)
	if opts.mode and not vim.tbl_contains({ "float", "tab", "split", "vsplit" }, opts.mode) then
		vim.notify("Invalid mode: " .. opts.mode .. ". Valid modes: float, tab, split, vsplit", vim.log.levels.WARN)
	end

	if opts.float then
		local float = opts.float
		if
			float.border
			and not vim.tbl_contains({ "none", "single", "double", "rounded", "solid", "shadow" }, float.border)
		then
			vim.notify("Invalid border: " .. float.border, vim.log.levels.WARN)
		end
			if float.height and (float.height <= 0 or float.height > 1) then
				vim.notify("Float height should be > 0 and <= 1", vim.log.levels.WARN)
			end
			if float.width and (float.width <= 0 or float.width > 1) then
				vim.notify("Float width should be > 0 and <= 1", vim.log.levels.WARN)
			end
		end

	if opts.term then
		local term = opts.term
		if term.position and not vim.tbl_contains({ "bot", "top", "left", "right" }, term.position) then
			vim.notify("Invalid terminal position: " .. term.position, vim.log.levels.WARN)
		end
	end
end

-- A setup function for users to call.
-- It will merge their provided options with the defaults.
function M.setup(opts)
	opts = opts or {}
	validate_config(opts)
	M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts)
	local ok, utils = pcall(require, "zignite.utils")
	if ok and utils.clear_project_cache then
		utils.clear_project_cache()
	end

	M.setup_keymaps()
end

-- Ensure defaults are available without applying side effects (e.g. keymaps).
function M.ensure()
	if vim.tbl_isempty(M.options) then
		M.options = vim.tbl_deep_extend("force", {}, M.defaults, {})
	end
	return M.options
end

function M.setup_keymaps()
	if not M.options.keymaps then
		return
	end
	for _, keymap in ipairs(M.options.keymaps) do
		vim.keymap.set(keymap[1], keymap[2], keymap[3], keymap[4])
	end
end

return M
