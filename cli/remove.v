// -R (remove) subcommand — remove packages from the system.
//
// Flags (mirroring pacman's remove.c):
//   -s        remove unneeded dependencies (RECURSE)
//   -c        remove packages depending on targets (CASCADE)
//   -n        skip .pacsave backups (NOSAVE)
//   -u        remove unneeded orphans (UNNEEDED)
//   -d        skip dependency checks (NODEPS)
//   --dbonly  remove DB entry only (keep files)
//   --noscriptlet  don't run install scriptlets
//   --print   dry-run (show what would be done)
//
// Reference: pacman/src/pacman/remove.c
module cli

import config
import db
import hooks
import os
import trans
import util

// run_remove executes the -R operation.
// cfg and handle are pre-initialised (config loaded at startup).
pub fn run_remove(args &CliArgs, cfg &config.Config, handle &util.Handle) ! {
	// --- Validate targets ---
	if args.targets.len == 0 {
		return error('no targets specified for remove')
	}

	// --- Resolve database path ---
	dbpath := if args.root != '' {
		os.join_path(args.root, if args.dbpath != '' { args.dbpath } else { 'var/lib/ace' })
	} else if args.dbpath != '' {
		args.dbpath
	} else {
		handle.resolved_dbpath()
	}

	// --- Open local database ---
	mut local_db := db.init(dbpath)!
	local_db.populate()!

	// Wrap in Database for trans API
	mut localdb_db := db.Database{
		pkgcache: local_db.pkgcache
	}

	// --- Map CLI flags to trans.RemoveFlags ---
	mut flags := trans.RemoveFlags.none
	if args.cascading {
		flags |= trans.RemoveFlags.cascade
	}
	if args.recursive {
		flags |= trans.RemoveFlags.recurse
	}
	if args.unneeded {
		flags |= trans.RemoveFlags.unneeded
	}
	if args.nosave {
		flags |= trans.RemoveFlags.nosave
	}
	if args.noscriptlet {
		flags |= trans.RemoveFlags.noscriplet
	}
	if args.dbonly {
		flags |= trans.RemoveFlags.dbonly
	}

	// --- Print mode (dry-run) ---
	if args.print {
		println('Packages to remove:')
		for target in args.targets {
			if pkg := local_db.pkgcache[target] {
				println('  ${pkg.name} ${pkg.version}')
			} else {
				println('  ${target} (not installed)')
			}
		}
		if int(flags) & (int(trans.RemoveFlags.recurse) | int(trans.RemoveFlags.cascade)) != 0 {
			println('  (with recursive / cascading removal)')
		}
		return
	}

	// --- Confirmation prompt ---
	if !confirm_remove(args.targets, &local_db) {
		println('cancelled')
		return
	}

	// --- Remove each target ---
	mut errors := []string{}
	for target in args.targets {
		progress_callback(0, 'removing ${target}')

		// Look up the package and call remove_package directly
		p := localdb_db.pkgcache[target] or {
			errors << '${target}: not found'
			continue
		}
		trans.remove_package(handle, p, flags, mut localdb_db) or {
			errors << '${target}: ${err.msg()}'
			continue
		}

		progress_callback(100, 'removed ${target}')
	}

	// Run post-transaction hooks.
	run_remove_hooks(handle, args.targets)

	if errors.len > 0 {
		return error('failed to remove packages: ' + errors.join('; '))
	}
}

// ---------------------------------------------------------------------------
// confirm_remove — prompt the user before removing packages
// ---------------------------------------------------------------------------

fn confirm_remove(targets []string, local_db &db.LocalDB) bool {
	println('')
	for i, t in targets {
		if pkg := local_db.pkgcache[t] {
			if i == 0 {
				println('Packages (${targets.len}) ${pkg.name}-${pkg.version}')
			} else {
				println('             ${pkg.name}-${pkg.version}')
			}
		} else {
			if i == 0 {
				println('Packages (${targets.len}) ${t} (not installed)')
			} else {
				println('             ${t} (not installed)')
			}
		}
	}
	println('')
	print(':: Proceed with removal? [Y/n] ')
	response := os.input('').trim_space().to_lower()
	return response == '' || response == 'y' || response == 'yes'
}

// ---------------------------------------------------------------------------
// progress_callback — default progress display
// ---------------------------------------------------------------------------

fn progress_callback(percent int, message string) {
	if percent == 0 {
		eprintln('${message}...')
	} else if percent == 100 {
		eprintln('${message}.')
	}
}

fn run_remove_hooks(handle &util.Handle, targets []string) {
	if handle.hookedirs.len == 0 {
		return
	}
	mut engine := hooks.new_hook_engine(handle)
	mut util_pkgs := []&util.Package{}
	for t in targets {
		util_pkgs << &util.Package{name: t, version: ''}
	}
	engine.set_packages([]&util.Package{}, util_pkgs)
	engine.run_post(util_pkgs) or {
		eprintln('warning: post-transaction hook failed: ${err}')
	}
}
