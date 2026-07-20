// CLI argument types for the ace package manager.
//
// Reference: pacman/src/pacman/pacman.c:1178 (main arg parsing)
module cli

import os

// Operation represents the top-level subcommand selected via flags.
pub enum Operation {
	main
	query    // -Q
	remove   // -R
	sync     // -S
	upgrade  // -U
	database // -D
	deptest  // -T
	files    // -F
}

// QueryOp represents the -Q sub-operation — kept for test backward compat.
pub enum QueryOp {
	list   // -Q  (plain list)
	info   // -Qi
	files  // -Ql
	search // -Qs
	owner  // -Qo
}

// CliArgs holds all parsed command-line arguments.
pub struct CliArgs {
pub mut:
	operation Operation
	query_op  QueryOp
	targets   []string // positional args (package names, search terms, etc.)
	config    string   // --config
	root      string   // --root / -r
	dbpath    string   // --dbpath / -b
	// --- Global options ---
	cachedirs []string // --cachedir  (may appear multiple times)
	hookdirs  []string // --hookdir   (may appear multiple times)
	gpgdir    string   // --gpgdir
	logfile   string   // --logfile
	arch      []string // --arch     (may appear multiple times)
	pacman_mode bool   // --pacman   use pacman paths (config, dbpath, etc.)
	transfer    bool   // --transfer migrate pacman data to ace native directories
	all_optional bool  // --all-optional  install all optional deps
	deptree      bool  // --deptree       show dependency tree
	show_history bool  // --history       show transaction history
	keyring_init     bool   // --keyring-init   initialize GPG keyring
	keyring_populate string // --keyring-populate <name>  import keyring keys
	noconfirm bool     // --noconfirm
	verbose   bool     // --verbose / -v
	debug     int      // --debug    (optional argument, 0=no, 1=debug, 2=debug+function)
	// --- Query (-Q) flags ---
	query_info       int    // -i / --info  count (0,1,2)
	query_list       bool   // -l / --list
	query_changelog  bool   // -c / --changelog
	query_check      int    // -k / --check count (0,1,2)
	query_groups     int    // -g / --groups count (0,1,2)
	query_search     bool   // -s / --search
	query_owns       bool   // -o / --owns
	query_file       bool   // -p / --file  (pkg file, not DB)
	query_deps       bool   // -d / --deps
	query_explicit   bool   // -e / --explicit
	query_native     bool   // -n / --native
	query_foreign    bool   // -m / --foreign
	query_unrequired int    // -t / --unrequired count (0,1,2)
	query_upgrades   bool   // -u / --upgrades
	quiet            bool   // -q / --quiet (per-operation for -Q)
	// --- Remove (-R) flags ---
	recursive   bool // -s  remove dependencies too
	cascading   bool // -c  remove packages that depend on targets
	nosave      bool // -n  don't save modified config files
	unneeded    bool // -u  remove unneeded orphans
	nodeps      bool // -d  skip dependency checks
	dbonly      bool // --dbonly  remove DB entry only (leave files)
	noscriptlet bool // --noscriptlet  don't run install scripts
	print       bool // --print  dry-run
	// --- Upgrade (-U) flags ---
	asdeps          bool     // --asdeps  mark as dependency
	asexplicit      bool     // --asexplicit  mark as explicitly installed
	needed          bool     // --needed  don't reinstall up-to-date
	download_only   bool     // -w  download only (no install)
	overwrite_files []string // --overwrite  list of glob patterns
	ignore_pkgs     []string // --ignore  list of packages to ignore
	// --- Sync (-S) flags ---
	sync_count    int  // -y  count: 0=none, 1=-Sy, 2=-Syy
	sync_search   bool // -Ss
	sync_info     int  // -i  count: 0=none, 1=-Si, 2=-Sii
	sync_list     bool // -Sl
	sync_group    int  // -g  count: 0=none, 1=-Sg, 2=-Sgg
	sync_clean    int  // -c  count: 0=none, 1=-Sc, 2=-Scc
	sync_upgrade  int  // -u  count: 0=none, 1=-Su, 2=-Suu
	// --- Database (-D) flags ---
	database_check     int  // -k/--check  count: 0=none, 1=-Dk, 2=-Dkk
	database_asdeps    bool // --asdeps  mark as dependency
	database_asexplicit bool // --asexplicit  mark as explicitly installed
	// --- Files (-F) flags ---
	files_list      bool // -l/--list  list files in packages
	files_refresh   int  // -y/--refresh  count: 0=none, 1=-Fy, 2=-Fyy
	files_regex     bool // -x/--regex  treat search as regex
	files_machinereadable bool // --machinereadable  null-delimited output
}

// print_usage prints the usage/help text to stdout.
pub fn print_usage() {
	println('ace - Arch Linux Compatible Package Manager')
	println('')
	println('Usage: ace [options] [operation]')
	println('')
	println('Operations:')
	println('  -Q, --query    Query the package database')
	println('  -R, --remove   Remove packages')
	println('  -S, --sync     Synchronize packages')
	println('  -U, --upgrade  Upgrade packages')
	println('  -D, --database Database operations (check, mark)')
	println('  -T, --deptest  Dependency satisfiability test')
	println('  -F, --files    File query operations')
	println('')
	println('Options:')
	println('  --config <path>  Use an alternate config file')
	println('  --root, -r <path> Set an alternate installation root')
	println('  --dbpath, -b <path> Set an alternate database path')
	println('  --cachedir <dir> Set an alternate package cache directory')
	println('  --hookdir <dir>  Set an alternate hook directory')
	println('  --gpgdir <path>  Set an alternate GnuPG home directory')
	println('  --logfile <path> Set an alternate log file')
	println('  --arch <arch>    Set an alternate architecture')
	println('  --pacman         Use pacman-compatible paths (config, dbpath, etc.)')
	println('  --transfer       Migrate pacman data to ace native directories')
	println('  --all-optional   Install all optional dependencies')
	println('  --deptree        Show recursive dependency tree for a package')
	println('  --history        Show human-readable transaction history')
	println('  --keyring-init   Initialize a fresh GPG keyring')
	println('  --keyring-populate <name>  Import keys from a keyring package')
	println('  --noconfirm      Do not ask for confirmation')
	println('  --verbose, -v    Output more status messages')
	println('  --debug          Show debug messages')
	println('  --help, -h       Show this help message')
	println('  --version        Show version information')
	println('')
	println('See the ace(1) manual page or README.md for full documentation.')
}

// parse_args reads os.args and returns parsed CliArgs.
pub fn parse_args() CliArgs {
	return parse_args_from(os.args)
}

// parse_args_from parses an arbitrary string slice as CLI args.
// Exported so tests can inject custom arguments without depending
// on os.args.
pub fn parse_args_from(raw []string) CliArgs {
	mut args := CliArgs{
		operation: .main
		query_op:  .list
	}
	if raw.len <= 1 {
		return args
	}

	// Check for --version, --help, or -h across all args before dispatching.
	for arg in raw[1..] {
		if arg == '--version' {
			println('ace 0.0.1')
			exit(0)
		}
		if arg == '--help' || arg == '-h' {
			print_usage()
			exit(0)
		}
	}

	mut i := 1
	for i < raw.len {
		arg := raw[i]
		if arg == '--' {
			// Everything after -- is a positional target
			i++
			for i < raw.len {
				args.targets << raw[i]
				i++
			}
			break
		}

		if arg == '--config' {
			i++
			if i < raw.len {
				args.config = raw[i]
			}
			i++
			continue
		}

		if arg == '--root' || arg == '-r' {
			i++
			if i < raw.len {
				args.root = raw[i]
			}
			i++
			continue
		}

		if arg == '--dbpath' || arg == '-b' {
			i++
			if i < raw.len {
				args.dbpath = raw[i]
			}
			i++
			continue
		}

		if arg == '--cachedir' {
			i++
			if i < raw.len {
				args.cachedirs << raw[i]
			}
			i++
			continue
		}

		if arg == '--hookdir' {
			i++
			if i < raw.len {
				args.hookdirs << raw[i]
			}
			i++
			continue
		}

		if arg == '--gpgdir' {
			i++
			if i < raw.len {
				args.gpgdir = raw[i]
			}
			i++
			continue
		}

		if arg == '--logfile' {
			i++
			if i < raw.len {
				args.logfile = raw[i]
			}
			i++
			continue
		}

		if arg == '--arch' {
			i++
			if i < raw.len {
				args.arch << raw[i]
			}
			i++
			continue
		}

		if arg == '--noconfirm' {
			args.noconfirm = true
			i++
			continue
		}

		if arg == '--confirm' {
			args.noconfirm = false
			i++
			continue
		}

		if arg == '--verbose' || arg == '-v' {
			args.verbose = true
			i++
			continue
		}

		if arg == '--pacman' {
			args.pacman_mode = true
			i++
			continue
		}

		if arg == '--transfer' {
			args.transfer = true
			i++
			continue
		}

		if arg == '--all-optional' {
			args.all_optional = true
			i++
			continue
		}

		if arg == '--deptree' {
			args.deptree = true
			i++
			continue
		}

		if arg == '--history' {
			args.show_history = true
			i++
			continue
		}

		if arg == '--keyring-init' {
			args.keyring_init = true
			i++
			continue
		}

		if arg == '--keyring-populate' {
			i++
			if i < raw.len {
				args.keyring_populate = raw[i]
			}
			i++
			continue
		}

		if arg == '--debug' || arg.starts_with('--debug=') {
			if arg.starts_with('--debug=') {
				level_str := arg['--debug='.len..]
				args.debug = if level_str.len > 0 { level_str.int() } else { 1 }
			} else {
				// --debug optionally followed by a level as next token
				if i + 1 < raw.len {
					i++
					args.debug = raw[i].int()
				} else {
					args.debug = 1
				}
			}
			i++
			continue
		}

		// Operation flags
		if arg == '-T' {
			args.operation = .deptest
			i++
			continue
		}
		// ------------------------------------------------------------
		// -Q  (query)  — combined flags like -Qii, -Qdt, -Qkk are supported
		// ------------------------------------------------------------
		if arg.len >= 2 && arg[0] == `-` && arg[1] == `Q` {
			args.operation = .query
			// Parse sub-flags from the remainder after 'Q'
			for j := 2; j < arg.len; j++ {
				match arg[j] {
					`c` { args.query_changelog = true }
					`d` { args.query_deps = true }
					`e` { args.query_explicit = true }
					`g` { args.query_groups++ }
					`i` { args.query_info++ }
					`k` { args.query_check++ }
					`l` { args.query_list = true }
					`m` { args.query_foreign = true }
					`n` { args.query_native = true }
					`o` { args.query_owns = true }
					`p` { args.query_file = true }
					`q` { args.quiet = true }
					`s` { args.query_search = true }
					`t` { args.query_unrequired++ }
					`u` { args.query_upgrades = true }
					else {}
				}
			}
			// Set query_op for test backward compat
			if args.query_search {
				args.query_op = .search
			} else if args.query_owns {
				args.query_op = .owner
			} else if args.query_info > 0 {
				args.query_op = .info
			} else if args.query_list {
				args.query_op = .files
			} else {
				args.query_op = .list
			}
			i++
			continue
		}

		// ------------------------------------------------------------
		// -R  (remove)  — combined flags like -Rscn are supported
		// ------------------------------------------------------------
		if arg.len >= 2 && arg[0] == `-` && arg[1] == `R` {
			args.operation = .remove
			// Parse sub-flags from the remainder after 'R'
			for j := 2; j < arg.len; j++ {
				match arg[j] {
					`s` { args.recursive = true }
					`c` { args.cascading = true }
					`n` { args.nosave = true }
					`u` { args.unneeded = true }
					`d` { args.nodeps = true }
					else {}
				}
			}
			i++
			continue
		}

		// ------------------------------------------------------------
		// -U  (upgrade)
		// ------------------------------------------------------------
		if arg == '-U' {
			args.operation = .upgrade
			i++
			continue
		}

		// ------------------------------------------------------------
		// -S  (sync)  — combined flags like -Sy, -Syy, -Su, -Syu
		// ------------------------------------------------------------
		if arg.len >= 2 && arg[0] == `-` && arg[1] == `S` {
			args.operation = .sync
			// Parse sub-flags from the remainder after 'S'
			if arg.len == 2 {
				// bare -S with no sub-flags
				i++
				continue
			}
			for j := 2; j < arg.len; j++ {
				match arg[j] {
					`y` { args.sync_count++ }
					`u` { args.sync_upgrade++ }
					`w` { args.download_only = true }
					`c` { args.sync_clean++ }
					`s` { args.sync_search = true }
					`i` { args.sync_info++ }
					`l` { args.sync_list = true }
					`g` { args.sync_group++ }
					`q` { args.quiet = true }
					else {}
				}
			}
			i++
			continue
		}

		// ------------------------------------------------------------
		// -D  (database)  — combined flags like -Dk, -Dkk, -Dq
		// ------------------------------------------------------------
		if arg.len >= 2 && arg[0] == `-` && arg[1] == `D` {
			args.operation = .database
			// Parse sub-flags from the remainder after 'D'
			for j := 2; j < arg.len; j++ {
				match arg[j] {
					`k` { args.database_check++ }
					`q` { args.quiet = true }
					else {}
				}
			}
			i++
			continue
		}

		// ------------------------------------------------------------
		// -F  (files)  — combined flags like -Fl, -Fy, -Fx, -Fq
		// ------------------------------------------------------------
		if arg.len >= 2 && arg[0] == `-` && arg[1] == `F` {
			args.operation = .files
			// Parse sub-flags from the remainder after 'F'
			for j := 2; j < arg.len; j++ {
				match arg[j] {
					`l` { args.files_list = true }
					`y` { args.files_refresh++ }
					`x` { args.files_regex = true }
					`q` { args.quiet = true }
					else {}
				}
			}
			i++
			continue
		}

		// ------------------------------------------------------------
		// Long options shared by -R and -U
		// ------------------------------------------------------------
		if arg == '--dbonly' {
			args.dbonly = true
			i++
			continue
		}
		if arg == '--noscriptlet' {
			args.noscriptlet = true
			i++
			continue
		}
		if arg == '--print' {
			args.print = true
			i++
			continue
		}

		// ------------------------------------------------------------
		// Long options for -U  (upgrade)
		// ------------------------------------------------------------
		if arg == '--asdeps' {
			args.asdeps = true
			i++
			continue
		}
		if arg == '--asexplicit' {
			args.asexplicit = true
			i++
			continue
		}
		if arg == '--needed' {
			args.needed = true
			i++
			continue
		}
		if arg == '--overwrite' {
			i++
			if i < raw.len {
				args.overwrite_files << raw[i]
			}
			i++
			continue
		}
		if arg == '--ignore' {
			i++
			if i < raw.len {
				args.ignore_pkgs << raw[i]
			}
			i++
			continue
		}
		if arg == '-w' {
			args.download_only = true
			i++
			continue
		}

		// ------------------------------------------------------------
		// Long options for -D  (database)
		// ------------------------------------------------------------
		if arg == '--check' {
			args.database_check++
			i++
			continue
		}

		// ------------------------------------------------------------
		// Long options for -F  (files)
		// ------------------------------------------------------------
		if arg == '--list' {
			args.files_list = true
			i++
			continue
		}
		if arg == '--refresh' {
			args.files_refresh++
			i++
			continue
		}
		if arg == '--regex' {
			args.files_regex = true
			i++
			continue
		}
		if arg == '--machinereadable' {
			args.files_machinereadable = true
			i++
			continue
		}

		// Unrecognized flags are skipped
		if arg.starts_with('-') {
			i++
			continue
		}

		// Positional argument
		args.targets << arg
		i++
	}

	return args
}
