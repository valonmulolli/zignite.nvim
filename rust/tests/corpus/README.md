# Backend Compatibility Corpus

This document freezes the behavior that the Rust backend must preserve during the
migration. It is a compatibility record, not a new production protocol.

## Baseline

The baseline was collected from commit `26fcb04` in the isolated rewrite
worktree on 2026-10-05.

| Command | Result | Notes |
|---|---|---|
| `(cd zig && zig build test)` | exit 0 | The test executable emits the existing `[Zignite] Process timed out after 50ms` diagnostic while exercising timeout behavior. This is expected test output, not a failed build. |
| `(cd zig && zig build -Doptimize=ReleaseFast)` | exit 0 | Release backend builds successfully with Zig 0.16.0. |
| `lua5.4 zig/test/runner.lua .` | exit 0 | `Test Results: 7 passed, 0 failed`; the runner reports all Lua and integration suites passed. |

The baseline is intentionally preserved before any Rust source exists.

## CLI Modes

The current executable advertises these interfaces in `zig/src/main.zig` and
`zig/src/dispatch.zig`:

- `--argv <program> [args...]`, with optional `--timeout=MS` and `--cleanup=CMD`
- `--daemon`
- `--config-sync --revision=<N>`
- `--quickfix [--max-lines=N] [--max-bytes=N] [--strip-ansi=0|1]`
- `--quickfix-daemon`
- `--detect --tool=zig|go|cargo|odin|dart|swift`
- `--detect-daemon`
- `--project-parse-daemon`
- `--project-parse --kind=<kind> --path=<absolute-path>`
- `--build-resolve --filetype=<ft> --path=<absolute-path>`
- `--build-action --action=named|live|last --filetype=<ft> --path=<absolute-path>`
- `--run-resolve --filetype=<ft> --path=<absolute-path>`

The Rust CLI must preserve the `--argv` boundary: arguments after `--argv`
belong to the child and must not be parsed as backend flags.

## Protocol Families

The current line protocol uses tab-prefixed body fields and exact marker lines.
The Rust implementation initially keeps these marker names for Lua
compatibility:

| Domain | Request | Response |
|---|---|---|
| Health | `@@ZHLT_REQ_BEGIN`, `@@ZHLT_REQ_END` | `@@ZHLT_RES_BEGIN`, `@@ZHLT_RES_ERR`, `@@ZHLT_RES_END` |
| Config | `@@ZCFG_REQ_BEGIN`, `@@ZCFG_REQ_END` | `@@ZCFG_RES_BEGIN`, `@@ZCFG_RES_ERR`, `@@ZCFG_RES_END` |
| Detection | `@@ZDET_REQ_BEGIN`, `@@ZDET_REQ_END` | `@@ZDET_RES_BEGIN`, `@@ZDET_RES_ERR`, `@@ZDET_RES_END` |
| Project | `@@ZPRJ_REQ_BEGIN`, `@@ZPRJ_REQ_END` | `@@ZPRJ_RES_BEGIN`, `@@ZPRJ_RES_ERR`, `@@ZPRJ_RES_END` |
| Build resolve | `@@ZBR_REQ_BEGIN`, `@@ZBR_REQ_END` | `@@ZBR_RES_BEGIN`, `@@ZBR_RES_ERR`, `@@ZBR_RES_END` |
| Build action | `@@ZBA_REQ_BEGIN`, `@@ZBA_REQ_END` | `@@ZBA_RES_BEGIN`, `@@ZBA_RES_ERR`, `@@ZBA_RES_END` |
| Run resolve | `@@ZRUN_REQ_BEGIN`, payload markers, `@@ZRUN_REQ_END` | `@@ZRUN_RES_BEGIN`, `@@ZRUN_RES_ERR`, `@@ZRUN_RES_END` |
| Quickfix | `@@ZQF_BEGIN`, `@@ZQF_END` | `@@ZQF_RES_BEGIN`, `@@ZQF_RES_ERR`, `@@ZQF_RES_END` |

### Known frame examples

Health request and response:

```text
@@ZHLT_REQ_BEGIN 1
@@ZHLT_RES_BEGIN 1
@@ZHLT_RES_END 1
```

Malformed detection header:

```text
@@ZDET_REQ_BEGIN 9 nope
@@ZDET_RES_BEGIN 9
@@ZDET_RES_ERR 9 InvalidDetectTool
@@ZDET_RES_END 9
```

Malformed project header:

```text
@@ZPRJ_REQ_BEGIN 11 extra
@@ZPRJ_RES_BEGIN 11
@@ZPRJ_RES_ERR 11 InvalidProjectDaemonHeader
@@ZPRJ_RES_END 11
```

Missing build-resolve path:

```text
@@ZBR_REQ_BEGIN 5
@@ZBR_REQ_END 5
@@ZBR_RES_BEGIN 5
@@ZBR_RES_ERR 5 MissingBuildResolvePath
@@ZBR_RES_END 5
```

Rust tests must also verify that a marker-looking value is emitted as a
body field and cannot terminate its enclosing frame early. Body values with
control characters are invalid and must return a structured error.

## Required Compatibility Cases

These cases are required by the rewrite design and must become executable Rust
or differential tests as the relevant modules land:

- marker-looking command output, including `@@Z*RES_END` text
- malformed and truncated request frames
- oversized input lines and bounded reads
- missing executables with a structured tool name
- invalid commands and non-zero child exit status
- timeout and descendant cleanup on Unix
- timeout and descendant cleanup using Windows process/job handles
- Windows paths and `.exe` executable resolution
- interactive stdin forwarding for final terminal programs
- empty stdout/stderr
- cleanup command ordering and cleanup failure reporting
- CRLF input and exact marker matching
- marker-name prefix rejection, such as `@@ZHLT_REQ_BEGINNING`

## Process Behavior Already Tested by Zig

The current Zig unit tests cover:

- preserving non-zero child exit codes
- Unix timeout termination including descendants
- Unix force-kill after a child ignores graceful termination
- Windows timeout termination of a suspended child
- Windows descendant termination and reaping
- a 100 ms timeout grace period in the process-tree coordinator

The Rust process tests must retain these behaviors without relying solely on a
recycled PID or an unowned process identifier.

## Project Fixture Manifest

The fixtures remain under `zig/test_fixtures/` while the Zig compatibility
tests still run. They will move to `test_fixtures/` when the Zig backend and
its test package are removed:

| Fixture root | Primary project-system coverage |
|---|---|
| `bazel` | Bazel module/workspace/build discovery |
| `bun` | Bun package scripts |
| `cargo` | Cargo project commands |
| `cmake` | CMake configure/build metadata |
| `go` | Go module commands |
| `go_work` | Go workspace commands |
| `gradle` | Gradle task discovery |
| `maven` | Maven task discovery |
| `meson` | Meson setup/build metadata |
| `node` | Node package scripts |
| `python` | Python project metadata |
| `python_conda` | Conda Python environment metadata |
| `python_conda_yaml` | YAML Conda environment metadata |
| `python_requirements` | Requirements-based Python metadata |
| `yarn` | Yarn package scripts |

The fixture manifest is intentionally separate from parser implementation. A
fixture may be used by more than one detection or build-resolution test.

## Baseline Ownership

- Zig currently owns CLI parsing, process supervision, protocol framing,
  configuration, runtime resolution, quickfix processing, detection, project
  parsing, and build actions.
- Lua currently owns Neovim UI and the test harness, and communicates with the
  backend through the marker protocol.
- Rust must replace the first group without changing the second group's public
  Neovim behavior.
