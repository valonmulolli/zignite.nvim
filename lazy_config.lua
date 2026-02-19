local keys = {
  { "<leader>r", "<cmd>RunFile<cr>", desc = "Run file" },
  { "<leader>rb", "<cmd>RunBuildSelect<cr>", desc = "Select build command" },
  { "<leader>rq", "<cmd>RunClose<cr>", desc = "Close runner" },
  { "<leader>rt", "<cmd>RunFile tab<cr>", desc = "Run file in tab" },
  { "<leader>rv", "<cmd>RunFile vsplit<cr>", desc = "Run file in vsplit" },
  { "<leader>rh", "<cmd>RunFile split<cr>", desc = "Run file in split" },
  { "<leader>rp", "<cmd>RunProject<cr>", desc = "Run project" },
  { "<leader>rl", "<cmd>RunLive<cr>", desc = "Run live/watch command" },
  { "<leader>rs", "<cmd>StopCode<cr>", desc = "Stop running code" },
}

return {
  {
    "valonmulolli/zignite.nvim",
    build = "cd zig && zig build -Doptimize=ReleaseFast",
    lazy = false,
    keys = keys,
    config = function()
      require("zignite.config").setup({
        -- Keymaps are managed by Lazy above.
        keymaps = {},
        mode = "float",
        runners = {
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
              "clang++ $fileName -o /tmp/$fileNameWithoutExt",
              "/tmp/$fileNameWithoutExt",
            },
            cleanup_command = "rm /tmp/$fileNameWithoutExt",
          },
        },

        -- Optional execution behavior.
        timeout = nil,
        quickfix = {
          enabled = true,
          max_lines = 1000,
          strip_ansi = true,
        },

        -- Keep your compact runner window style.
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
    end,
  },
}
