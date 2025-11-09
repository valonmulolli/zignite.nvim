# Local Development Setup

For local development and testing, you can load the plugin directly from your local directory.

## Using Lazy.nvim

Add to your `~/.config/nvim/init.lua`:

```lua
-- For local development
vim.opt.runtimepath:prepend('/path/to/zignite.nvim')

-- Or use lazy with local path
require('lazy').setup({
    {
        dir = '/path/to/zignite.nvim',
        config = function()
            require('zignite.config').setup()
        end
    }
})
```

## Manual Installation

1. Clone or copy the plugin to your Neovim plugin directory:
   ```bash
   cp -r /path/to/zignite.nvim ~/.local/share/nvim/site/pack/local/start/
   ```

2. Build the Zig backend:
   ```bash
   cd ~/.local/share/nvim/site/pack/local/start/zignite.nvim/zig
   zig build
   ```

3. Add to your Neovim config:
   ```lua
   require('zignite.config').setup()
   ```

## Testing

Run the test suite:
```bash
cd /path/to/zignite.nvim
nvim --headless -c "lua require('test.runner').run_tests()"
```