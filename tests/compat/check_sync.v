// check_sync.v — compat check: ace -S vs pacman -S output diff.
//
// Compares ace and pacman output for the -S (sync) subcommand.
// Requires a populated sync database (run -Sy first on both).
//
// Usage:
//   v run tests/compat/check_sync.v
//
// Environment:
//   ACE_BIN  — path to ace binary (default: ./ace)

import os

const ace_bin_default = './ace'

fn run_ace(args string) ?string {
	ace_bin := os.getenv('ACE_BIN')
	mut bin := if ace_bin != '' { ace_bin } else { ace_bin_default }
	if !os.exists(bin) {
		return error('ace binary not found: ${bin}')
	}
	res := os.execute('"${bin}" ${args} 2>/dev/null')
	return res.output
}

fn run_pacman(args string) ?string {
	res := os.execute('pacman ${args} 2>/dev/null')
	if res.exit_code != 0 {
		return error('pacman exited with ${res.exit_code}')
	}
	return res.output
}

fn compare(cmd string, desc string) {
	ace_out := run_ace(cmd) or {
		println('  SKIP (ace error): ${desc}: ${err}')
		return
	}
	pac_out := run_pacman(cmd) or {
		println('  SKIP (pacman error): ${desc}: ${err}')
		return
	}

	ace_lines := ace_out.split('\n')
	pac_lines := pac_out.split('\n')
	mut ace_trimmed := []string{}
	mut pac_trimmed := []string{}
	for l in ace_lines {
		t := l.trim_right(' \t')
		if t.len > 0 {
			ace_trimmed << t
		}
	}
	for l in pac_lines {
		t := l.trim_right(' \t')
		if t.len > 0 {
			pac_trimmed << t
		}
	}

	if ace_trimmed.join('\n') == pac_trimmed.join('\n') {
		println('  PASS ${desc}')
	} else {
		println('  FAIL ${desc}')
		println('  --- ace output ---')
		for l in ace_trimmed {
			println('  | ${l}')
		}
		println('  --- pacman output ---')
		for l in pac_trimmed {
			println('  | ${l}')
		}
		println('  --- end ---')
	}
}

fn main() {
	println('=== Sync (-S) compat checks ===')

	pacman_check := os.execute('which pacman')
	if pacman_check.exit_code != 0 {
		println('  SKIP: pacman not available')
		return
	}

	// 1. -Sl (list all packages in all sync repos)
	// Note: this may differ from pacman since ace reads from a different dbpath
	compare('-Sl', '-Sl list all sync packages')

	// 2. -Ss search (only if not too many results)
	compare('-Ss linux', '-Ss linux search')

	// 3. -Ss search for a specific package
	compare('-Ss "^glibc$"', '-Ss "^glibc$" exact search')

	// 4. -Si info on a well-known package
	compare('-Si glibc', '-Si glibc info')

	// 5. -Si on a small package
	compare('-Si pacman', '-Si pacman info')

	// 6. -Sg (list groups)
	compare('-Sg', '-Sg list groups')

	// 7. -Fl (files list — needs sync dbs populated)
	compare('-Fl glibc', '-Fl glibc files list')

	println('Done.')
}
