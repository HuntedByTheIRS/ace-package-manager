# ace Benchmarks

This directory contains benchmarking scripts for the ace package manager.
Benchmarks measure performance of core operations on realistic data.

## Prerequisites

- `ace` binary built (`make build` at project root)
- V compiler installed (v0.5.2+)

## Usage

Run all benchmarks:

```bash
make bench
```

Or run individual benchmarks:

```bash
v -enable-globals run tests/bench/bench_vercmp.v
v -enable-globals run tests/bench/bench_db_load.v
```

The orchestrator (`run_benchmarks.v`) runs each benchmark script in sequence and
collects:

- **Elapsed wall time** (ms) per benchmark script
- **Peak memory delta** (kB, via `/proc/self/status VmRSS`)

Results are printed to stdout with per-operation timings and a final summary table.

## Benchmarks

### bench_vercmp.v

Measures version comparison throughput for the `util.vercmp` function
(100 000 iterations per test case):

- **vercmp/baseline**: identical strings
- **vercmp/epoch**: epoch-prefixed versions
- **vercmp/real-world**: typical version strings from Arch packages
- **vercmp/tilde**: tilde pre-release markers
- **vercmp/complex**: versions with git hashes, epochs, underscores
- **vercmp/large-epoch**: edge-case epoch values

### bench_db_load.v

Measures database loading performance:

- **db/init (500x)**: Initialize local DB 500 times
- **db/populate (50 pkgs)**: Create and populate a local DB with 50 packages
- **db/write (50 pkgs)**: Write 50 package entries to disk
- **db/sync_parse (N)**: Parse N entries from a sync DB archive

### bench_dep_resolve.v (blocked)

The dependency-resolution benchmark exists at `tests/bench/bench_dep_resolve.v`
but requires fixes in the `trans` module before it can run. See the file for
reference — it benchmarks `trans.resolve_deps` and `trans.sort_by_deps` on
various dependency tree shapes once the module compiles cleanly.
