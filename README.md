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

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Architecture](#architecture)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
  - [Commands](#commands)
  - [Build Command Picker](#build-command-picker)
  - [Runtime Arguments](#runtime-arguments)
  - [Quickfix Pipeline](#quickfix-pipeline)
  - [Variable Substitution](#variable-substitution)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [License](#license)

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

**vim.pack (Neovim >= 0.10)**

```lua
-- Register the build hook before vim.pack.add() to catch install events
vim.api.nvim_create_autocmd('PackChanged', {
    group = vim.api.nvim_create_augroup('zignite-build', { clear = true }),
    callback = function(ev)
        if ev.data.spec.name == 'zignite.nvim' then
            -- :wait() ensures the build completes before the next statement
            vim.system({ 'zig', 'build', '-Doptimize=ReleaseFast' }, { cwd = ev.data.path .. '/zig' }):wait()
        end
    end,
})

vim.pack.add({
    { src = 'https://github.com/valonmulolli/zignite.nvim', version = 'master' },
})
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

Zignite works out of the box for 20+ languages. See `example_config.lua` for all available options.

## Usage

### Commands

- `:RunFile`: Run the current file using the filetype runner (single-file flow).
- `:RunCode`: Run the current visual selection, or the current file when used without a visual range.
- `:RunBuild <name> <mode>`: Run a specific build command by name (e.g., `:RunBuild test vsplit`). Supports tab completion for command names.
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

### Runtime Arguments

Any build command can request runtime arguments by using `$zignite_args` in the
command template. When selected, the picker prompts for input and runs the
expanded command.

```lua
build_commands = {
    python = {
        pip = "pip install $zignite_args",
    },
}
```

**zig fetch integration**: The `zig fetch` command is detected automatically and
prompts for URL/path input. Paste a plain GitHub repo URL or `<owner>/<repo>`,
and Zignite expands it to the saved Zig form:

```text
https://github.com/<owner>/<repo>
                      ↓
zig fetch --save git+https://github.com/<owner>/<repo>
```

- Use `:RunFile` for fast single-file feedback.
- Use `:RunBuild run` when you explicitly want project-wide startup/build behavior.
- For Zig, `:RunFile` prefers project build execution (`zig build ...`) only when the source imports build-defined modules that require `build.zig`.

### Quickfix Pipeline

On non-zero exit, terminal output feeds into the quickfix list so you can jump
through errors. The pipeline uses Zig processing when available, with an
automatic Lua fallback.

```lua
quickfix = {
    enabled = true,
    max_lines = 1000,   -- Keep only last N lines from terminal output
    max_bytes = 262144, -- Byte cap for quickfix processing
}
```


### Variable Substitution

You can use these variables in your custom runner commands:

| Variable              | Description                 | Example              |
| :-------------------- | :-------------------------- | :------------------- |
| `$file`               | Full file path              | `/home/user/main.py` |
| `$fileName`           | Filename with extension     | `main.py`            |
| `$fileNameWithoutExt` | Filename without extension  | `main`               |
| `$dir`                | Directory path              | `/home/user/project` |
| `$projectName`        | Project root folder name    | `my-project-cli`     |
| `$projectNameShort`   | Project name without suffix | `my-project`         |

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

### Go `:RunFile` feels slow or hangs

The Zig backend picks `go run .` by default (whole-module execution). For
single-file feedback, use `:RunFile` which uses the configured runner
(`go run $file`). Switch to `:RunBuild run` when you want full module execution.

### `<leader>` mapping does not trigger

If you define mappings via Lazy.nvim `keys`, use `{ "<lhs>", "<rhs>", mode = "n", ... }` format.  
The `{ "n", "<lhs>", "<rhs>", ... }` format is for `require("zignite").setup({ keymaps = { ... } })`.

## Development

### Run tests (Lua frontend + Zig integration suite)

```sh
lua zig/test/runner.lua
```

### Run backend benchmark

```sh
cd zig
zig build bench          # defaults to 3000 iterations
zig build bench-fast     # defaults to 1000 iterations
zig build bench -- 10000
```

See `CONTRIBUTING.md` for benchmark details.

## License

MIT License - see [LICENSE](LICENSE) file for details.
