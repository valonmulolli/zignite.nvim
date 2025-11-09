local M = {}

-- Default configuration
M.defaults = {
    keymaps = {
        { "n", "<leader>r", ":RunFile<CR>", { desc = "Run file" } },
        { "n", "<leader>rq", ":RunClose<CR>", { desc = "Close runner" } },
        { "n", "<leader>rt", ":RunFile tab<CR>", { desc = "Run file in new tab" } },
        { "n", "<leader>rv", ":RunFile vsplit<CR>", { desc = "Run file in vertical split" } },
        { "n", "<leader>rh", ":RunFile split<CR>", { desc = "Run file in horizontal split" } },
        { "n", "<leader>rp", ":RunProject<CR>", { desc = "Run project" } },
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
            cleanup_command = "rm /tmp/$fileNameWithoutExt"
        },
        cpp = {
            cmd = {
                "cd $dir",
                "clang++ $fileName -std=c++23 -o /tmp/$fileNameWithoutExt",
                "/tmp/$fileNameWithoutExt",
            },
            cleanup_command = "rm /tmp/$fileNameWithoutExt"
        },
        rust = {
            cmd = {
                "cd $dir",
                "rustc $fileName -o /tmp/$fileNameWithoutExt",
                "/tmp/$fileNameWithoutExt",
            },
            cleanup_command = "rm /tmp/$fileNameWithoutExt"
        },
        go = {
            "cd $dir",
            "go run $fileName"
        },
        zig = {
            "cd $dir",
            "zig run $fileName"
        },
        java = {
            "cd $dir",
            "javac $fileName",
            "java $fileNameWithoutExt"
        },
        kotlin = {
            cmd = {
                "cd $dir",
                "kotlinc $fileName -include-runtime -d /tmp/$fileNameWithoutExt.jar",
                "java -jar /tmp/$fileNameWithoutExt.jar",
            },
            cleanup_command = "rm /tmp/$fileNameWithoutExt.jar"
        },
        
        -- Interpreted languages
        python = "python3 -u $file",
        javascript = {
            "cd $dir",
            "node $fileName"
        },
        typescript = {
            "cd $dir",
            "bun $fileName"
        },
        lua = {
            "cd $dir",
            "lua $fileName"
        },
        ruby = "ruby $file",
        php = "php $file",
        perl = "perl $file",
        r = "Rscript $file",
        julia = "julia $file",
        
        -- Shell scripts
        sh = {
            "cd $dir",
            "bash $fileName"
        },
        zsh = {
            "cd $dir",
            "zsh $fileName"
        },
        
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
            cleanup_command = "rm /tmp/$fileNameWithoutExt"
        },
    },

    -- Spinner configuration
    spinner = "dots",        -- Spinner type: "dots", "line", "bar", "clock", "arrows", "dots2", "triangle", "square", "circle", "arrow", "box"
    spinner_speed = 80,      -- Speed in milliseconds
    
    -- Output configuration
    show_stderr_prefix = false,  -- Whether to prefix stderr output with [STDERR] (default: false for better UX)

    -- Project configuration
    -- Pattern matching for project root detection
    project = {
        -- Example Node.js project:
        -- [vim.fn.expand("~/projects/myapp") .. "/.*"] = {
        --     name = "My Node.js App",
        --     description = "My awesome web application",
        --     command = "npm run dev",
        -- },
        
        -- Example Rust project:
        -- [vim.fn.expand("~/rust/myproject") .. "/.*"] = {
        --     name = "My Rust Project",
        --     description = "Rust application",
        --     command = "cargo run",
        -- },
    },

    -- UI configuration for the floating window
    float = {
        border = "rounded", -- Border style: "none", "single", "double", "rounded", "solid", "shadow"
        height = 0.8,       -- Window height (0.0 to 1.0 = percentage of editor height)
        width = 0.8,        -- Window width (0.0 to 1.0 = percentage of editor width)
        x = 0.5,            -- Horizontal position (0.0 = left, 0.5 = center, 1.0 = right)
        y = 0.5,            -- Vertical position (0.0 = top, 0.5 = center, 1.0 = bottom)
        border_hl = "FloatBorder", -- Highlight group for the border
        close_key = "q",    -- Key to close the window
        focus = true,       -- Auto-focus the window on open
        startinsert = false,-- Enter insert mode when the window opens
    },

    -- Terminal configuration for split/vsplit/tab modes
    term = {
        position = "bot",   -- Position: "bot", "top", "left", "right"
        size = 15,          -- Size in lines (for horizontal) or columns (for vertical)
        focus = true,       -- Focus on terminal after opening
        startinsert = true, -- Start in insert mode
    },
}

-- This will hold the merged user and default configuration
M.options = {}



-- A setup function for users to call.
-- It will merge their provided options with the defaults.
function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
    
    M.setup_keymaps()
end

function M.setup_keymaps()
    if not M.options.keymaps then
        return
    end
    for _, keymap in ipairs(M.options.keymaps) do
        vim.keymap.set(keymap[1], keymap[2], keymap[3], keymap[4])
    end
end

-- Initialize with default options
M.setup()

return M
