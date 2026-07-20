# Ace — Arch Linux Compatible Package Manager

A drop-in replacement for pacman written in [V](https://vlang.io/). Supports all
standard subcommands (`-Q`, `-R`, `-S`, `-U`, `-D`, `-T`, `-F`) with matching
flags and behaviour, plus post-transaction hooks, GPG keyring management, 
a coloured crimson UI, dependency tree, transaction history, and one-shot 
migration from pacman.


## Features

| Area | What |
|---|---|
| **Drop-in compatible** | Same CLI flags, same DB format, same pacman.conf |
| **Full install/remove** | Archive extraction, file tracking, dependency resolution |
| **Post-transaction hooks** | Runs ALPM hooks after install/remove (initramfs, font cache, etc.) |
| **GPG keyring management** | `--keyring-init` / `--keyring-populate` — native keyring setup |
| **Crimson UI** | Coloured output — headings, packages, versions, errors |
| **Progress bar** | `[##########] 47% (158/335)` during extraction |
| **Dependency tree** | `--deptree zsh` shows recursive tree with version constraints |
| **Transaction history** | `--history` reads the log with coloured markers |
| **All optional deps** | `--all-optional` installs every optional dependency |
| **One-shot migration** | `--transfer` copies pacman data into ace's native directories |
| **Dual-DB mode** | `--pacman` shares pacman's local database; native mode uses `/var/lib/ace/` |

## Quick Start

```sh
# Build
make build                         # requires V 0.5.2+, libzstd, gpgme

# Migrate from pacman (optional — one-time)
doas ./ace --transfer              # copies local DB, sync DBs, cache, config

# Use natively after transfer
doas ./ace -Syu                    # full system upgrade
doas ./ace -S neovim               # install a package
doas ./ace -R neovim               # remove a package

# Or share pacman's database
doas ./ace --pacman -S fish        # uses /var/lib/pacman/local/ directly
doas ./ace --pacman -R fish
```

## Subcommands

| Flag | Operation | Key Flags |
|---|---|---|
| `-Q` | Query local DB | `-Qi` info, `-Ql` file list, `-Qs` search, `-Qo` file owner, `-Qk` check |
| `-S` | Sync / install | `-Sy` refresh, `-Ss` search, `-Su` upgrade, `-Sc` clean cache |
| `-R` | Remove | `-Rs` recursive, `-Rc` cascade, `-Rn` nosave, `--print` dry-run |
| `-U` | Upgrade from file | `--asdeps`, `--asexplicit`, `--needed`, `-w` download-only |
| `-D` | Database ops | `-Dk` check, `--asdeps`, `--asexplicit` |
| `-T` | Dependency test | `-T glibc "python>=3.10"` |
| `-F` | File search | `-Fl` list, `-Fy` refresh, `-Fx` regex |

## Ace-Specific Flags

| Flag | Description |
|---|---|
| `--pacman` | Use pacman-compatible paths (`/var/lib/pacman/`, `/etc/pacman.conf`) |
| `--transfer` | Migrate all pacman data to ace native directories (requires root) |
| `--keyring-init` | Initialize a fresh GPG keyring |
| `--keyring-populate <name>` | Import keys from a keyring package |
| `--all-optional` | Install all optional dependencies alongside the target |
| `--deptree <pkg>` | Show recursive dependency tree with version constraints |
| `--history` | Show human-readable transaction history |
| `--noconfirm` | Skip confirmation prompts |
| `--config <path>` | Use alternate config file |
| `--root <path>` | Set alternate installation root |
| `--dbpath <path>` | Set alternate database path |

## Migration from Pacman

```sh
# One command — safe to run multiple times, never touches pacman's data
doas ace --transfer

# What gets copied:
#   /var/lib/pacman/local/      → /var/lib/ace/local/      (installed packages)
#   /var/lib/pacman/sync/       → /var/lib/ace/sync/       (repository DBs)
#   /etc/pacman.conf            → /etc/ace.conf            (configuration)
#   /var/cache/pacman/pkg/      → /var/cache/ace/pkg/      (package cache)
#   /etc/pacman.d/hooks/        → /etc/ace/hooks/          (alpm hooks)
#   /etc/pacman.d/gnupg/        → /etc/ace/gnupg/          (GPG keyring)
#   /var/log/pacman.log         → /var/log/ace.log         (transaction log)

# After transfer, use ace without --pacman:
doas ace -Syu
```

## Examples

```sh
# Search and install
ace -Ss "terminal emulator"       # search repos
doas ace -S alacritty             # install
ace -Qi alacritty                 # show info
ace -Ql alacritty                 # list installed files

# Dependency inspection
ace --deptree zsh                 # recursive tree
ace --deptree firefox             # deep dependency chain
ace -T glibc "python>=3.10"      # check if deps are satisfied

# System maintenance
doas ace -Syu                     # full upgrade
doas ace -Sc                      # clean package cache
ace -Dk                           # check DB consistency
ace --history                     # view transaction log

# Install with optional deps
doas ace -S fish --all-optional   # installs fish + python, pkgfile, groff, etc.

# Dry-run removal
ace -R --print firefox            # see what would be removed
```

## Configuration

Ace reads `/etc/pacman.conf` by default. After `--transfer`, use `--config /etc/ace.conf` or rename it. The format matches pacman's INI-style:

```ini
[options]
RootDir     = /
DBPath      = /var/lib/ace/
CacheDir    = /var/cache/ace/pkg/
LogFile     = /var/log/ace.log

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
```

## Requirements

- V compiler 0.5.2+
- libzstd development headers
- gpgme development headers
- Arch Linux (or derivative)

## Build

```sh
make build      # compile ace binary
make test       # run all tests (39 test suites)
make fmt        # format source
make clean      # remove binary
```

## License

MIT
