# Architecture

`zignite.nvim` is split into two layers:

- Lua owns the Neovim runtime layer
- Zig owns parsing, backend execution, and build-system intelligence

That split is intentional. The Lua side should stay focused on editor behavior, caching, and user-facing policy. The Zig side should stay focused on command inference, project parsing, detection, and quickfix processing.

## Ownership

### Lua

Lua is the Neovim-facing runtime.

Main areas:

- `lua/zignite/init.lua`
  - user commands like `RunFile`, `RunBuild`, `RunLive`
  - source context resolution
  - runner setup
- `lua/zignite/build/`
  - `project_query.lua`: query/decode/cache adapter for Zig project records
  - `command_policy.lua`: final merge and override policy
  - `runtime_lookup.lua`: cached lookup and async refresh
  - `system_runtime.lua`: hot-path local root checks and warmed system cache reuse
  - `picker*.lua`: build picker UI
  - `detect/*.lua`: backend transport and detect caching
- `lua/zignite/runtime/`
  - argv shaping
  - command normalization
  - runtime execution helpers
- `lua/zignite/ui/`
  - windows
  - spinner
  - quickfix publishing

Lua should not grow new parser-heavy logic when Zig can own it cleanly.

### Zig

Zig is the backend.

Top-level entrypoints:

- `zig/src/main.zig`
- `zig/src/daemon.zig`
- `zig/src/command.zig`
- `zig/src/detect.zig`
- `zig/src/quickfix.zig`
- `zig/src/project.zig`

Subsystem layout:

- `zig/src/build/`
  - shared build-system helpers
  - warmed system/root queries
- `zig/src/project/core/`
  - shared project parser infrastructure
  - auto-kind dispatch
  - output emission
- `zig/src/project/<kind>/`
  - project-specific parser implementations
- `zig/src/detect/`
  - detect parsing and template rendering
- `zig/src/quickfix/`
  - ANSI stripping, tailing, diagnostic normalization

## Runtime flow

### RunFile

`RunFile` stays mostly Lua-owned.

Flow:

1. `lua/zignite/init.lua` resolves the source path and filetype
2. Lua chooses the filetype runner
3. smart runner defaults may consult warmed Zig system state
4. `lua/zignite/runtime/*` normalizes argv/shell execution
5. `zig/src/command.zig` executes the final process

### RunBuild / RunLive

`RunBuild` and `RunLive` are mixed Lua/Zig flows.

Flow:

1. `lua/zignite/build/runtime_lookup.lua` asks for cached commands first
2. `lua/zignite/build/project_query.lua` decodes warmed Zig project/system records
3. `lua/zignite/build/command_policy.lua` merges:
   - defaults
   - configured overrides
   - Zig project commands
   - Zig system commands
   - tool-detect commands
4. async refresh warms richer Zig results in the background
5. final execution goes through `lua/zignite/runtime/*` and `zig/src/command.zig`

### Quickfix

Quickfix is backend-heavy by design.

Flow:

1. terminal output is captured in Lua
2. non-zero exits may trigger quickfix processing
3. `zig/src/quickfix.zig` handles:
   - tail limiting
   - ANSI stripping
   - diagnostic normalization
4. Lua publishes the final quickfix list into Neovim

## Backend contracts

The Lua side should treat backend record formats as stable contracts.

Main project/system records:

- `COMMAND\t<name>\t<command>`
- `ROOT\t<path>`
- `SYSTEM\t<name>`
- `BUILD_READY\t0|1`

Additional project-specific records may appear, but the `COMMAND`/`ROOT`/`SYSTEM` contract is the core interface used by the Lua build layer.

## System queries

System queries are the warmed, low-cost backend answers used by cached lookup.

Current queries include:

- `c-family`
- `bazel-root`
- `jvm-root`
- `node-root`
- `python-root`

These live in:

- `zig/src/build/system.zig`

Lua should prefer warmed system results when available, but still keep hot-path local checks nonblocking.

## Auto project kinds

Auto kinds map a source file path to the relevant project file or workspace.

Examples:

- `cargo-auto`
- `go-auto`
- `jvm-auto`
- `c-family-auto`
- `bazel-auto`
- `package-json-auto`
- `python-auto`

These live in:

- `zig/src/project/core/auto.zig`

## Adding a new project parser

Use this path:

1. add parser implementation under `zig/src/project/<kind>/`
2. expose public parser API via `zig/src/project/<kind>/api.zig`
3. teach `zig/src/project/core/emit/*.zig` how to emit final records
4. if source-path resolution is needed, wire auto-kind logic in `zig/src/project/core/auto.zig`
5. only add Lua changes if the runtime layer actually needs a new policy or cache path

Preferred outcome:

- Zig emits final command records
- Lua consumes those records without reconstructing them

## Adding a new system query

Use this path:

1. add query enum and parser handling in `zig/src/build/system.zig`
2. emit baseline `COMMAND` records there if the query should supply warmed commands
3. ensure `zig/src/project/core/auto.zig` writes the query result when `kind == .system`
4. add warmed-cache handling in `lua/zignite/build/system_runtime.lua`
5. consume that warmed result in `lua/zignite/build/project_query.lua` or `lua/zignite/build/command_policy.lua`

Preferred outcome:

- Lua does not invent baseline commands that Zig can emit directly

## What should stay in Lua

These are good Lua responsibilities:

- Neovim UI
- user command entrypoints
- config merge semantics
- cached lookup orchestration
- hot-path local gating that must stay nonblocking

## What should move to Zig when possible

These are good Zig responsibilities:

- parser logic
- command inference
- build-system baseline command sets
- workspace/source-path resolution
- quickfix processing
- tool detection parsing

## Current rule of thumb

If a change answers:

- "what project is this?"
- "what commands should exist?"
- "what is the preferred command?"
- "how do we parse this file or tool output?"

it should usually land in Zig first.

If a change answers:

- "how do we show this in Neovim?"
- "how do we merge user config?"
- "how do we keep the picker/runtime nonblocking?"

it should usually land in Lua.
