# Contributing

## Development model

This repo uses a split architecture:

- Lua for Neovim integration, UI, prompting, and transport glue
- Zig for backend parsing, command inference, detection, quickfix processing, and execution planning

Before adding new logic, check whether it belongs in the Lua runtime layer or the Zig backend layer.

The detailed architecture overview lives in:

- `docs/architecture.md`

## Local validation

Run these before committing:

```sh
~/.luarocks/bin/luacheck lua --codes
lua test/runner.lua
cd zig && zig build test
```

If you changed shipped Zig code paths, also run:

```sh
cd zig && zig build
```

That catches executable-level issues that may not show up in `zig build test` alone.

## Where changes should go

### New project parser

Usually add it here:

- `zig/src/project/<kind>/api.zig`
- `zig/src/project/<kind>/*.zig`

Then wire:

- `zig/src/project/core/emit/*.zig`
- `zig/src/project/core/auto.zig` if source-path auto resolution is needed

### New warmed system query

Usually add it here:

- `zig/src/build/system.zig`

Then wire the Lua bridge side:

- `lua/zignite/rpc/*`
- `lua/zignite/init.lua` only if a Neovim-facing command or UI flow needs to call it
- prefer extending backend response contracts instead of adding new Lua-side reconstruction logic

### New Neovim UI behavior

Usually add it here:

- `lua/zignite/ui/*`
- `lua/zignite/ui/build_picker/*`
- `lua/zignite/init.lua`

## Expectations

- Prefer Zig for parsing and command inference
- Prefer Lua for editor integration, prompting, and runtime behavior that depends on Neovim APIs
- When a behavior can live in Zig without needing Neovim APIs, prefer pushing it into the backend
- Keep public module surfaces stable unless there is a strong reason to break them
- Add regression coverage for:
  - warmed cache behavior
  - async refresh behavior
  - daemon/one-shot fallback behavior

## Good contributions

Examples of changes that fit the current direction:

- moving command synthesis from Lua into Zig records
- adding system queries that warm cached command sets
- simplifying Lua bridge code without breaking the public module surface
- expanding real integration coverage for supported build systems
