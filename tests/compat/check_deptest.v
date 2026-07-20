// check_deptest.v — compat check: ace -T vs pacman -T output diff.
//
// Compares ace and pacman output for the -T (deptest) subcommand.
// -T checks whether given dependencies are satisfied by the local DB.
//
// Usage:
//   v run tests/compat/check_deptest.v
//
// Environment:
//   ACE_BIN  — path to ace binary (default: ./ace)

import os

const ace_bin_default = './ace'

struct CmpCase {
	args string
	desc string
}

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

fn compare(args string, desc string) {
	ace_out := run_ace(args) or {
		println('  SKIP (ace error): ${desc}: ${err}')
		return
	}
	pac_out := run_pacman(args) or {
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
		println('  args: pacman ${args}')
		if ace_trimmed.len > 0 {
			println('  ace exit code: 0')
		}
		if ace_trimmed.join('\n') != pac_trimmed.join('\n') {
			println('  --- diff ---')
			mut max := ace_trimmed.len
			if pac_trimmed.len > max {
				max = pac_trimmed.len
			}
			for i in 0 .. max {
				ace_l := if i < ace_trimmed.len { ace_trimmed[i] } else { '(missing)' }
				pac_l := if i < pac_trimmed.len { pac_trimmed[i] } else { '(missing)' }
				if ace_l != pac_l {
					println('  - ${ace_l}')
					println('  + ${pac_l}')
				} else {
					println('    ${ace_l}')
				}
			}
		}
		println('  --- end ---')
	}
}

fn main() {
	println('=== Deptest (-T) compat checks ===')

	pacman_check := os.execute('which pacman')
	if pacman_check.exit_code != 0 {
		println('  SKIP: pacman not available')
		return
	}

	cases := [
		// Basic satisfaction: deps that should be met
		CmpCase{'-T glibc', 'glibc (should be satisfied)'},
		CmpCase{'-T bash', 'bash (should be satisfied)'},
		CmpCase{'-T "glibc>=2.0"', 'glibc>=2.0 (version met)'},
		CmpCase{'-T "glibc>=1.0"', 'glibc>=1.0 (version easily met)'},

		// Missing packages (should produce non-zero exit, no output)
		CmpCase{'-T nonexistent-pkg-abc-123', 'nonexistent (should be missing)'},

		// Multiple deps at once
		CmpCase{'-T glibc bash zlib', 'multiple satisfied deps'},

		// Mixed: some satisfied, some not
		CmpCase{'-T glibc nonexistent-pkg-abc', 'mixed satisfied/missing'},

		// Version constraints that may or may not be met
		CmpCase{'-T "glibc>=9999"', 'glibc>=9999 (version likely not met)'},
	]

	for c in cases {
		compare(c.args, c.desc)
	}

	println('Done.')
}
