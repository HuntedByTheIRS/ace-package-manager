# Ace — Advanced Usage Guide

## Table of Contents

- [Migration from Pacman](#migration-from-pacman)
- [Dual-Database Mode](#dual-database-mode)
- [Dependency Tree](#dependency-tree)
- [Transaction History](#transaction-history)
- [Optional Dependencies](#optional-dependencies)
- [Library Dependency Checking](#library-dependency-checking)
- [Extreme Library Checking](#extreme-library-checking)
- [Post-Transaction Hooks](#post-transaction-hooks)
- [GPG Keyring Management](#gpg-keyring-management)
- [Progress Bar](#progress-bar)
- [Colour Theme](#colour-theme)
- [Root and Path Overrides](#root-and-path-overrides)
- [Offline / Cache-Only Operations](#offline--cache-only-operations)
- [Database Integrity](#database-integrity)
- [Dry-Run and Print Mode](#dry-run-and-print-mode)
- [Pacman Compatibility Notes](#pacman-compatibility-notes)
- [Troubleshooting](#troubleshooting)
- [Internal Architecture Notes](#internal-architecture-notes)

---

## Migration from Pacman

```sh
doas ace --transfer
```

Copies **all** pacman data into ace's native directories. Idempotent — safe to
run multiple times. Pacman's original data is never modified or removed.

| Source | Destination |
|---|---|
| `/var/lib/pacman/local/` | `/var/lib/ace/local/` |
| `/var/lib/pacman/sync/` | `/var/lib/ace/sync/` |
| `/etc/pacman.conf` | `/etc/ace.conf` |
| `/var/cache/pacman/pkg/` | `/var/cache/ace/pkg/` |
| `/etc/pacman.d/hooks/` | `/etc/ace/hooks/` |
| `/etc/pacman.d/gnupg/` | `/etc/ace/gnupg/` |
| `/var/log/pacman.log` | `/var/log/ace.log` |

After migration, use ace without `--pacman`:

```sh
doas ace -Syu
doas ace -S firefox
ace -Q | wc -l          # should match pacman -Q | wc -l
```

---

## Dual-Database Mode

Ace can operate in two database modes:

### Native mode (default)
Uses `/var/lib/ace/` — completely separate from pacman. Requires `--transfer`
first to populate the database.

### Pacman-compatible mode (`--pacman`)
Reads and writes `/var/lib/pacman/local/` directly. This means ace and pacman
share the same view of installed packages.

```sh
# Install with ace, query with pacman — same DB
doas ace --pacman -S fish
pacman -Q fish              # fish 4.8.1-1 ✓
```

**Warning**: In `--pacman` mode, ace writes sync databases to its own directory
(`/var/lib/ace/sync/`) to avoid corrupting pacman's signature-verified sync DBs.
Use `ace -Sy` (not `pacman -Sy`) to refresh ace's sync databases in this mode.

---

## Dependency Tree

```sh
ace --deptree <package>
```

Shows a recursive dependency tree with version constraints. Works on any
installed package with dependency metadata.

```
ace --deptree zsh

zsh 5.9.2-1.1
├── pcre2
    ├── bzip2
    │   ├── glibc
    │   │   ├── linux-api-headers >=4.10
    │   │   ├── tzdata
    │   │   └── filesystem
    │   │       └── iana-etc
    │   └── sh (not installed)
    ├── glibc
    │   └── ... (already shown, collapsed in display)
    ├── readline
    │   └── glibc (circular)
    └── ...
```

Features:
- **Version constraints**: Shows `>=`, `<=`, `=` modifiers when present
- **Circular detection**: Marks `(circular)` for already-visited packages
- **Not-installed markers**: Shows `(not installed)` for missing dependencies
- **Depth limit**: Caps at 10 levels deep to avoid infinite recursion
- **Colour coded**: Package names in crimson, versions in dark red, missing deps in gray

**Limitation**: Ace's sync databases may lack dependency metadata (notably
CachyOS repos). If `-Qi` shows "Depends On: None" for a package, the deptree
will also be empty. This is a repo metadata issue, not an ace bug.

---

## Transaction History

```sh
ace --history
```

Reads the log file (default: `/var/log/ace.log`, or pacman's log in `--pacman`
mode) and formats transactions with colours:

```
2026-07-19 11:21  [INSTALL] installed starship (1.26.0-1)
2026-07-19 15:38  [REMOVE]  removed starship (1.26.0-1)
2026-07-19 12:10  [UPGRADE] upgraded zsh (5.9.1-1.1 -> 5.9.2-1.1)
```

Colour legend:
- **Green `[INSTALL]`** — package installation
- **Yellow `[REMOVE]`** — package removal
- **Crimson `[UPGRADE]`** — package upgrade

Use `--logfile <path>` to read a different log.

---

## Optional Dependencies

```sh
doas ace -S fish --all-optional
```

When `--all-optional` is specified, ace resolves and installs **all** optional
dependencies alongside the target package. For example, `fish`'s optional deps:

| Optional Dep | Purpose |
|---|---|
| `python` | Man page completion parser / web config tool |
| `pkgfile` | Command-not-found hook |
| `groff` | `--help` for built-in commands |
| `xsel` / `xclip` | X11 clipboard integration |
| `wl-clipboard` | Wayland clipboard integration |

Without `--all-optional`, only hard dependencies (`glibc`, `libgcc`, `pcre2`)
are installed.

---

## Library Dependency Checking

```sh
doas ace -S firefox --libs
```

The `--libs` flag enables automatic library-level dependency resolution. It:

1. **Builds a provides index**: Scans all sync database packages' `%PROVIDES%`
   metadata for shared library entries (e.g., `libc.so=6-64`, `libssl.so=3`).
2. **Resolves co-providers**: For each target package's dependency chain,
   discovers other packages that provide the same libraries — these may be
   implicit dependencies not captured by explicit `depends` declarations.
3. **Adds missing providers**: Any library-providing package not already in the
   install set is added automatically.

### Caching

`--libs` prioritises **speed** over exhaustive accuracy. Results are cached at
`{dbpath}/cache/libcheck_cache` so subsequent runs can skip expensive
resolution for already-analysed packages. The cache is automatically
invalidated when sync databases are refreshed (`-Sy`), ensuring stale
entries are never used.

**Cache file format** (text, one entry per line):
```
# ace libcheck cache v1 — auto-generated
firefox=ffmpeg,libvpx,libwebp
zsh=
```

When combined with `--all-optional`, both optional deps AND library providers are
resolved.

**Example**: Installing `firefox` with `--libs` may discover that `libffi`
provides a library Firefox links against. On the first run, the full metadata
scan resolves all providers. On subsequent runs, cached results are used
instantly.

---

## Extreme Library Checking

```sh
doas ace -S firefox --extreme-libs
```

The `--extreme-libs` flag prioritises **accuracy** over speed. It always runs
fresh — bypassing the `--libs` cache entirely:

1. **Runs `ldconfig -p`**: Queries the system's dynamic linker cache for all
   installed shared libraries (~4000 entries on a typical Arch system).
2. **Cross-references with sync DBs**: Matches each system library soname against
   the sync database provides index.
3. **Discovers missing providers**: If a target package's dependency chain
   requires a library that exists on the system but whose provider package
   isn't in the install set, that provider is added.

Unlike `--libs`, `--extreme-libs` **never uses cached results** — every
invocation spawns a fresh `ldconfig -p` subprocess and performs a full
cross-reference against the sync database provides index. This guarantees
the most accurate picture of the current system state.

**Speed vs accuracy trade-off**:

| Flag | Strategy | Speed | Accuracy | Cached? |
|---|---|---|---|---|
| `--libs` | Reverse-index + reverse-depends | Fast | Good | Yes — `{dbpath}/cache/libcheck_cache` |
| `--extreme-libs` | `ldconfig -p` + full cross-reference | Slow (~1-5s) | Best | No — always fresh |

**Caveats**:
- Reflects only the *current* system state — not suitable for chroot or
  `--root` operations on different systems.
- Requires `ldconfig` (part of `glibc`, always available on Arch).
- Uses a 30-second timeout on `ldconfig` to guard against stuck NFS mounts.

`--libs` and `--extreme-libs` can be used together for maximum coverage:
`doas ace -Syu --libs --extreme-libs`. The `--libs` resolution runs first
(cached), then `--extreme-libs` supplements with fresh ldconfig results.

---

## Post-Transaction Hooks

Ace runs ALPM-compatible hooks at multiple phases: pre-transaction (before any
packages are installed), per-package post-install (after each individual package
extraction), and post-transaction (after all packages in the transaction).
Hooks handle system integration tasks like initramfs regeneration, font cache
updates, and service restarts.

### Hook File Format

Hook files use the standard pacman `.hook` INI format:

```ini
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Target = linux

[Action]
When = PostTransaction
Exec = /usr/bin/mkinitcpio -P
```

### Hook Directories

Hooks are loaded from the configured `HookDir` (default: `/etc/ace/hooks/`).
Multiple directories can be specified in `ace.conf`:

```ini
HookDir = /etc/ace/hooks/
HookDir = /usr/share/libalpm/hooks/
```

### Trigger Types

| Field | Values |
|---|---|
| `Type` | `Package` |
| `Operation` | `Install`, `Upgrade`, `Remove` |
| `Target` | Package name or fnmatch glob (`*` for all) |

### Action Phases

| Phase | Behaviour |
|---|---|
| `PreTransaction` | Runs before packages are installed/removed. `AbortOnFail=true` cancels the transaction. |
| `PostTransaction` | Runs after all packages are processed. Failures are non-fatal. |

### Example: System Update Hook

```ini
# /etc/ace/hooks/90-update-cache.hook
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Operation = Remove
Target = *

[Action]
When = PostTransaction
Exec = /bin/sh -c "fc-cache -s; update-desktop-database -q"
```

---

## GPG Keyring Management

Ace manages its own GPG keyring independently of pacman. Initialize and
populate the keyring with trusted signing keys.

```sh
# Initialize a fresh keyring
# ace --keyring-init

# Import trusted keys from a keyring package
# ace --keyring-populate archlinux

# For custom distros (e.g. Arcturus Linux)
# ace --keyring-populate arcturus
```

The keyring is stored at the configured `GPGDir` (default: `/etc/ace/gnupg/`).

Keyring packages are searched in `/usr/share/pacman/keyrings/<name>.gpg` and
`/usr/share/pacman/keyrings/<name>/`.

---

## Progress Bar

During package extraction, ace shows a real-time progress bar:

```
:: Installing packages...
  [############                    ]  30% (101/335)
```

- **40-character bar** with `#` for completed, space for remaining
- **Percentage + file count** (`30% (101/335)`)
- **Two-pass architecture**: First pass counts total entries (non-metadata),
  second pass extracts with progress display
- Appears during both `-S` (sync install) and `-U` (upgrade from file)

---

## Colour Theme

Ace uses a **deep crimson** colour scheme (ANSI 256-color `#d70000` / 160)
with complementary accents:

| Element | Colour | Code |
|---|---|---|
| Section headings (`:: Installing`) | Bold crimson | `\033[1m\033[38;5;160m` |
| Package names | Bold crimson | `\033[1m\033[38;5;160m` |
| New packages | Light pink | `\033[38;5;211m` |
| Installed/up-to-date | Dark green | `\033[38;5;28m` |
| Version strings | Crimson | `\033[38;5;160m` |
| Progress/download | Orange | `\033[38;5;208m` |
| Errors | Bold bright red | `\033[1m\033[38;5;196m` |
| Warnings | Bold yellow | `\033[1m\033[38;5;220m` |
| Success markers | Green | `\033[38;5;76m` |
| Secondary text | Gray | `\033[38;5;245m` |

Colours are applied to all subcommands: sync output, query results,
dependency tree, transaction history, and error messages.

---

## Root and Path Overrides

Ace supports the same path overrides as pacman:

```sh
# Install into a chroot
doas ace --root /mnt/newroot -S base

# Use a custom database
ace --dbpath /custom/path -Q

# Alternate config
ace --config /etc/custom-pacman.conf -Syu
```

**Important**: When both `--root` and `--dbpath` are set, `dbpath` is joined
with `root`. When `--pacman` sets `dbpath = /var/lib/pacman/`, the root prefix
is still applied if `--root` is also given.

---

## Offline / Cache-Only Operations

```sh
# Install from a local package file (no network needed)
doas ace -U /var/cache/pacman/pkg/fish-4.8.1-1-x86_64.pkg.tar.zst

# Query local database
ace -Q | wc -l
ace -Qi glibc
ace -Ql firefox

# Check database consistency
ace -Dk

# Dependency test
ace -T glibc "python>=3.10"

# Search installed packages
ace -Qs "python"
```

---

## Database Integrity

```sh
# Basic check — verifies all packages have desc and files
ace -Dk

# See what -Dk checks:
# 1. Missing desc/files files in package directories
# 2. Missing dependencies (required by installed packages)
# 3. Package conflicts (two packages conflicting)
# 4. File ownership conflicts (same file owned by two packages)

# Per-package file check
ace -Qk firefox    # check all files exist on disk
ace -Qkk firefox   # verbose check
```

---

## Dry-Run and Print Mode

```sh
# See what would be removed without actually removing
ace -R --print firefox

# See what would be installed without downloading
ace -S --print neovim

# Download only, don't install
ace -Sw firefox
```

`--print` mode automatically skips database lock acquisition and confirmation
prompts, matching pacman's behavior.  It also implicitly sets `--noconfirm` and
skips conflict resolution for speed.

---

## Pacman Compatibility Notes

Ace aims for full pacman compatibility.  Key behavioural notes:

### Double-Flag Semantics

| Flag | Effect |
|---|---|
| `-Rs` | Remove with unneeded dependencies (RECURSE) |
| `-Rss` | Remove with ALL dependencies including explicitly installed (RECURSEALL) |
| `-Rd` | Skip dependency version checks (NODEPVERSION) |
| `-Rdd` | Skip ALL dependency checks (NODEPS) |
| `-Su` / `--sysupgrade` | Upgrade all packages |
| `-Suu` / `--sysupgrade --sysupgrade` | Upgrade allowing downgrades |

### `--dbonly` Implications

When `--dbonly` is used (both `-R` and `-S`), ace automatically enables
`--noscriptlet` — install scripts and hooks are not executed.  This matches
pacman's behaviour where `--dbonly` implies `NOSCRIPTLET | NOHOOKS`.

### HoldPkg Enforcement

Packages listed in the `HoldPkg` configuration option cannot be removed.
Attempting to remove a held package produces an error.  This protects
critical system packages (e.g., `pacman`, `glibc`, `systemd`) from
accidental removal.

### Separated CLI Overrides

Config-only options now have CLI overrides with proper priority (CLI >
config > defaults):

| Config Option | CLI Flag |
|---|---|
| `Color` | `--color <auto\|never\|always>` |
| `NoProgressBar` | `--noprogressbar` |
| `IgnoreGroup` | `--ignoregroup <group>` |
| `DisableDownloadTimeout` | `--disable-download-timeout` |
| `DisableSandbox` | `--disable-sandbox` |

### Stdin Target Reading

Ace supports reading package targets from stdin using the `-` token:
```sh
# Install all packages listed in a file
cat pkglist.txt | ace -S -

# Pipe from pacman
pacman -Qq | ace -S -
```

---

## Troubleshooting

### "error: package directory not found" on remove
This means the `--root` prefix wasn't applied to the database path. Ace now
joins root + dbpath correctly in all operations. If you see this, ensure your
`--root` and `--dbpath` flags are consistent.

### "Depends On: None" in -Qi output
Ace's sync DB format (downloaded via `-Sy`) may not include dependency metadata
for all repositories. CachyOS repos, in particular, lack `%DEPENDS%` in their
desc files. This is a repo-side metadata issue. Packages install and function
correctly regardless.

### Sync DB signature errors when using pacman after ace
In `--pacman` mode, ace writes sync databases to `/var/lib/ace/sync/`, not
pacman's directory. However, if you ran an older version of ace that wrote to
`/var/lib/pacman/sync/`, run `pacman -Sy` to restore pacman's sync databases.

### "cannot use map as type" or build errors with new .v files
Ace uses `v main.v -enable-globals` for building. All .v files in the `cli/`
module must have unique function names. If adding new files, avoid redefining
functions that exist in other cli/ files (e.g., `ver_str`, `dim_str`).

---

## Internal Architecture Notes

### Install Flow (end-to-end)

```
User runs: ace -S fish

1. cli/args.v       parse_args() → CliArgs{operation: .sync, targets: ["fish"]}
2. cli/init.v       init_from_args() → Config + Handle
3. main.v           dispatch → cli.run_sync()
4. cli/sync.v       run_sync() → sync_install_or_upgrade()
   a. Load sync DBs      → []&Database (from /var/lib/ace/sync/*.db)
   b. Resolve targets    → find "fish" in pkgcache, add to pkg_targets
   c. Init transaction   → trans.new_transaction(), add_pkg_to_trans()
   d. Prepare            → trans.prepare() — resolve deps, check conflicts
   e. Download           → download module (parallel, sandboxed)
   f. Install            → loop: trans.install_package() for each pkg
5. trans/install.v  install_package()
   a. Clear file list    → pkg.files = FileList{}
   b. Extract archive    → extract_package_files()
      - First pass:      count non-metadata entries
      - Second pass:     extract each file/dir/symlink
      - Progress bar:    [####  ] 30% per entry
      - Populate:        pkg.files.files << {name, size, mode}
   c. Write DB           → db.write_pkg() → {dbpath}/local/fish-4.8.1-1/{desc,files}
6. Return               → "done"
```

### Remove Flow (end-to-end)

```
User runs: ace -R fish

1. cli/remove.v     run_remove()
   a. Open local DB     → db.init() + populate()
   b. Map flags         → RemoveFlags (cascade, recurse, nosave, etc.)
   c. Confirm           → confirm_remove()
   d. Remove            → trans.remove_package()
2. trans/remove.v   remove_package()
   a. Validate           → origin must be .local_db
   b. Recurse/Cascade    → expand removal list
   c. Check deps         → stop if other packages depend on target
   d. Sort               → dependents before dependencies
   e. Remove each        → remove_single_package()
      - Pre scriptlet    → run_remove_scriptlet("pre_remove")
      - Remove files     → remove_package_files() — iterate filelist backwards
      - Post scriptlet   → run_remove_scriptlet("post_remove")
      - DB remove        → db.remove_pkg() — delete {name}-{version}/ directory
      - Cache remove     → localdb.pkgcache.delete(name)
```

### Database Format

Ace uses pacman's ALPM database format. Both local and sync databases use
identical structures.

**Local DB** (`/var/lib/ace/local/`):
```
local/
  ALPM_DB_VERSION           → "9"
  pkgname-version/
    desc                    → %NAME%, %VERSION%, %DEPENDS%, etc.
    files                   → %FILES% + %BACKUP% sections
    install                 → (optional) .INSTALL scriptlet
```

**Sync DB** (compressed `.db` in `/var/lib/ace/sync/`):
```
core.db (tar.zst)
  glibc-2.43-2/
    desc                    → %FILENAME%, %NAME%, %VERSION%, %DEPENDS%, etc.
    depends                 → (optional) dependency specifiers
    files                   → (optional, in .files databases only)
```

Ace downloads `.db` files (without file lists). File lists are populated
during extraction from the package archive itself. This means `-R`, `-Ql`,
and `-Qk` always have accurate file data regardless of the sync DB format.
