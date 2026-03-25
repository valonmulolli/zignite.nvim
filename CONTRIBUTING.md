# Contributing

## Development model

This repo uses a split architecture:

- Lua for Neovim runtime, UI, caching, and config policy
- Zig for backend parsing, command inference, detection, and quickfix processing

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

Then wire the Lua runtime side:

- `lua/zignite/build/system_runtime.lua`
- `lua/zignite/build/project_query.lua`
- `lua/zignite/build/command_policy.lua` only if user-facing merge policy is required

### New Neovim UI behavior

Usually add it here:

- `lua/zignite/ui/*`
- `lua/zignite/build/picker*`
- `lua/zignite/init.lua`

### New command policy

Usually add it here:

- `lua/zignite/build/command_policy.lua`

But if Zig can emit a better final command contract, prefer that instead of adding another Lua-side reconstruction path.

## Expectations

- Prefer Zig for parsing and command inference
- Prefer Lua for editor integration and nonblocking runtime behavior
- Keep public module surfaces stable unless there is a strong reason to break them
- Add regression coverage for:
  - warmed cache behavior
  - async refresh behavior
  - daemon/one-shot fallback behavior

## Good contributions

Examples of changes that fit the current direction:

- moving command synthesis from Lua into Zig records
- adding system queries that warm cached command sets
- simplifying Lua runtime code without breaking the public module surface
- expanding real integration coverage for supported build systems
