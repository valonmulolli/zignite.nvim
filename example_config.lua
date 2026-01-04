-- ============================================================================
-- Zignite.nvim - Complete Example Configuration
-- ============================================================================
-- This file shows all available configuration options with examples
-- Copy and modify sections you need for your setup
-- ============================================================================

require("zignite.config").setup({
    
    -- ========================================================================
    -- KEYMAPS
    -- ========================================================================
    keymaps = {
        -- File execution
        { "n", "<leader>r", ":RunFile<CR>", { desc = "Run file" } },
        { "n", "<leader>rf", ":RunFile<CR>", { desc = "Run file" } },
        
        -- Build command picker (NEW!)
        { "n", "<leader>rb", ":RunBuildSelect<CR>", { desc = "Select build command" } },
        
        -- Project execution
        { "n", "<leader>rp", ":RunProject<CR>", { desc = "Run project" } },
        
        -- Output modes
        { "n", "<leader>rt", ":RunFile tab<CR>", { desc = "Run file in new tab" } },
        { "n", "<leader>rv", ":RunFile vsplit<CR>", { desc = "Run file in vertical split" } },
        { "n", "<leader>rh", ":RunFile split<CR>", { desc = "Run file in horizontal split" } },
        
        -- Control
        { "n", "<leader>rq", ":RunClose<CR>", { desc = "Close runner" } },
        { "n", "<leader>rs", ":StopCode<CR>", { desc = "Stop execution" } },
    },
    
    -- ========================================================================
    -- OUTPUT MODE
    -- ========================================================================
    -- Default mode: "float", "tab", "split", "vsplit"
    mode = "float",
    
    -- ========================================================================
    -- FILETYPE RUNNERS
    -- ========================================================================
    -- Commands for running single files
    runners = {
        -- Compiled languages
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
        
        go = "go run $file",
        zig = "zig run $file",
        
        -- Interpreted languages
        python = "python3 -u $file",
        javascript = { "cd $dir", "node $fileName" },
        typescript = { "cd $dir", "bun $fileName" },
        lua = { "cd $dir", "lua $fileName" },
        ruby = "ruby $file",
        php = "php $file",
        odin = "odin run $file",
        fortran = {
            cmd = {
                "cd $dir",
                "gfortran $fileName -o /tmp/$fileNameWithoutExt",
                "/tmp/$fileNameWithoutExt",
            },
            cleanup_command = "rm /tmp/$fileNameWithoutExt"
        },
    },
    
    -- ========================================================================
    -- BUILD COMMANDS (NEW!)
    -- ========================================================================
    -- Project-level build commands (cargo build, zig build, etc.)
    build_commands = {
        -- Rust
        rust = {
            build = "cargo build",
            run = "cargo run",
            test = "cargo test",
            release = "cargo build --release",
            ["release-run"] = "cargo run --release",
            check = "cargo check",
            clean = "cargo clean",
            
            -- Add custom commands
            bench = "cargo bench",
            doc = "cargo doc --open",
            clippy = "cargo clippy",
            fmt = "cargo fmt",
        },
        
        -- Zig
        zig = {
            build = "zig build",
            run = "zig build run",
            test = "zig build test",
            release = "zig build -Doptimize=ReleaseFast",
            ["release-run"] = "zig build run -Doptimize=ReleaseFast",
            
            -- Add custom commands
            debug = "zig build -Doptimize=Debug",
            small = "zig build -Doptimize=ReleaseSmall",
        },
        
        -- Go
        go = {
            build = "go build",
            run = "go run .",
            test = "go test ./...",
            clean = "go clean",
            mod = "go mod tidy",
            
            -- Add custom commands
            vet = "go vet ./...",
            fmt = "go fmt ./...",
        },
        
        -- Odin
        odin = {
            build = "odin build .",
            run = "odin run .",
            test = "odin test .",
            release = "odin build . -o:speed",
            check = "odin check .",
        },
        
        -- Fortran
        fortran = {
            build = "gfortran *.f90 -o main",
            run = "gfortran *.f90 -o main && ./main",
            clean = "rm main",
        },
        
        -- JavaScript/TypeScript
        javascript = {
            start = "npm start",
            dev = "npm run dev",
            build = "npm run build",
            test = "npm test",
            install = "npm install",
            
            -- Or use yarn
            -- start = "yarn start",
            -- dev = "yarn dev",
            -- build = "yarn build",
        },
        
        typescript = {
            start = "npm start",
            dev = "npm run dev",
            build = "npm run build",
            test = "npm test",
        },
        
        -- Python
        python = {
            run = "python -m main",
            test = "pytest",
            install = "pip install -r requirements.txt",
            
            -- Or use poetry
            -- run = "poetry run python -m main",
            -- test = "poetry run pytest",
            -- install = "poetry install",
        },
        
        -- C/C++ with Make, CMake, and Meson support
        c = {
            -- Make commands
            build = "make",
            run = "make run",
            clean = "make clean",
            test = "make test",
            install = "make install",
            debug = "make debug",
            
            -- CMake commands
            ["cmake-config"] = "cmake -B build",
            ["cmake-build"] = "cmake --build build",
            ["cmake-run"] = "cmake --build build && ./build/main",
            ["cmake-clean"] = "rm -rf build",
            ["cmake-debug"] = "cmake -B build -DCMAKE_BUILD_TYPE=Debug && cmake --build build",
            ["cmake-release"] = "cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build",
            
            -- Meson commands
            ["meson-setup"] = "meson setup build",
            ["meson-build"] = "meson compile -C build",
            ["meson-run"] = "meson compile -C build && ./build/main",
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
            ["cmake-config"] = "cmake -B build",
            ["cmake-build"] = "cmake --build build",
            ["cmake-run"] = "cmake --build build && ./build/main",
            ["cmake-clean"] = "rm -rf build",
            ["cmake-debug"] = "cmake -B build -DCMAKE_BUILD_TYPE=Debug && cmake --build build",
            ["cmake-release"] = "cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build",
            ["cmake-test"] = "cd build && ctest",
            
            -- Meson commands
            ["meson-setup"] = "meson setup build",
            ["meson-build"] = "meson compile -C build",
            ["meson-run"] = "meson compile -C build && ./build/main",
            ["meson-clean"] = "rm -rf build",
            ["meson-test"] = "meson test -C build",
        },
    },
    
    -- ========================================================================
    -- PROJECT CONFIGURATION
    -- ========================================================================
    -- Pattern matching for project root detection
    project = {
        -- Example: Zig project
        [vim.fn.expand("~/Dev/myzig") .. "/.*"] = {
            name = "My Zig Project",
            command = "zig build run",
        },
        
        -- Example: Rust project with release mode
        [vim.fn.expand("~/Dev/rustapp") .. "/.*"] = {
            name = "Rust Application",
            command = "cargo run --release",
        },
        
        -- Example: Node.js project
        [vim.fn.expand("~/Dev/webapp") .. "/.*"] = {
            name = "Web Application",
            command = "npm run dev",
        },
        
        -- Example: Go project
        [vim.fn.expand("~/Dev/goapp") .. "/.*"] = {
            name = "Go Application",
            command = "go run .",
        },
    },
    
    -- ========================================================================
    -- UI CONFIGURATION
    -- ========================================================================
    
    -- Floating window settings
    float = {
        border = "rounded",        -- "none", "single", "double", "rounded", "solid", "shadow"
        height = 0.8,              -- 0.0 to 1.0 (percentage of editor height)
        width = 0.8,               -- 0.0 to 1.0 (percentage of editor width)
        x = 0.5,                   -- 0.0 = left, 0.5 = center, 1.0 = right
        y = 0.5,                   -- 0.0 = top, 0.5 = center, 1.0 = bottom
        border_hl = "FloatBorder", -- Highlight group for the border
        close_key = "<Esc>",       -- Key to close the window
        focus = true,              -- Auto-focus the window on open
        startinsert = false,       -- Enter insert mode when the window opens
    },
    
    -- Terminal settings (for split/vsplit/tab modes)
    term = {
        position = "bot",          -- "bot", "top", "left", "right"
        size = 15,                 -- Size in lines (for horizontal) or columns (for vertical)
        focus = true,              -- Focus on terminal after opening
        startinsert = true,        -- Start in insert mode
    },
    
    -- ========================================================================
    -- ANIMATIONS & OUTPUT
    -- ========================================================================
    
    -- Spinner configuration
    spinner = "dots",              -- "dots", "line", "bar", "arrows", "dots2", etc.
    spinner_speed = 80,            -- Speed in milliseconds
    enable_animations = true,      -- Enable/disable animations and spinners
    
    -- Execution configuration
    timeout = nil,                 -- Timeout in ms (e.g. 5000). nil = disabled.
    
    -- Output configuration
    show_stderr_prefix = false,    -- Whether to prefix stderr with [STDERR]
    no_stderr_prefix_types = {"zig", "go", "rust"}, -- Languages that use stderr normally
    
    -- Stderr filtering (NEW!)
    -- Hide common warnings while preserving errors
    stderr_filters = {
        "MODULE_TYPELESS_PACKAGE_JSON",  -- Node.js module type warnings
        "ExperimentalWarning",            -- Node.js experimental features
        "DeprecationWarning",             -- Deprecation warnings
        "Use `node --trace-warnings",    -- Node.js trace suggestions
        "To eliminate this warning",     -- Generic warning hints
    },
})

-- ============================================================================
-- ADDITIONAL CONFIGURATION EXAMPLES
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Language-Specific Keymaps (Recommended!)
-- ----------------------------------------------------------------------------
-- Show picker for compiled languages, run directly for scripting languages

vim.api.nvim_create_autocmd("FileType", {
    pattern = {"rust", "zig", "go", "c", "cpp"},
    callback = function()
        -- Override <leader>r to show picker for compiled languages
        vim.keymap.set("n", "<leader>r", ":RunBuildSelect<CR>", { 
            buffer = true, 
            desc = "Select build command" 
        })
    end,
})

-- ----------------------------------------------------------------------------
-- Filetype-Specific Quick Commands
-- ----------------------------------------------------------------------------

-- Rust: Quick commands
vim.api.nvim_create_autocmd("FileType", {
    pattern = "rust",
    callback = function()
        vim.keymap.set("n", "<F5>", ":RunBuild run<CR>", { buffer = true, desc = "Cargo run" })
        vim.keymap.set("n", "<F6>", ":RunBuild test<CR>", { buffer = true, desc = "Cargo test" })
        vim.keymap.set("n", "<F7>", ":RunBuild check<CR>", { buffer = true, desc = "Cargo check" })
    end,
})

-- Zig: Quick commands
vim.api.nvim_create_autocmd("FileType", {
    pattern = "zig",
    callback = function()
        vim.keymap.set("n", "<F5>", ":RunBuild run<CR>", { buffer = true, desc = "Zig run" })
        vim.keymap.set("n", "<F6>", ":RunBuild test<CR>", { buffer = true, desc = "Zig test" })
    end,
})

-- C/C++: Quick commands
vim.api.nvim_create_autocmd("FileType", {
    pattern = {"c", "cpp"},
    callback = function()
        vim.keymap.set("n", "<F5>", ":RunBuild run<CR>", { buffer = true, desc = "Make run" })
        vim.keymap.set("n", "<F6>", ":RunBuild build<CR>", { buffer = true, desc = "Make build" })
        vim.keymap.set("n", "<F7>", ":RunBuild test<CR>", { buffer = true, desc = "Make test" })
        vim.keymap.set("n", "<F8>", ":RunBuild cmake-run<CR>", { buffer = true, desc = "CMake run" })
    end,
})

-- ============================================================================
-- USAGE EXAMPLES
-- ============================================================================

-- Single file execution:
--   nvim test.c
--   :RunFile              → Compiles and runs test.c
--   <leader>r             → Same as above

-- Build command (direct):
--   nvim src/main.rs
--   :RunBuild run         → Runs cargo run
--   :RunBuild test        → Runs cargo test
--   :RunBuild release     → Runs cargo build --release

-- Build command (picker):
--   nvim src/main.rs
--   <leader>rb            → Shows picker with all cargo commands
--   Select and run!

-- Project execution:
--   nvim ~/Dev/myzig/src/main.zig
--   :RunProject           → Runs zig build run (from project root)
--   <leader>rp            → Same as above

-- Different output modes:
--   :RunFile split        → Run in horizontal split
--   :RunFile vsplit       → Run in vertical split
--   :RunFile tab          → Run in new tab
--   :RunBuild test split  → Run tests in split

-- Visual selection:
--   Select code in visual mode
--   :'<,'>RunCode         → Runs selected code

-- ============================================================================
-- AVAILABLE COMMANDS
-- ============================================================================

-- :RunFile [mode]           - Run current file
-- :RunCode                  - Run visual selection
-- :RunProject [mode]        - Run project command
-- :RunBuild <command>       - Run specific build command
-- :RunBuildSelect [mode]    - Show command picker (NEW!)
-- :RunClose                 - Close output window
-- :StopCode                 - Stop running process

-- ============================================================================
-- QUICK REFERENCE
-- ============================================================================

-- Default Keymaps:
--   <leader>r   → Run file
--   <leader>rb  → Show build command picker
--   <leader>rp  → Run project
--   <leader>rq  → Close runner
--   <leader>rt  → Run in tab
--   <leader>rv  → Run in vsplit
--   <leader>rh  → Run in split

-- Build Commands (examples):
--   Rust:  build, run, test, release, check, clean
--   Zig:   build, run, test, release
--   Go:    build, run, test, clean, mod
--   C/C++: build, run, test, cmake-run, meson-run
--   JS/TS: start, dev, build, test, install

-- ============================================================================
-- DOCUMENTATION
-- ============================================================================

-- See these files for more information:
--   • README.md              - User documentation
--   • doc/zignite.txt        - Vim help file
