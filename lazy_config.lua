return {
  {
    "valonmulolli/zignite.nvim",
    build = "cd zig && zig build",
    lazy = false,  -- Load on startup, not lazy
    keys = {
      { "<leader>r", "<cmd>RunFile<cr>", desc = "Run file" },
      { "<leader>rb", "<cmd>RunBuildSelect<cr>", desc = "Select build command" },
      { "<leader>rq", "<cmd>RunClose<cr>", desc = "Close runner" },
      { "<leader>rt", "<cmd>RunFile tab<cr>", desc = "Run file in tab" },
      { "<leader>rv", "<cmd>RunFile vsplit<cr>", desc = "Run file in vsplit" },
      { "<leader>rh", "<cmd>RunFile split<cr>", desc = "Run file in split" },
      { "<leader>rp", "<cmd>RunProject<cr>", desc = "Run project" },
      { "<leader>rs", "<cmd>StopCode<cr>", desc = "Stop running code" },
    },
    config = function()
      require("zignite.config").setup({
        -- ====================================================================
        -- KEYMAPS
        -- ====================================================================
        keymaps = {
          { "n", "<leader>r", ":RunFile<CR>", { desc = "Run file" } },
          { "n", "<leader>rb", ":RunBuildSelect<CR>", { desc = "Select build command" } }, -- NEW!
          { "n", "<leader>rq", ":RunClose<CR>", { desc = "Close runner" } },
          { "n", "<leader>rt", ":RunFile tab<CR>", { desc = "Run file in new tab" } },
          { "n", "<leader>rv", ":RunFile vsplit<CR>", { desc = "Run file in vertical split" } },
          { "n", "<leader>rh", ":RunFile split<CR>", { desc = "Run file in horizontal split" } },
          { "n", "<leader>rp", ":RunProject<CR>", { desc = "Run project" } },
          { "n", "<leader>rs", ":StopCode<CR>", { desc = "Stop running code" } },
        },
        
        -- ====================================================================
        -- OUTPUT MODE
        -- ====================================================================
        mode = "float",
        
        -- ====================================================================
        -- FILETYPE RUNNERS
        -- ====================================================================
        runners = {
          -- Compiled languages
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
              "clang++ $fileName -std=c++23 -o /tmp/$fileNameWithoutExt",
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
          javascript = {
            "cd $dir",
            "node $fileName",
          },
          typescript = {
            "cd $dir",
            "bun $fileName",
          },
          lua = {
            "cd $dir",
            "lua $fileName",
          },
          ruby = "ruby $file",
          php = "php $file",
          perl = "perl $file",
          r = "Rscript $file",
          julia = "julia $file",
          
          -- Shell scripts
          sh = {
            "cd $dir",
            "bash $fileName",
          },
          zsh = {
            "cd $dir",
            "zsh $fileName",
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
            cleanup_command = "rm /tmp/$fileNameWithoutExt",
          },
          odin = "odin run $file",
          fortran = {
            cmd = {
              "cd $dir",
              "gfortran $fileName -o /tmp/$fileNameWithoutExt",
              "/tmp/$fileNameWithoutExt",
            },
            cleanup_command = "rm /tmp/$fileNameWithoutExt",
          },
        },
        
        -- ====================================================================
        -- BUILD COMMANDS (NEW!)
        -- ====================================================================
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
          },
          
          -- Zig
          zig = {
            build = "zig build",
            run = "zig build run",
            test = "zig build test",
            release = "zig build -Doptimize=ReleaseFast",
            ["release-run"] = "zig build run -Doptimize=ReleaseFast",
          },
          
          -- Go
          go = {
            build = "go build",
            run = "go run .",
            test = "go test ./...",
            clean = "go clean",
            mod = "go mod tidy",
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
          },
          
          -- C/C++ with Make, CMake, and Meson
          c = {
            -- Make
            build = "make",
            run = "make run",
            clean = "make clean",
            test = "make test",
            install = "make install",
            debug = "make debug",
            
            -- CMake
            ["cmake-config"] = "cmake -B build",
            ["cmake-build"] = "cmake --build build",
            ["cmake-run"] = "cmake --build build && ./build/main",
            ["cmake-clean"] = "rm -rf build",
            ["cmake-debug"] = "cmake -B build -DCMAKE_BUILD_TYPE=Debug && cmake --build build",
            ["cmake-release"] = "cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build",
            
            -- Meson
            ["meson-setup"] = "meson setup build",
            ["meson-build"] = "meson compile -C build",
            ["meson-run"] = "meson compile -C build && ./build/main",
            ["meson-clean"] = "rm -rf build",
            ["meson-test"] = "meson test -C build",
          },
          
          cpp = {
            -- Make
            build = "make",
            run = "make run",
            clean = "make clean",
            test = "make test",
            install = "make install",
            debug = "make debug",
            
            -- CMake
            ["cmake-config"] = "cmake -B build",
            ["cmake-build"] = "cmake --build build",
            ["cmake-run"] = "cmake --build build && ./build/main",
            ["cmake-clean"] = "rm -rf build",
            ["cmake-debug"] = "cmake -B build -DCMAKE_BUILD_TYPE=Debug && cmake --build build",
            ["cmake-release"] = "cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build",
            ["cmake-test"] = "cd build && ctest",
            
            -- Meson
            ["meson-setup"] = "meson setup build",
            ["meson-build"] = "meson compile -C build",
            ["meson-run"] = "meson compile -C build && ./build/main",
            ["meson-clean"] = "rm -rf build",
            ["meson-test"] = "meson test -C build",
          },
        },
        
        -- ====================================================================
        -- ANIMATIONS & OUTPUT
        -- ====================================================================
        spinner = "dots",
        spinner_speed = 80,
        enable_animations = true,
        
        -- Execution configuration
        timeout = nil,  -- Timeout in ms (e.g. 5000). nil = disabled.
        
        -- Output configuration
        show_stderr_prefix = false,
        no_stderr_prefix_types = { "zig", "go", "rust" },
        
        -- Stderr filtering (NEW!)
        stderr_filters = {
          "MODULE_TYPELESS_PACKAGE_JSON",  -- Node.js module warnings
          "ExperimentalWarning",            -- Experimental features
          "DeprecationWarning",             -- Deprecations
          "Use `node --trace-warnings",    -- Trace suggestions
          "To eliminate this warning",     -- Warning hints
        },
        
        -- ====================================================================
        -- PROJECT CONFIGURATION
        -- ====================================================================
        project = {
          -- Add your custom projects here
          -- Example:
          -- [vim.fn.expand("~/Dev/myproject") .. "/.*"] = {
          --   name = "My Project",
          --   command = "cargo run --release",
          -- },
        },
        
        -- ====================================================================
        -- UI CONFIGURATION
        -- ====================================================================
        float = {
          border = "rounded",
          height = 0.15,
          width = 0.60,
          x = 1,
          y = 0.90,
          border_hl = "FloatBorder",
          close_key = "q",
          focus = true,
          startinsert = false,
        },
        
        term = {
          position = "bot",
          size = 5,
          focus = true,
          startinsert = true,
        },
      })
      
      -- No language-specific keymaps
    end,
  },
}
