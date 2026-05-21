-- ============================================================================
-- Zignite.nvim - Example Configuration
-- ============================================================================
-- This is a reference config for normal use.
--
-- Important architecture rule:
--   Lua owns Neovim setup, keymaps, UI, and user overrides.
--   Zig owns builtin runners, build-system detection, and command resolution.
--
-- Keep `runners` and `build_commands` empty unless you intentionally want to
-- override or extend the Zig backend defaults.
--
-- Plugin manager build step:
--   build = "cd zig && zig build -Doptimize=ReleaseFast"
-- ============================================================================

require("zignite").setup({
  -- ==========================================================================
  -- KEYMAPS
  -- ==========================================================================
  -- If your plugin manager registers keymaps, set `keymaps = {}` here and define
  -- these mappings in the manager spec instead.
  keymaps = {
    { "n", "<leader>r", ":RunFile<CR>", { desc = "Run file" } },
    { "n", "<leader>rf", ":RunFile<CR>", { desc = "Run file" } },
    { "n", "<leader>rb", ":RunBuildSelect<CR>", { desc = "Select build command" } },
    { "n", "<leader>rl", ":RunLive<CR>", { desc = "Run live/watch command" } },
    { "n", "<leader>rt", ":RunFile tab<CR>", { desc = "Run file in new tab" } },
    { "n", "<leader>rv", ":RunFile vsplit<CR>", { desc = "Run file in vertical split" } },
    { "n", "<leader>rh", ":RunFile split<CR>", { desc = "Run file in horizontal split" } },
    { "n", "<leader>rq", ":RunClose<CR>", { desc = "Close runner" } },
    { "n", "<leader>rs", ":StopCode<CR>", { desc = "Stop execution" } },
  },

  -- Default output mode: "float", "tab", "split", or "vsplit".
  mode = "float",

  -- ==========================================================================
  -- BACKEND OVERRIDES
  -- ==========================================================================
  -- Builtin single-file runners live in Zig. Leave this empty for the default
  -- behavior for Zig, Go, Rust, C/C++, Python, JavaScript, TypeScript, etc.
  runners = {
    -- Example override:
    -- python = "uv run python $file",
    --
    -- Example custom runner:
    -- mylang = {
    --   cmd = {
    --     "mylang build $file",
    --     "mylang run $fileNameWithoutExt",
    --   },
    --   cleanup_command = "rm -f $fileNameWithoutExt",
    -- },
  },

  -- Builtin project/build commands live in Zig. Leave this empty so the backend
  -- can pick the real project system: zig build, go modules/workspaces, Cargo,
  -- package.json scripts, Make, CMake, Meson, Bazel, Maven, Gradle, and more.
  build_commands = {
    -- Example extension:
    -- zig = {
    --   docs = "zig build docs",
    -- },
    --
    -- Example override:
    -- typescript = {
    --   lint = "npm run lint",
    -- },
  },

  -- Build command auto-detection.
  detect = {
    zig = true,
    go = true,
    rust = true,
    odin = true,
    c_cpp_make = true,
    js_package_scripts = true,
    java_kotlin_project = true,
    bazel_project = true,
  },

  -- Detection runtime behavior for the picker.
  detect_runtime = {
    async_picker = true, -- Open from cache/defaults, refresh in the background.
    cache_ttl_ms = 15000,
    live_merge = true, -- Merge refreshed commands into the open picker.
  },

  -- ==========================================================================
  -- QUICKFIX
  -- ==========================================================================
  quickfix = {
    enabled = true,
    processor = "auto", -- "auto", "lua", or "zig"; auto prefers Zig.
    zig_min_lines = 300,
    max_lines = 1000,
    max_bytes = 262144,
    strip_ansi = true,
    strip_ansi_max_lines = 400,
    parse_diagnostics = true,
    zig_worker = true,
    async_strip = true,
    strip_chunk_size = 200,
  },

  -- ==========================================================================
  -- PROJECT OVERRIDES
  -- ==========================================================================
  -- Use this only for special local projects that need a custom command.
  project = {
    -- [vim.fn.expand("~/Dev/my-special-project") .. "/.*"] = {
    --   name = "My Special Project",
    --   command = "zig build run -Dexample=true",
    -- },
  },

  -- ==========================================================================
  -- UI
  -- ==========================================================================
  float = {
    border = "rounded",
    height = 0.8,
    width = 0.8,
    x = 0.5,
    y = 0.5,
    border_hl = "FloatBorder",
    border_hl_success = "DiagnosticOk",
    border_hl_error = "DiagnosticError",
    close_key = "<Esc>",
    auto_close_success_ms = nil, -- nil keeps successful output open.
    focus = true,
    startinsert = false,
  },

  term = {
    position = "bot",
    size = 15,
    focus = true,
    startinsert = true,
  },

  picker = {
    focus = true,
    filter_input = "inline", -- "inline", "ui", or "cmdline".
    layout = "auto", -- "auto", "detailed", or "compact".
    compact_breakpoint = 96,
  },

  -- Only one runner window at a time.
  singleton = true,

  -- Behavior for :RunClose and the float close key:
  --   "stop" stops the process.
  --   "hide" only hides the output window.
  close_behavior = "stop",

  -- Spinner/title animation.
  spinner = "dots",
  spinner_speed = 80,
  enable_animations = true,

  -- Timeout in milliseconds. nil disables timeout.
  timeout = nil,
})

-- ============================================================================
-- OPTIONAL LOCAL KEYMAP EXAMPLES
-- ============================================================================
-- These are intentionally commented out. The backend already resolves the best
-- build/run/test commands; these mappings only choose which UI command to open.
--
-- vim.api.nvim_create_autocmd("FileType", {
--   pattern = { "rust", "zig", "go", "c", "cpp" },
--   callback = function(ev)
--     vim.keymap.set("n", "<leader>r", ":RunBuildSelect<CR>", {
--       buffer = ev.buf,
--       desc = "Select build command",
--     })
--   end,
-- })

-- ============================================================================
-- QUICK REFERENCE
-- ============================================================================
-- :RunFile [mode]         Run current file.
-- :RunCode                Run visual selection or current file.
-- :RunBuild <command>     Run a concrete build command.
-- :RunBuildSelect [mode]  Open the build command picker.
-- :RunBuildLast           Repeat the last build command.
-- :RunLive                Run the best live/dev/watch command.
-- :RunClose               Close output, using `close_behavior`.
-- :StopCode               Stop the running process.
--
-- Common variables available in custom commands:
--   $file
--   $fileName
--   $fileNameWithoutExt
--   $dir
--   $fileExt
--   $projectName
--   $projectNameShort
