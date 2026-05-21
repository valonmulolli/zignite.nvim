<h1 align="center">zignite.nvim</h1>
<br/>
<p align="center">
  <img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"/>
  <img src="https://img.shields.io/badge/Lua%20%2B%20Zig-blueviolet.svg" alt="Lua + Zig"/>
  <img src="https://img.shields.io/badge/Powered%20by-Zig-orange.svg" alt="Powered by Zig"/>
  <br/>
  <strong>Async code runner for Neovim. Powered by Zig for near-zero overhead execution with non-blocking output streaming.</strong>
</p>

---

Zignite.nvim is a code runner for Neovim focused on low-latency execution and interactive output. It uses terminal buffers in floats, splits, vsplits, and tabs, so programs keep stdin, ANSI colors, and real-time streaming. A Zig backend handles command execution, filetype normalization, build/run resolution, project parsing, quickfix processing, and command detection.

## Features

- **Interactive Terminal Output**: Runner windows are real terminals, so stdin-driven programs continue to work.
- **Full ANSI Colors**: Compiler errors and logs retain their rich coloring.
- **Zig Backend**: Build resolution, runner resolution, command detection, project parsing, quickfix processing, and execution support run through a native backend.
- **Safety Timeouts**: Commands that exceed the configured timeout are terminated by the Zig backend.
- **Quickfix Integration**: Non-zero exits can populate the quickfix list so errors are easy to jump through.
- **Unified Zig Daemon**: Reuses one backend daemon for config sync, build/run resolve, detection, project parsing, and quickfix processing to reduce repeat-run latency.
- **Build System Support**: Supports `cargo`, `zig build`, `npm`, `make`, CMake, Meson, Bazel, Maven, Gradle, Go modules/workspaces, and more.
- **Interactive Command Picker**: Choose between `run`, `test`, `build`, `clean`, and detected project commands.
- **Project Detection**: Detects project roots so project-aware commands run from the correct working directory.
- **Smart Language Detection**: Uses Neovim filetype first, then falls back to file extension/shebang for mixed-language folders.
- **Platform**: Linux and macOS only.

## Requirements

- Neovim >= 0.10
- Zig `0.16.0`

The backend targets Zig 0.16.0. Earlier versions will not compile.

## Architecture

The current architecture is intentionally split:

- Lua owns the Neovim frontend layer: setup, config, RPC transport, picker/window UI, and thin controller flow
- Zig owns the backend layer: config interpretation, filetype normalization, build/run resolution, project parsing, system queries, detection, quickfix processing, and execution support

For contributors: `CONTRIBUTING.md`


## Installation

The `build` step is required to compile the Zig backend.

Example files in this repo:

- `lazy_config.lua`: recommended minimal `lazy.nvim` setup
- `example_config.lua`: full reference config with more options than most users need

**Lazy.nvim**

```lua
{
    "valonmulolli/zignite.nvim",
    build = "cd zig && zig build -Doptimize=ReleaseFast",
    config = function()
        require("zignite").setup({})
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
        require("zignite").setup({
            keymaps = {}, -- avoid duplicate mappings when Lazy keys are used
        })
    end,
}
```

**Native package (vim-pack)**

```bash
git clone https://github.com/valonmulolli/zignite.nvim \
  ~/.local/share/nvim/site/pack/vendor/start/zignite.nvim
cd ~/.local/share/nvim/site/pack/vendor/start/zignite.nvim/zig && \
  zig build -Doptimize=ReleaseFast
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

Zignite works out of the box for 20+ languages. The block below shows the default configuration shape:

```lua
require('zignite').setup({
    -- Timeout in milliseconds (e.g., 5000 = 5 seconds). 
    -- If a process runs longer than this, the Zig backend will kill it.
    timeout = nil, 

    keymaps = {
        { "n", "<leader>r", ":RunFile<CR>", { desc = "Run file" } },
        { "n", "<leader>rb", ":RunBuildSelect<CR>", { desc = "Select build command" } },
        { "n", "<leader>rl", ":RunLive<CR>", { desc = "Run live/watch command" } },
        { "n", "<leader>rq", ":RunClose<CR>", { desc = "Close runner" } },
    },

    -- UI configuration for the floating window
    float = {
        border = "rounded",       -- "none", "single", "double", "rounded"
        height = 0.8,
        width = 0.8,
        x = 0.5,
        y = 0.5,
        border_hl = "FloatBorder",
        close_key = "<Esc>",
        startinsert = false,      -- Float opens in normal mode by default
    },
    
    spinner = "dots",             -- "dots", "line", "bar", "arrows", etc.
    enable_animations = true,     -- Show spinner in window title
    close_behavior = "stop",      -- "stop" (default) or "hide" for :RunClose / float close key

    term = {
        position = "bot",         -- split: top|bot, vsplit: left|right
        size = 15,
        focus = true,
        startinsert = true,
    },

    picker = {
        focus = true,             -- Focus build picker on open
        filter_input = "inline",  -- "inline" | "ui" (vim.ui.input) | "cmdline" (vim.fn.input)
        layout = "auto",          -- "auto" | "detailed" | "compact"
        compact_breakpoint = 96,  -- Auto-switch to compact picker on narrow screens
    },

    detect_runtime = {
        async_picker = true,      -- Open picker immediately from cache/defaults
        cache_ttl_ms = 15000,     -- Detection cache freshness window
        live_merge = true,        -- Refresh detected commands in-place while picker is open
    },

    quickfix = {
        enabled = true,             -- Populate quickfix on non-zero exit
        processor = "auto",         -- "auto" | "lua" | "zig"
        zig_min_lines = 300,        -- Legacy threshold; auto mode now prefers zig whenever backend is available
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
- `:RunCode`: Run the current visual selection, or the current file when used without a visual range.
- `:RunBuildSelect`: Open an interactive picker to choose a command (build, test, run, etc.).
- `:RunBuildLast`: Repeat the most recent `:RunBuild`/picker command for the current filetype.
- `:RunLive`: Run the best live/watch command for current filetype (`live`, `dev`, `watch`, `serve`, `start`, `preview`).
- `:RunClose`: Close runner output (`close_behavior="stop"` stops jobs, `"hide"` only closes output).
- `:StopCode`: Terminate the currently running process.

### Build Command Picker

For compiled languages such as Rust, Zig, C++, and Go, you often want more than a single-file runner. Use `<leader>rb` (default) to open the build command picker:

```text
  build              → cargo build
  check              → cargo check
▶ run                → cargo run
  test               → cargo test
  clean              → cargo clean
```

For Zig projects, the default commands also include a project-level check path:

```text
  build              → zig build
  check              → zig build check
  run                → zig build run
  test               → zig build test
```

Use:
- `j`/`k` (or arrow keys) to navigate
- `Enter` to select
- `/` to start inline filter in the same picker popup (type to filter, `Enter` apply, `Esc` cancel)
- `c` to clear filter
- `r` to run the previous build command for current filetype

On narrower screens the picker automatically switches to a smaller compact layout while staying in a single window. The selected command still appears on the bottom command line.

To use external prompt modes instead of inline filtering, set:
```lua
picker = {
    filter_input = "ui",      -- use vim.ui.input popup
    -- or
    filter_input = "cmdline",
    layout = "compact",       -- optional: force compact picker layout
}
```

Picker commands are built from your configured `build_commands.<filetype>` plus
auto-detected commands when available. Detection currently covers:
- tool commands for `zig`, `go`, `rust`, `c`, `cpp`, `python`, `odin`, and `fortran`
- project commands for `Makefile`, `package.json`, Maven, Gradle, CMake, Meson, Bazel, `Cargo.toml`, `go.mod`, `go.work`, and `pyproject.toml`
- Python project workflows for `uv`, `requirements.txt`/`pip`, and conda (`environment.yml` / `environment.yaml`)

Configured commands always take priority when names overlap.

Auto-detection is enabled by default. You can disable specific detectors:

```lua
detect = {
    go = false,
    rust = false,
    c_cpp_make = false,
    bazel_project = false,
}
```

Detection, build resolution, run resolution, config sync, and quickfix reuse a
persistent Zig backend daemon (`--daemon`) for lower overhead. The plugin
builds this backend during installation, and the resolver path expects it to be
available.

`RunBuild`, `RunLive`, and `:RunBuild` completion use configured commands plus
cached detected commands first, then refresh detection in the background. That
keeps command dispatch responsive even when tool help output still has to be
parsed.

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

Python project support is intentionally limited to:
- `uv`
- `requirements.txt` / `pip`
- conda (`environment.yml` / `environment.yaml`)

`zig fetch` is included and prompts for URL/path input when selected. In the
picker, you can paste a plain GitHub repo URL or `<owner>/<repo>`, and
Zignite will expand it to the saved Zig form automatically.

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
For example, pasting:

```text
https://github.com/<owner>/<repo>
```

expands to:

```text
zig fetch --save git+https://github.com/<owner>/<repo>
```

- Use `:RunFile` for fast single-file feedback.
- Use `:RunBuild run` when you explicitly want project-wide startup/build behavior.
- For Zig, `:RunFile` prefers project build execution (`zig build ...`) only when the source imports build-defined modules that require `build.zig`.

### Quickfix Pipeline

- `quickfix.processor = "auto"`: prefers Zig processing when the backend is available, with immediate Lua fallback on backend errors.
- `quickfix.processor = "zig"`: always uses Zig processing with immediate Lua fallback on backend errors.
- `quickfix.zig_worker = true`: keeps quickfix requests on the persistent Zig backend daemon (`--daemon`) to avoid per-run process spawn cost.
- `quickfix.zig_worker = false`: disables worker reuse and uses one-shot Zig quickfix jobs.

Recommended low-latency setup:

```lua
quickfix = {
    processor = "auto",
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
Run `zig build -Doptimize=ReleaseFast` inside the plugin's `zig/` directory manually.

### "No runner configured"
The Zig backend auto-detects the correct build/run command for supported
filetypes. If nothing appears:

- Check that your `build.zig`, `Cargo.toml`, `Makefile`, `CMakeLists.txt`,
  `package.json`, etc. are in the project root.
- The filetype must be one of the supported languages (zig, rust, go, c, cpp,
  python, odin, fortran, java, kotlin, javascript, typescript).
- If your project uses an unsupported build system, add a custom command in your
  setup via `build_commands` or `runners`:
  ```lua
  runners = {
      my_lang = "my-compiler $file"
  }
  ```

### Platform note
Only Linux and macOS are supported. Windows is not supported and will not be.

### Odin "Redeclaration of 'main'" on `:RunFile`
The Zig backend defaults to `odin run .` for project builds. If you are working
on a single file outside of an Odin project, set a custom runner:
```lua
runners = {
    odin = "odin run $file -file",
}
```

### Go `:RunFile` feels slow or hangs
The Zig backend picks `go run .` by default (whole-module execution). For
single-file feedback, use `:RunFile` which uses the configured runner
(`go run $file`). Switch to `:RunBuild run` when you want full module execution.

### `zsh: no such option: argv`
Do not put `--argv` in `runners` or `build_commands`. That flag is reserved for Zignite's internal backend wrapper and is injected automatically when appropriate.

### `<leader>` mapping does not trigger
If you define mappings via Lazy.nvim `keys`, use `{ "<lhs>", "<rhs>", mode = "n", ... }` format.  
The `{ "n", "<lhs>", "<rhs>", ... }` format is for `require("zignite").setup({ keymaps = { ... } })`.

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

### Run the Lua frontend + integration suite

```sh
lua test/runner.lua
```

### Run backend benchmark

```sh
cd zig
zig build bench          # defaults to 3000 iterations
zig build bench-fast     # defaults to 1000 iterations
zig build bench -- 10000
```

What the benchmark covers:
- direct Zig build resolution
- direct Zig run resolution
- selected-command materialization
- daemon-backed build resolution
- daemon-backed run resolution
- quickfix processing (tail collect, ansi strip, full pipeline)

`bench-fast` is the quick local pass. `bench` gives a steadier baseline.

The benchmark prints:
- direct resolver timings (`avg/run`)
- daemon-backed resolver timings (`avg/run`)
- per-case throughput (`ops/s`)
- per-case percentile stats (min, p50, p95, max, stddev)
- guardrail warnings when a benchmark crosses its configured threshold

## License

MIT License - see [LICENSE](LICENSE) file for details.
