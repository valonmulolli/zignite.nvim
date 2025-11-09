# Zignite.nvim

<p align="center">
  <img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"/>
  <img src="https://img.shields.io/badge/Made%20with-Lua-blueviolet.svg" alt="Made with Lua"/>
  <img src="https://img.shields.io/badge/Powered%20by-Zig-orange.svg" alt="Powered by Zig"/>
  <br/>
  <strong>A blazingly fast, asynchronous code runner for Neovim, powered by Zig.</strong>
</p>

---

Zignite.nvim is a modern code runner plugin for Neovim that prioritizes performance and responsiveness. It uses a backend written in Zig to execute code in a background process, ensuring the Neovim UI never blocks. The output is displayed in a clean, configurable floating window.

## Features

- **High-Performance Backend**: Core logic is written in Zig for maximum speed.
- **Asynchronous Execution**: Never blocks the Neovim UI, even with long-running code.
- **Customizable UI**: Highly configurable floating window for output.
- **Visual Selection**: Run only the code you've highlighted in visual mode.
- **Cancellable Jobs**: Stop a running process at any time with the `:StopCode` command.
- **Configurable**: Easily customize commands for different filetypes.

## Requirements

- Neovim >= 0.7
- Zig (latest nightly version recommended)

## Installation

Install using your favorite plugin manager. The `build` step is required to compile the Zig backend.

The `zig build` command, executed from the `zig` directory, compiles the Zig source code located in `zig/src/`. This creates a native executable that acts as the high-performance backend for the plugin. The compiled binary is placed in `zig/zig-out/bin/`, and it is this binary that the Lua frontend communicates with to run your code asynchronously.

**Lazy.nvim**

<details>

<summary>📋 Copy</summary>



```lua

{

    "valonmulolli/zignite.nvim",

    build = "cd zig && zig build",

    config = function()

        require("zignite.config").setup({

            -- Your custom configuration here

        })

    end,

}

```

</details>

**Packer**

```lua
use {
    'valonmulolli/zignite.nvim',
    run = 'cd zig && zig build',
    config = function()
        require("zignite.config").setup({})
    end,
}
```

**vim-plug**

```vim
Plug 'valonmulolli/zignite.nvim', { 'do': 'cd zig && zig build' }
```

## Configuration

Zignite provides a `setup` function to customize its behavior. You only need to pass the values you want to override. Here is an example showing all the default settings:

```lua
require('zignite.config').setup({
    keymaps = {
        { "n", "<leader>r", ":RunFile<CR>", { desc = "Run file" } },
        { "n", "<leader>rq", ":RunClose<CR>", { desc = "Close runner" } },
        { "n", "<leader>rt", ":RunFile tab<CR>", { desc = "Run file in new tab" } },
        { "n", "<leader>rp", ":RunProject<CR>", { desc = "Run project" } },
    },

    -- Runner commands for different filetypes
    runners = {
        python = "python",
        sh = "bash",
        javascript = "node",
        typescript = "ts-node",
        go = "go run",
        rust = "cargo run",
        c = "gcc -o /tmp/zignite_c_output % && /tmp/zignite_c_output",
        cpp = "g++ -o /tmp/zignite_cpp_output % && /tmp/zignite_cpp_output",
    },

    -- UI configuration for the floating window
    float = {
        border = "rounded",       -- Border style ("none", "single", "double", "rounded")
        height = 0.8,           -- Window height (percentage of editor height)
        width = 0.8,            -- Window width (percentage of editor width)
        x = 0.5,                -- Horizontal position (percentage from left)
        y = 0.5,                -- Vertical position (percentage from top)
        border_hl = "FloatBorder", -- Highlight group for the border
        close_key = "<Esc>",      -- Key to close the window
        focus = true,           -- Auto-focus the window on open
        startinsert = false,    -- Enter insert mode when the window opens
    },
})
```

## Keymaps

Zignite comes with a set of default keymaps for common actions. You can customize them by overriding the `keymaps` table in the `setup` function.

| Keymap       | Command        | Description              |
|--------------|----------------|--------------------------|
| `<leader>r`  | `:RunFile`     | Run the current file.    |
| `<leader>rq` | `:RunClose`    | Close the runner window. |
| `<leader>rt` | `:RunFile tab` | Run file in a new tab. |
| `<leader>rp` | `:RunProject`  | Run the project. |

## Usage

### Commands

- `:RunCode`: Execute the current file or visual selection.
- `:RunFile`: Execute the current file.
- `:RunFile tab`: Execute the current file in a new tab.
- `:RunFile split`: Execute the current file in a horizontal split.
- `:RunFile vsplit`: Execute the current file in a vertical split.
- `:RunClose`: Close the runner window.
- `:RunProject`: Run the project (detects project root automatically).
- `:StopCode`: Terminate the currently running process.

### Visual Mode

Select code in visual mode and run `:RunCode` to execute only the selected portion.

### Project Detection

Zignite automatically detects project types based on common markers:

- `package.json` → Node.js project
- `Cargo.toml` → Rust project
- `go.mod` → Go project
- Custom project configurations can be added in the setup function

## Examples

### Basic Usage

```vim
" Run current file
:RunFile

" Run visual selection
:'<,'>RunCode

" Run project
:RunProject

" Stop running process
:StopCode
```

### Custom Configuration

```lua
require('zignite.config').setup({
    -- Custom runners
    runners = {
        python = "python3 -u $file",
        javascript = "node $file",
        -- Add compiled languages with cleanup
        c = {
            cmd = {"gcc $file -o /tmp/$fileNameWithoutExt", "/tmp/$fileNameWithoutExt"},
            cleanup_command = "rm /tmp/$fileNameWithoutExt"
        }
    },

    -- Custom keymaps
    keymaps = {
        { "n", "<F5>", ":RunFile<CR>", { desc = "Run file" } },
        { "v", "<F5>", ":RunCode<CR>", { desc = "Run selection" } },
    },

    -- UI customization
    float = {
        width = 0.9,
        height = 0.9,
        border = "double"
    }
})
```

### Project Configuration

```lua
require('zignite.config').setup({
    project = {
        -- Node.js project
        ["/home/user/myapp/.*"] = {
            name = "My Node.js App",
            command = "npm run dev"
        },
        -- Rust project
        ["/home/user/rustapp/.*"] = {
            name = "My Rust App",
            command = "cargo run"
        }
    }
})
```

## Variable Substitution

Zignite supports extensive variable substitution in commands:

| Variable | Description | Example |
|----------|-------------|---------|
| `$file` | Full file path | `/home/user/main.py` |
| `$fileName` | Filename with extension | `main.py` |
| `$fileNameWithoutExt` | Filename without extension | `main` |
| `$dir` | Directory path | `/home/user/project` |
| `$fileExt` | File extension | `py` |
| `$dirName` | Directory name | `project` |

## Troubleshooting

### "Zig executable not found"
Make sure Zig is installed and the plugin is built:
```bash
cd ~/.local/share/nvim/lazy/zignite.nvim/zig
zig build
```

### "No runner configured for filetype"
Add a custom runner in your configuration:
```lua
require('zignite.config').setup({
    runners = {
        your_filetype = "your_command $file"
    }
})
```

### Process doesn't stop
Use `:StopCode` to terminate running processes. If that doesn't work, restart Neovim.

### File not found errors
Ensure your buffer is saved (`:w`) before running code.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) file for details.
