// check_query.v — compat check: ace -Q vs pacman -Q output diff.
//
// Compares ace and pacman output for the -Q subcommand on the real local DB.
// Skips tests when running on a non-Arch system or when the local DB is empty.
//
// Usage:
//   v run tests/compat/check_query.v
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

	// Normalize trailing whitespace per line
	ace_lines := ace_out.split('\n')
	pac_lines := pac_out.split('\n')
	mut ace_trimmed_lines := []string{}
	mut pac_trimmed_lines := []string{}
	for line in ace_lines {
		t := line.trim_right(' \t')
		if t.len > 0 {
			ace_trimmed_lines << t
		}
	}
	for line in pac_lines {
		t := line.trim_right(' \t')
		if t.len > 0 {
			pac_trimmed_lines << t
		}
	}

	ace_trimmed := ace_trimmed_lines.join('\n')
	pac_trimmed := pac_trimmed_lines.join('\n')

	if ace_trimmed == pac_trimmed {
		println('  PASS ${desc}')
	} else {
		println('  FAIL ${desc}')
		println('  --- ace output ---')
		for line in ace_lines {
			println('  | ${line}')
		}
		println('  --- pacman output ---')
		for line in pac_lines {
			println('  | ${line}')
		}
		println('  --- end ---')
	}
}

fn main() {
	println('=== Query (-Q) compat checks ===')

	// Guard: check pacman is available
	pacman_check := os.execute('which pacman')
	if pacman_check.exit_code != 0 {
		println('  SKIP: pacman not available')
		return
	}

	// 1. -Q (list all packages — name version)
	compare('-Q', '-Q list all packages')

	// 2. -Q (quiet mode)
	compare('-Qq', '-Qq quiet list')

	// 3. -Qi on a well-known package
	compare('-Qi glibc', '-Qi glibc info')

	// 4. -Qi on bash
	compare('-Qi bash', '-Qi bash info')

	// 5. -Ql on a known package (list files)
	compare('-Ql bash', '-Ql bash file list')

	// 6. -Qo on a path owned by a well-known package
	compare('-Qo /bin/bash', '-Qo /bin/bash owner')

	// 7. -Qo on a shared lib path
	compare('-Qo /usr/lib/libc.so', '-Qo /usr/lib/libc.so owner')

	// 8. -Qs search (full-text search)
	compare('-Qs libc', '-Qs libc search')

	// 9. -Qn (native packages only — currently empty list on both)
	compare('-Qn', '-Qn native only')

	// 10. -Qd (deps only)
	compare('-Qd', '-Qd deps only')

	// 11. -Qe (explicit only)
	compare('-Qe', '-Qe explicit only')

	println('Done.')
}
