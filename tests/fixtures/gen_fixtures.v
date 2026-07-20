// gen_fixtures.v — orchestrator that generates all test fixture artifacts.
//
// Usage:
//   v run tests/fixtures/gen_fixtures.v
//
// Output:
//   tests/fixtures/output/  — all generated artifacts

import os

fn main() {
	out := 'tests/fixtures/output'
	os.mkdir_all(out, os.MkdirParams{}) or { panic('mkdir: ${err}') }

	println('=== ace test fixture generator ===')
	println('')

	scripts := [
		'tests/fixtures/gen_core_db/',
		'tests/fixtures/gen_pkg_tar_zst/',
		'tests/fixtures/gen_local_db/',
	]

	for i, script in scripts {
		println('[${i + 1}/${scripts.len}] Running generator: ${script}...')
		res := os.execute('v -enable-globals run ${script}')
		if res.exit_code != 0 {
			eprintln('FAILED: ${script}\n${res.output}')
			exit(1)
		}
		print(res.output)
	}

	println('')
	println('All fixtures generated in ${out}/')
	entries := os.ls(out) or { panic('ls: ${err}') }
	for e in entries {
		full := os.join_path(out, e)
		info := if os.is_dir(full) { '(dir)' } else { '${os.file_size(full)} bytes' }
		println('  ${e} ${info}')
	}
}
