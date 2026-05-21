# Architecture

Zignite is a Zig-first Neovim plugin.

The current split is:
- Lua handles plugin setup, config, RPC transport, picker/window UI, and thin controller flow.
- Zig handles config interpretation, filetype normalization, build/run resolution, project parsing, system detection, command detection, quickfix processing, and execution support.

## Lua Frontend

Current Lua tree:
- `lua/zignite/config.lua`
- `lua/zignite/init.lua`
- `lua/zignite/rpc/*`
- `lua/zignite/ui/*`
- `lua/zignite/ui/build_picker/*`

Responsibilities:
- register commands like `:RunFile`, `:RunBuildSelect`, `:RunLive`, and `:StopCode`
- collect current editor context such as file path, filetype, and visual selections
- sync config to the Zig daemon
- send build/run resolve requests to Zig
- normalize backend payloads at the RPC boundary before handing them to controller/UI code
- render picker, terminal windows, spinner, and quickfix UI
- maintain small editor-local state such as the last selected build command

Intentional Lua-only behavior:
- visual-selection temp file handling
- Neovim job/window lifecycle
- picker/filter/input UI

## Zig Backend

Current Zig tree:
- `zig/src/main.zig`
- `zig/src/daemon.zig`
- `zig/src/config/*`
- `zig/src/filetype.zig`
- `zig/src/build/resolve/*`
- `zig/src/runtime/resolve/*`
- `zig/src/build/system/*`
- `zig/src/project/*`
- `zig/src/detect/*`
- `zig/src/quickfix/*`

Responsibilities:
- parse synced config through `zig/src/config/view.zig`, keyed by store generation
- normalize filetypes from Neovim filetype, extension, and shebang
- resolve build commands, preferred commands, live command names, and selected-command execution payloads
- resolve runners, argv, cwd, cleanup commands, and display names
- detect build systems and project roots
- parse project files such as `Cargo.toml`, `package.json`, `go.mod`, `go.work`, `pom.xml`, `build.gradle.kts`, `CMakeLists.txt`, `meson.build`, `MODULE.bazel`, and `pyproject.toml`
- process quickfix output and diagnostics
- expose direct CLI modes plus a unified framed daemon protocol

## Request Flow

### Run file
1. Lua collects the current file path and filetype.
2. Lua syncs config if needed.
3. Lua sends `--run-resolve` to the Zig backend.
4. Zig returns a JSON-first resolved runner payload containing the final command, argv, cwd, cleanup command, source, and display name.
5. Lua opens a terminal window and executes the resolved command.

### Build picker / build execution
1. Lua collects the current file path and filetype.
2. Lua syncs config if needed.
3. Lua sends `--build-resolve` to the Zig backend.
4. Zig returns:
   - command list
   - command metadata
   - preferred commands
   - preferred live command name
5. Lua renders the picker.
6. When the user selects a command, Lua sends a command-specific `--build-resolve` request.
7. Zig returns a JSON-first execution payload containing:
   - final command
   - argv
   - cwd
   - display name
   - config revision
8. Lua launches the terminal job.

### Quickfix
1. Lua collects the terminal output.
2. In `quickfix.processor = "auto"` mode, Lua prefers the Zig quickfix path when the backend is available, and falls back to Lua processing otherwise.
3. Zig can strip ANSI, tail large outputs, and normalize diagnostics.
4. Lua publishes the resulting quickfix list to Neovim.

## Supported Project Lanes

The backend currently has real fixture coverage for:
- Bazel
- Bun
- Cargo
- CMake
- Go modules
- Go workspaces
- Gradle
- Maven
- Meson
- Node / package.json
- Python with `uv`
- Python with `requirements.txt` / `pip`
- Python with conda (`environment.yml` and `environment.yaml`)

Python support is intentionally limited to:
- `uv`
- `pip` / `requirements.txt`
- conda

The backend does not intentionally support Poetry, PDM, or Hatch.

## Testing Strategy

There are two main layers:

### Lua/frontend tests
- `lua test/runner.lua`
- `test/integration/*`

These cover:
- config/setup behavior
- picker/controller behavior
- quickfix UI behavior
- Lua-to-backend RPC behavior through a simulator

### Zig/backend tests
- `cd zig && zig build test`

These cover:
- direct resolver behavior
- project parsers
- build-system detection
- quickfix backend logic
- fixture-based backend scenarios under `test/fixtures/backend/*`

### Benchmarks
- `cd zig && zig build bench-fast`
- `cd zig && zig build bench`

These measure direct and daemon-backed resolver performance, plus quickfix
processing benchmarks.

## Design Rules

When extending the codebase:
- prefer putting new resolution or inference logic in Zig, not Lua
- keep Lua focused on Neovim integration and UI
- route config interpretation through `zig/src/config/view.zig`
- avoid reintroducing raw JSON parsing into resolver code
- prefer fixture-based backend tests for new project-detection behavior
