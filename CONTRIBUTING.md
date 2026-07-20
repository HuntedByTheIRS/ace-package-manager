# Contributing to Ace

Ace is an Arch Linux Compatible Package Manager written in Vlang. It aims to be
a drop-in replacement for pacman. Contributions are welcome.

## Quick Start

```sh
# Clone the repo and build
git clone https://github.com/yourorg/ace
cd ace
make build

# Run the binary
./ace --help

# Run all tests
make test
```

## Prerequisites

- The **V compiler** (v0.5.2+). Install from https://vlang.io/ or your distro.
- **libzstd** — development headers (`zstd.h`, `-lzstd`). On Arch: `zstd`.
- **gpgme** — development headers (`gpgme.h`, `-lgpgme`). On Arch: `gpgme`.
- **zstd** CLI tool (for phase 0 validation tests).

## Development Workflow

### 1. Pick an Issue

Check open issues or look at the phase roadmap. If you want to work on
something not yet tracked, open an issue first.

### 2. Understand the Architecture

Read `ARCHITECTURE.md` for the module map and data flow. Each module mirrors a
specific pacman source file — the reference is noted in the module's doc
comment (e.g. `// Reference: pacman/src/pacman/query.c`).

### 3. Code Style

- **V fmt**: Run `make fmt` before committing. The project uses V's built-in
  formatter (`v fmt -w .`).
- **Naming**: Follow V conventions — `snake_case` for functions and variables,
  `PascalCase` for types and enums.
- **Comments**: Module-level doc comments explain the module's purpose. Public
  functions have doc comments describing parameters, return values, and
  behaviour. Reference the upstream pacman source where applicable.
- **Line length**: Aim for 100 characters max. Prefer readability over brevity.

### 4. C Interop Rules

- All `#flag`, `#include`, and `C.*` calls go in `lib/`. No exceptions.
- Wrappers must present a safe V API — no raw pointers, no unsafe blocks
  leaking to callers.
- One wrapper file per C library (e.g. `lib/zstd.v`, `lib/gpgme.v`).

### 5. Error Handling

- Every fallible public function returns `!` (the V error union).
- Errors use `util.AceError` with a typed `ErrorCode` (mirroring
  `alpm_errno_t`).
- Wrap errors from lower layers with context:
  ```v
  download_pkg(name) or {
      return AceError{code: .retrieve, message: "while installing ${name}: ${err.msg()}"}
  }
  ```

### 6. Testing

Run the full test suite before submitting:

```sh
# All tests
make test

# Test a specific module
v -enable-globals test config/
v -enable-globals test cli/
v -enable-globals test db/
v -enable-globals test util/
```

Tests live alongside the source they test (e.g. `cli/query_test.v`,
`db/local_test.v`, `util/vercmp_test.v`). We follow V's convention of
`*_test.v` files with `fn test_*` functions.

### 7. Commit Messages

Write clear, scoped commit messages:

```
module: short description

Longer explanation of what changed and why. Reference issues
and pacman source lines where relevant.
```

Examples:
- `db/local: fix null pointer in read_desc_into when desc is empty`
- `cli/query: add -Qkk support for full file check`
- `trans: add dependency resolution in prepare()`

### 8. Submit a Pull Request

1. Create a feature branch from `master`.
2. Make your changes.
3. Run `make fmt` and `make test`.
4. Push and open a PR against `master`.

### 9. Phase 0 Validation

Before your first build, run the C interop validation:

```sh
./ace
```

This exercises the zstd decompression and gpgme signature verification
wrappers. Both must pass before merging changes to `lib/`.

## Project Layout

```
ace/
├── main.v          — entry point
├── cli/            — subcommand handlers + extras
│   ├── args.v      — CLI argument parsing (all flags)
│   ├── init.v      — config loading, handle initialization
│   ├── query.v     — -Q operations
│   ├── sync.v      — -S operations (install, search, refresh)
│   ├── remove.v    — -R operations
│   ├── upgrade.v   — -U operations
│   ├── database.v  — -D operations
│   ├── deptest.v   — -T operations
│   ├── files.v     — -F operations
│   ├── display.v   — callback display helpers
│   ├── deptree.v   — --deptree dependency tree
│   ├── history.v   — --history transaction log reader
│   ├── transfer.v  — --transfer pacman→ace migration
│   └── colors.v    — ANSI color constants
├── config/         — pacman.conf parser
├── db/             — database reader/writer
├── download/       — HTTP downloads + sandbox
├── trans/          — transaction state machine
│   ├── transaction.v — state machine, commit, hooks
│   ├── install.v    — archive extraction + progress bar + DB write
│   ├── remove.v     — file removal, scriptlets, DB cleanup
│   ├── resolver.v   — dependency resolution, sorting
│   └── conflict.v   — file/package conflict detection
├── lib/            — C interop wrappers
├── lock/           — database locking
├── archive/        — .pkg.tar.* archive reader
├── util/           — shared types, vercmp, checksums
├── hooks/          — hook runner (ALPM-compatible .hook files)
├── signing/        — package signing (WIP)
├── cache/          — cache management (WIP)
├── commit/         — commit logic (WIP)
└── pacman/         — reference upstream source
```

## Feature Areas for Contribution

### Install / Remove Pipeline (`trans/`)
The critical path. Handles archive extraction with progress bar, file list
tracking, backup file management, scriptlets, and DB writes. The `install.v`
module performs a two-pass extraction: first pass counts entries, second pass
extracts with a `[####  ] 47%` progress indicator. File permissions and
symlinks are preserved from archive metadata.

### Sync Database Management (`cli/sync.v`, `db/sync.v`)
Downloads `.db` files from configured repositories. Note: ace downloads the
regular `.db` format (not `.files`). File lists are populated during extraction
from the package archive itself. The sync DB parser handles `desc`, `depends`,
and `files` entries in compressed archives.

### Dependency Resolution (`trans/resolver.v`)
Resolves dependencies, sorts packages by dependency order, handles provider
selection (`provides`), and integrates with the `--all-optional` flag to
include optional dependencies.

### Colour System (`cli/colors.v`, inline helpers)
Uses ANSI 256-color codes with a crimson theme (`\033[38;5;160m`). Each CLI
file defines its own inline colour helpers (`fn pkg_str()`, `fn dim_str()`,
etc.) to avoid cross-file naming conflicts. The `colors.v` module provides
reference constants and semantic helpers.

### New Feature Flags
- **`--deptree`** (`cli/deptree.v`): Recursive dependency tree with circular
  detection, depth limit (10), not-installed markers.
- **`--history`** (`cli/history.v`): Parses `[TIMESTAMP] [OPERATION] msg`
  format logs with colour-coded `[INSTALL]`/`[REMOVE]`/`[UPGRADE]` markers.
- **`--transfer`** (`cli/transfer.v`): Idempotent pacman→ace migration copying
  local DB, sync DBs, config, cache, hooks, GPG, and log.
- **`--all-optional`**: Wired into `cli/sync.v` install flow, resolves and
  enqueues `optdepends` alongside the target package.

## Getting Help

Open an issue on GitHub. For questions about the architecture, refer to
`ARCHITECTURE.md` and the reference pacman source in `pacman/`.
