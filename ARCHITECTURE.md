# Ace Architecture

Ace is an Arch Linux Compatible (package) Executable. It is a drop-in replacement
for pacman written in Vlang. Ace mirrors pacman's subcommands and behaviour
while keeping the codebase pure V with strict isolation of C interop.

## Module Map

```
main.v            Entry point — CLI dispatch
├── cli/          Subcommand handlers + extras (deptree, history, transfer, colors)
├── config/       Pacman.conf INI parser
├── db/           Package database reader/writer (local + sync)
├── util/         Shared types, error codes, version comparison, checksums
├── trans/        Transaction state machine (init → prepare → commit) + install/remove
├── download/     HTTP download engine with parallel + sandbox support
├── lib/          C interop wrappers (zstd, gpgme, POSIX sandbox)
├── lock/         File-based database lock (O_CREAT|O_EXCL)
├── archive/      Archive reader for .pkg.tar.{zst,xz,gz}
├── hooks/        Post-install hook runner (ALPM-compatible, wired into -S/-U/-R)
├── signing/      Package signing (placeholder)
├── cache/        Cache management (placeholder)
├── commit/       Transaction commit logic (placeholder)
└── pacman/       Reference pacman source (for comparison)
```

## How It Fits Together

At startup, `main.v` calls `cli.parse_args()` to parse os.args into a typed
`CliArgs` struct. Then `cli.init_from_args()` reads `/etc/pacman.conf` (or
`--config`), merges CLI overrides, and returns an `InitResult` holding the
parsed `Config` and a `Handle` (the runtime configuration handle).

The operation is dispatched by a `match` on `args.operation`. Each subcommand
function receives the same `(&CliArgs, &Config, &Handle)` triple and is
responsible for its own flow — opening databases, running transactions, and
printing output.

## Module Responsibilities

### `config/` — Configuration

Parses pacman.conf format: `[section]` headers, `Key = Value` pairs, `Include`
directives (recursive), and `SigLevel` multi-token bitmask parsing. Variable
substitution handles `$repo` and `$arch`. Returns a typed `Config` struct with
defaults matching pacman's compiled-in values.

### `db/` — Package Databases

Two database types:

- **LocalDB** (`/var/lib/pacman/local/`): A directory tree with one
  subdirectory per installed package (`name-version/`), each containing `desc`
  and `files` files in `%KEY%` format. Read via `init()` + `populate()`
  (prefers the newest version when duplicate directories exist).
  Write via `write_pkg()` (using `strings.Builder` for efficient string
  construction, and automatically removing old-version directories) and
  `remove_pkg()`.

- **SyncDB** (compressed `.db` archives): Tarballs fetched from repositories
  in parallel (up to 3 concurrent via semaphore-gated goroutines) and cached
  locally to avoid re-downloading when up-to-date.  Parsed via
  `archive.ArchiveReader`. Each entry in the archive is an
  `{name}-{version}/desc` file in `%KEY%` format plus optional `depends` and
  `files` files.  Multiple DBs are parsed in parallel goroutines via
  `load_sync_dbs()`.

Types (`types.v`) define `Package` (the core data structure carrying all
metadata), `Dependency` (with parsed version constraints), `FileList`,
`Group`, and the enums for `DepMod`, `PackageReason`, `PackageOrigin`,
`PackageValidation`.  `build_grpcache()` uses per-package seen-sets for
O(1) deduplication instead of the old O(n²) linear scan.

### `cli/` — Subcommands

Each subcommand lives in its own file:

| File      | Operation | Reference              |
|-----------|-----------|------------------------|
| `query.v` | -Q        | pacman/src/pacman/query.c |
| `sync.v`  | -S        | pacman/src/pacman/sync.c  |
| `remove.v`| -R        | pacman/src/pacman/remove.c |
| `upgrade.v`| -U       | pacman/src/pacman/upgrade.c (stub) |
| `deptest.v`| -T       | pacman/src/pacman/deptest.c |
| `database.v`| -D      | pacman/src/pacman/database.c |
| `files.v` | -F        | pacman/src/pacman/files.c  |
| `display.v`| Callbacks| pacman/src/pacman/callback.c |
| `args.v`  | Parsing   | pacman/src/pacman/pacman.c |
| `deptree.v`| --deptree  | Recursive dependency tree display |
| `history.v`| --history  | Transaction log reader and formatter |
| `transfer.v`| --transfer | Pacman-to-ACE data migration |
| `colors.v` | --         | ANSI color constants and helpers (crimson theme) |

`args.v` handles combined flags (`-Qii`, `-Rscn`, `-Syu`) by scanning
characters after the operation letter. All recognised pacman flags are
represented in the `CliArgs` struct.

### `trans/` — Transaction Engine

A 5-state state machine:

```
IDLE → INITIALIZED → PREPARED → COMMITTING → COMMITTED
```

Key modules within `trans/`:

- **`transaction.v`**: State machine (`trans_init`, `prepare`, `commit`, `release`), flags, hook runner wiring.
- **`install.v`**: `install_package()` — the core install function. Opens the `.pkg.tar.zst`
  archive via vibarchive and extracts files in a **single pass** (no separate counting
  pass — saves 2× decompression I/O).  Streams file data directly to disk chunk-by-chunk
  using a reusable 8 KiB read buffer, avoiding per-file allocations and in-memory
  buffering of large files.  Preserves permissions and symlinks, populates
  `pkg.files.files` from archive entries, and writes metadata to the local DB.
- **`remove.v`**: `remove_package()` — removes files (filelist from local DB, reverse
  iteration, .pacsave backup support, mountpoint guarding), runs scriptlets,
  removes DB entry. Supports cascade, recurse, unneeded, nosave, dbonly flags.
- **`resolver.v`**: Dependency resolution — `resolve_deps()`, `sort_by_deps()`,
  `satisfied_by_localdb()` (uses pre-built `local_provides` index for O(1) provider
  lookups instead of O(N) linear scan), provider selection.
- **`conflict.v`**: File and package conflict detection during prepare phase.

### `download/` — HTTP Downloads

Two-layer design:

- **`fetcher.v`**: Single-file HTTP downloader with **streaming to temp files**
  via `on_progress_body` (no in-memory buffering even for multi-GiB packages),
  Range-header resume, progress callbacks, and optional `.sig` auto-download.
- **`parallel.v`**: Concurrent download orchestration using V `go` coroutines
  and channels. A buffered semaphore channel limits concurrency (default: 7).
  Uses the streaming `Downloader` from `fetcher.v` to avoid loading entire
  response bodies into memory. Payloads with `errors_ok=true` never fail the batch.
- **`sandbox.v`**: Privilege-dropping before HTTP requests. Resolves
  `DownloadUser` from `/etc/passwd`, then delegates setuid/setgid to
  `lib.drop_root_privileges()`.
- **`mirror.v`**: Mirror selection and failover logic.

### `lib/` — C Interop Isolation

The **only** module that may contain `#flag`, `#include`, or `C.` references.
This is enforced by convention and checked in code review.

| File            | Library     | API                                   |
|-----------------|-------------|---------------------------------------|
| `zstd.v`        | libzstd     | `zstd_decompress(compressed)`         |
| `gpgme.v`       | gpgme       | `gpgme_init()`, `gpgme_verify()`, `gpgme_verify_path()` |
| `sandbox.v`     | POSIX       | `drop_root_privileges()`, `is_running_as_root()` |
| `gpgme_helper.c`| gpgme shim  | Type-safe C wrappers for voidptr casts |

Each wrapper presents a safe V API: callers never touch C pointers or unsafe
code. Memory management (alloc/release of gpgme context, data objects) is
handled inside the wrapper with V's `defer`.

### `lock/` — Database Locking

Exclusive process-safe lock using `O_CREAT | O_EXCL` semantics. The lock file
at `{dbpath}/db.lck` contains the owning PID. Stale locks (dead owner) are
detected via `/proc/{pid}/` and removed automatically.

### `archive/` — Archive Reader

Reads `.pkg.tar.{zst,xz,gz}` archives using the vibarchive module. Used by the
sync database parser (`db/sync.v`) and by `-U` (upgrade) to extract package
metadata from `.pkg.tar.*` files.

### `util/` — Shared Utilities

| File            | Purpose                                  |
|-----------------|------------------------------------------|
| `interfaces.v`  | `Handle` struct, `Event`/`Question` types, callback function types |
| `errors.v`      | `AceError` type with ErrorCode enum (mirrors alpm_errno_t) |
| `vercmp.v`      | `vercmp()` — pacman-compatible rpmvercmp algorithm |
| `checksum.v`    | `md5sum()`, `sha256sum()`, `blake2bsum()`, `verify_checksum()` |
| `splitname.v`   | `split_pkgname()`, `split_pkgfile()` — package specifier parsing |

## C Interop Isolation Policy

All C FFI lives in `lib/`. No other module may contain `#flag`, `#include`,
or call `C.*` functions. The `lib/README.md` documents the four rules:

1. No unsafe code outside `lib/`
2. No `#flag` / `#include` outside `lib/`
3. Wrappers expose a safe V API
4. One wrapper file per C library

## Build System

The project uses a plain Makefile. The V compiler compiles `main.v` with
`-enable-globals` (needed for signal handling and download display state).

```
make build     — compile the `ace` binary
make test      — run all tests
make clean     — remove the binary
make fmt       — format all V source
make vet       — run V's static analyser
```

See `CONTRIBUTING.md` for the development workflow.
