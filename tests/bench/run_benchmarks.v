// run_benchmarks.v — orchestrator that runs all benchmarks and reports results.
//
// Usage:
//   make bench
//   v -enable-globals run tests/bench/run_benchmarks.v

import os
import time
import strconv

struct BenchResult {
	name       string
	elapsed_ms i64
	mem_kb     i64 // VmRSS delta (kB)
}

struct BenchScript {
	name   string
	script string
}

fn memory_usage_kb() i64 {
	data := os.read_file('/proc/self/status') or { return 0 }
	for line in data.split('\n') {
		if line.starts_with('VmRSS:') {
			// line looks like "VmRSS:    12345 kB"
			parts := line.trim_space().split(' ')
			if parts.len >= 2 {
				return strconv.common_parse_int(parts[parts.len - 2], 10, 64, false, false) or { 0 }
			}
		}
	}
	return 0
}

fn run_one_bench(name string, script string) BenchResult {
	before_mem := memory_usage_kb()
	start := time.now()
	res := os.execute('v -enable-globals run "${script}" 2>&1')
	elapsed_ms := time.since(start).milliseconds()
	after_mem := memory_usage_kb()
	mut mem_delta := after_mem - before_mem
	if mem_delta < 0 {
		mem_delta = 0
	}

	if res.exit_code != 0 {
		eprintln('FAILED: ${script}\n${res.output}')
		exit(1)
	}
	print(res.output)
	return BenchResult{name, elapsed_ms, mem_delta}
}

fn main() {
	println('=== ace benchmark suite ===')
	println('')

	scripts := [
		BenchScript{'vercmp',        'tests/bench/bench_vercmp.v'},
		BenchScript{'db_load',       'tests/bench/bench_db_load.v'},
	]

	mut results := []BenchResult{}

	for s in scripts {
		result := run_one_bench(s.name, s.script)
		results << result
		println('')
	}

	// Summary table
	println('=== Summary ===')
	println('')
	println('  Benchmark            Time (ms)    Mem delta (kB)')
	println('  -------------------  ---------    ---------------')
	for r in results {
		println('  ${r.name:-20s} ${r.elapsed_ms:8}    ${r.mem_kb:8}')
	}
	println('')
	println('All benchmarks completed.')
}
