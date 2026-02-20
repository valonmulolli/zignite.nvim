# zignite.nvim

<p align="center">
  <img src="https://github.com/valonmulolli/zignite.nvim/actions/workflows/ci.yml/badge.svg?branch=master&event=push" alt="CI"/>
  <img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"/>
  <img src="https://img.shields.io/badge/Made%20with-Lua-blueviolet.svg" alt="Made with Lua"/>
  <img src="https://img.shields.io/badge/Powered%20by-Zig-orange.svg" alt="Powered by Zig"/>
  <br/>
  <strong>A blazingly fast, asynchronous code runner for Neovim, powered by Zig.</strong>
</p>

---

Zignite.nvim is a modern code runner plugin for Neovim that prioritizes performance and responsiveness. Unlike traditional runners that just pipe output to a text buffer, Zignite uses fully interactive terminal buffers inside floating windows. This means support for user input, full ANSI colors, and real-time streaming, all powered by a lightweight Zig backend for process safety.

## Features

- **Interactive Terminal Output**: Floating windows are real terminals. Run interactive scripts (e.g., Python `input()`) without issues.
- **Full ANSI Colors**: Compiler errors and logs retain their rich coloring.
- **High-Performance Backend**: Core process management logic is written in Zig.
- **Safety Timeouts**: Automatically kill processes that run too long (infinite loops) via the Zig backend.
- **Quickfix Integration**: Automatically populates the Quickfix list on error, allowing you to jump straight to the correct line.
- **Persistent Quickfix Worker**: Reuses a Zig daemon for quickfix processing to reduce repeat-run latency.
- **Persistent Detect Worker**: Reuses a Zig daemon for build-command detection parsing (`zig/go/cargo/odin`) with Lua fallback.
- **Build System Support**: First-class support for `cargo`, `zig build`, `npm`, `make`, etc.
- **Interactive Command Picker**: Visual menu to choose between `run`, `test`, `build`, or `clean` for the current project.
- **Project Detection**: Automatically detects project roots (e.g., executes `cargo run` even if you are editing a submodule file).
- **Smart Language Detection**: Uses Neovim filetype first, then falls back to file extension/shebang for mixed-language folders.
- **Cross-Platform**: Works efficiently on Linux, macOS, and Windows.

## Requirements

- Neovim >= 0.10
- Zig (latest version recommended)


## Installation

The `build` step is required to compile the Zig backend.

**Lazy.nvim**

```lua
{
    "valonmulolli/zignite.nvim",
    build = "cd zig && zig build -Doptimize=ReleaseFast",
    config = function()
        require("zignite.config").setup({})
    end,
}
```

If you manage keymaps through Lazy's `keys` field, use Lazy's key format:

```lua
{
    "valonmulolli/zignite.nvim",
    keys = {
        { "<leader>r", "<cmd>RunFile<cr>", mode = "n", desc = "Run file" },
        { "<leader>rb", "<cmd>RunBuildSelect<cr>", mode = "n", desc = "Build picker" },
        { "<leader>rl", "<cmd>RunLive<cr>", mode = "n", desc = "Run live/watch command" },
    },
    config = function()
        require("zignite.config").setup({
            keymaps = {}, -- avoid duplicate mappings when Lazy keys are used
        })
    end,
}
```

**Packer**

```lua
use {
    'valonmulolli/zignite.nvim',
    build = "cd zig && zig build -Doptimize=ReleaseFast",
    config = function()
        require("zignite.config").setup({})
    end,
}
```

**Nix / NixOS (flake)**

This repo now exposes a flake package that builds the Zig backend during packaging.

`flake.nix` input:

```nix
zignite = {
  url = "github:valonmulolli/zignite.nvim";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Home Manager Neovim plugins:

```nix
programs.neovim = {
  enable = true;
  plugins = [
    inputs.zignite.packages.${pkgs.system}.default
  ];
};
```

## Configuration

Zignite works out of the box for 20+ languages. Here is the default configuration structure:

```lua
require('zignite.config').setup({
    -- Timeout in milliseconds (e.g., 5000 = 5 seconds). 
    -- If a process runs longer than this, the Zig backend will kill it.
    timeout = nil, 

    keymaps = {
        { "n", "<leader>r", ":RunFile<CR>", { desc = "Run file" } },
        { "n", "<leader>rb", ":RunBuildSelect<CR>", { desc = "Select build command" } },
        { "n", "<leader>rl", ":RunLive<CR>", { desc = "Run live/watch command" } },
        { "n", "<leader>rq", ":RunClose<CR>", { desc = "Close runner" } },
        { "n", "<leader>rp", ":RunProject<CR>", { desc = "Run project" } },
    },

    -- UI configuration for the floating window
    float = {
        border = "rounded",       -- "none", "single", "double", "rounded"
        height = 0.8,
        width = 0.8,
        x = 0.5,
        y = 0.5,
        border_hl = "FloatBorder",
        close_key = "q",
        startinsert = true,       -- Enter insert mode automatically (useful for interactive scripts)
    },
    
    spinner = "dots",             -- "dots", "line", "bar", "clock", etc.
    enable_animations = true,     -- Show spinner in window title
    close_behavior = "stop",      -- "stop" (default) or "hide" for :RunClose / float close key

    term = {
        position = "bot",         -- split: top|bot, vsplit: left|right
        focus = true,
        startinsert = true,
    },

    picker = {
        focus = true,             -- Focus build picker on open
        filter_input = "inline",  -- "inline" | "ui" (vim.ui.input) | "cmdline" (vim.fn.input)
    },

    detect_runtime = {
        async_picker = true,      -- Open picker immediately from cache/defaults
        cache_ttl_ms = 15000,     -- Detection cache freshness window
        live_merge = true,        -- Refresh detected commands in-place while picker is open
    },

    quickfix = {
        enabled = true,             -- Populate quickfix on non-zero exit
        processor = "auto",         -- "auto" | "lua" | "zig"
        zig_min_lines = 300,        -- Auto-switch to zig quickfix processor
        max_lines = 1000,           -- Keep only last N lines from terminal output
        max_bytes = 262144,         -- Byte cap for quickfix processing
        strip_ansi = true,          -- Remove color escape codes in quickfix lines
        strip_ansi_max_lines = 400, -- Strip ANSI on most recent N lines
        parse_diagnostics = true,   -- Canonicalize parseable diagnostics in zig mode
        zig_worker = true,          -- Keep a persistent zig quickfix worker process
        async_strip = true,         -- Lua fallback: strip ANSI in chunks
        strip_chunk_size = 200,     -- Lua fallback chunk size
    },
})
```

## Usage

### Commands

- `:RunFile`: Run the current file using the filetype runner (single-file flow).
- `:RunCode`: Run the current visual selection.
- `:RunProject`: Run the detected project command from project root (e.g., `npm start`, `cargo run`, `go run .`).
- `:RunBuildSelect`: Open an interactive picker to choose a command (build, test, run, etc.).
- `:RunBuildLast`: Repeat the most recent `:RunBuild`/picker command for the current filetype.
- `:RunLive`: Run the best live/watch command for current filetype (`live`, `dev`, `watch`, `serve`, `start`, `preview`).
- `:RunClose`: Close runner output (`close_behavior="stop"` stops jobs, `"hide"` only closes output).
- `:StopCode`: Terminate the currently running process.

### Build Command Picker

For compiled languages (Rust, Zig, C++, Go), you often want to do more than just "Run". 
Press `<leader>rb` (default) to open the Command Picker:

```text
  build              → cargo build
  check              → cargo check
▶ run                → cargo run
  test               → cargo test
  clean              → cargo clean
```

Use:
- `j`/`k` (or arrow keys) to navigate
- `Enter` to select
- `/` to start inline filter in the same picker popup (type to filter, `Enter` apply, `Esc` cancel)
- `c` to clear filter
- `r` to run the previous build command for current filetype

To use external prompt modes instead of inline filtering, set:
```lua
picker = {
    filter_input = "ui",      -- use vim.ui.input popup
    -- or
    filter_input = "cmdline",
}
```

Picker commands are merged from your configured `build_commands.<filetype>` plus
auto-detected commands when available:
- `zig`: parsed from `zig --help`
- `go`: parsed from `go help`
- `rust`: parsed from `cargo --list`
- `odin`: parsed from `odin help`
- `c` / `cpp`: parsed from `Makefile` targets when `Makefile` is present
- `javascript` / `typescript`: project `package.json` scripts
- `java` / `kotlin`: Maven/Gradle project tasks inferred from project files

Configured commands always take priority when names overlap.

Auto-detection is enabled by default. You can disable specific detectors:

```lua
detect = {
    go = false,
    rust = false,
    c_cpp_make = false,
}
```

When the Zig backend is available, command detection parsing uses a persistent
worker (`--detect-daemon`) for lower overhead. If unavailable/failing, it
falls back to Lua parsing automatically.

Picker detection runtime defaults:

```lua
detect_runtime = {
    async_picker = true,
    cache_ttl_ms = 15000,
    live_merge = true,
}
```

- `async_picker = true`: `:RunBuildSelect` opens immediately from configured/cached commands.
- `cache_ttl_ms`: stale threshold used before triggering refresh.
- `live_merge = true`: refreshed detected commands are merged into the open picker without closing it.

`zig fetch` is included and prompts for URL/path input when selected.

Any build command can request runtime arguments by using `$zignite_args` in the
command template. Example:

```lua
build_commands = {
    python = {
        pip = "pip install $zignite_args",
    },
}
```

When selected, the picker asks for the argument and runs the expanded command.

### RunFile vs RunProject

- Use `:RunFile` for fast single-file feedback.
- Use `:RunProject` when you explicitly want project-wide startup/build behavior.
- For Zig, `:RunFile` prefers project build execution (`zig build ...`) when `build.zig` exists.

### Quickfix Pipeline

- `quickfix.processor = "auto"`: uses Lua for small outputs, Zig for large outputs (`zig_min_lines` threshold).
- `quickfix.processor = "zig"`: always uses Zig processing with immediate Lua fallback on backend errors.
- `quickfix.zig_worker = true`: keeps a persistent Zig worker (`--quickfix-daemon`) to avoid per-run process spawn cost.
- `quickfix.zig_worker = false`: disables worker reuse and uses one-shot Zig quickfix jobs.

Recommended low-latency setup:

```lua
quickfix = {
    processor = "auto",
    zig_min_lines = 200,
    zig_worker = true,
    max_lines = 1000,
    max_bytes = 262144,
}
```

### Variable Substitution

You can use these variables in your custom runner commands:

| Variable | Description | Example |
| :--- | :--- | :--- |
| `$file` | Full file path | `/home/user/main.py` |
| `$fileName` | Filename with extension | `main.py` |
| `$fileNameWithoutExt` | Filename without extension | `main` |
| `$dir` | Directory path | `/home/user/project` |
| `$projectName` | Project root folder name | `my-project-cli` |
| `$projectNameShort` | Project name without suffix | `my-project` |

## Troubleshooting

### "Zig executable not found"
Run `zig build` inside the plugin's `zig/` directory manually.

### "No runner configured"
Add it to your setup:
```lua
runners = {
    my_lang = "my-compiler $file"
}
```

### Odin "Redeclaration of 'main'" on `:RunFile`
Use single-file mode for Odin:
```lua
runners = {
    odin = "odin run $file -file",
}
```

### Go `:RunFile` feels slow or hangs
`go run .` compiles/runs the whole module. For single-file execution use `:RunFile` (runner `go run $file`). Use `:RunProject` only when you want full module execution.

### `zsh: no such option: argv`
Do not put `--argv` in `runners` or `build_commands`. That flag is reserved for Zignite's internal backend wrapper and is injected automatically when appropriate.

### `<leader>` mapping does not trigger
If you define mappings via Lazy.nvim `keys`, use `{ "<lhs>", "<rhs>", mode = "n", ... }` format.  
The `{ "n", "<lhs>", "<rhs>", ... }` format is for `zignite.config.setup({ keymaps = { ... } })`.

### Quickfix feels slow on huge error logs
Tune these options first:
```lua
quickfix = {
    processor = "auto",
    zig_worker = true,
    max_lines = 800,          -- lower tail size
    max_bytes = 196608,       -- lower byte cap
    strip_ansi_max_lines = 300,
}
```

### Build picker refresh behavior
If you prefer legacy blocking detection behavior for the picker:
```lua
detect_runtime = {
    async_picker = false,
    live_merge = false,
}
```

## Development

### Run tests

```sh
lua test/runner.lua
```

### Run integration tests only

```sh
lua test/integration.lua
```

### Run performance benchmark

```sh
lua test/benchmark.lua 10000
```

The benchmark prints:
- Cache-first picker build-list latency and avg/run.
- Lua quickfix path time.
- Zig quickfix simulation time.
- Zig quickfix + diagnostics parse simulation time.
- Real Zig backend quickfix timings when `zig/zig-out/bin/zignite` is available (includes process spawn overhead).
- Real Zig backend per-run averages (`avg/run`) for easier comparison.
- Speedup percentage (`zig` vs `lua`) for large-output quickfix.

Soft guardrail:
- Warn when zig speedup is below 30%.

Optional hard guardrail:
```sh
ZIGNITE_BENCH_HARD_FAIL=1 lua test/benchmark.lua 10000
```

## License

MIT License - see [LICENSE](LICENSE) file for details.
