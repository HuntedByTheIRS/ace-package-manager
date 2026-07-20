// run_compat.v — orchestrator for the ace ↔ pacman compatibility suite.
//
// Runs all compat checks in sequence and reports pass/fail for each.
//
// Usage:
//   v run tests/compat/run_compat.v
//
// Environment:
//   ACE_BIN  — path to the ace binary (default: ./ace)

import os

const ace_bin_default = './ace'

fn main() {
	ace_bin := os.getenv('ACE_BIN')
	mut bin := if ace_bin != '' { ace_bin } else { ace_bin_default }

	if !os.exists(bin) {
		eprintln('ace binary not found at "${bin}"')
		eprintln('Build it first: make build')
		exit(1)
	}

	// Check if pacman is available
	pacman_check := os.execute('which pacman')
	if pacman_check.exit_code != 0 {
		eprintln('pacman not found — compat tests require pacman installed')
		eprintln('Skipping compat suite.')
		exit(0)
	}

	println('=== ace ↔ pacman compatibility suite ===')
	println('ace binary: ${bin}')
	println('')

	checks := [
		['tests/compat/check_query.v', 'query compat'],
		['tests/compat/check_sync.v', 'sync compat'],
		['tests/compat/check_deptest.v', 'deptest compat'],
	]

	mut passed := 0
	mut failed := 0

	for check in checks {
		script := check[0]
		name := check[1]
		print('  [${name}] ... ')

		res := os.execute('ACE_BIN="${bin}" v run "${script}" 2>&1')
		if res.exit_code == 0 {
			println('PASS')
			passed++
		} else {
			println('FAIL')
			println('    output: ${res.output.replace('\n', '\n    ')}')
			failed++
		}
	}

	println('')
	println('Results: ${passed} passed, ${failed} failed')
	if failed > 0 {
		exit(1)
	}
}
