# zignite.nvim

<p align="center">
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
- **Build System Support**: First-class support for `cargo`, `zig build`, `npm`, `make`, etc.
- **Interactive Command Picker**: Visual menu to choose between `run`, `test`, `build`, or `clean` for the current project.
- **Project Detection**: Automatically detects project roots (e.g., executes `cargo run` even if you are editing a submodule file).
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
})
```

## Usage

### Commands

- `:RunFile`: Run the current file in a floating terminal.
- `:RunCode`: Run the current visual selection.
- `:RunProject`: Run the default project command (e.g., `npm start`, `cargo run`).
- `:RunBuildSelect`: Open an interactive picker to choose a command (build, test, run, etc.).
- `:RunClose`: Close the runner window.
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

Use `j`/`k` to navigate and `Enter` to select.

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

## License

MIT License - see [LICENSE](LICENSE) file for details.
