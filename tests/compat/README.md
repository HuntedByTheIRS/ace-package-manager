# ace ↔ pacman Compatibility Suite

This directory contains scripts that compare ace output against pacman output
for the same operations, reporting any differences.

## Prerequisites

- `ace` binary built (`make build` at project root)
- `pacman` installed (real Arch Linux pacman)
- A populated `/var/lib/pacman/` database (standard Arch installation)

## Usage

Run the full suite:

```bash
make compat
```

Or run individual checks:

```bash
v run tests/compat/check_query.v
v run tests/compat/check_sync.v
v run tests/compat/check_deptest.v
```

## Scripts

| Script | Operation | What it checks |
|--------|-----------|----------------|
| `check_query.v` | `-Q` (query) | List, info, search, file-owner output matching |
| `check_sync.v` | `-S` (sync) | Search, info, list output matching |
| `check_deptest.v` | `-T` (deptest) | Dependency resolution output matching |

## How It Works

Each script:
1. Runs `ace <args>` and captures stdout
2. Runs `pacman <args>` and captures stdout  
3. Diffs the two outputs
4. Reports PASS if identical, FAIL with diff if different

To use a custom ace binary path, set the `ACE_BIN` environment variable:

```bash
ACE_BIN=./ace v run tests/compat/check_query.v
```
