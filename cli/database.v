// -D (database) subcommand — modify or check the local package database.
//
// Sub-operations:
//   -Dk / -Dkk      check local or local+sync database consistency
//   -D --asdeps     mark packages as installed as dependency
//   -D --asexplicit mark packages as explicitly installed
//
// Reference: pacman/src/pacman/database.c
module cli

import db
import os

// =============================================================================
// Public entry point
// =============================================================================

// run_database executes the -D operation based on the parsed args.
pub fn run_database(args &CliArgs) ! {
	dbpath := if args.root != '' {
		os.join_path(args.root, if args.dbpath != '' { args.dbpath } else { 'var/lib/ace' })
	} else if args.dbpath != '' {
		args.dbpath
	} else {
		'/var/lib/ace'
	}

	mut local_db := db.init(dbpath)!
	local_db.populate()!

	// 1. Check mode (-Dk / -Dkk)
	if args.database_check > 0 {
		return run_db_check(args, &local_db)
	}

	// 2. Change install reason (--asdeps / --asexplicit)
	asdeps := args.database_asdeps || args.asdeps
	asexplicit := args.database_asexplicit || args.asexplicit

	if asdeps || asexplicit {
		if asdeps && asexplicit {
			return error('cannot specify both --asdeps and --asexplicit')
		}
		if args.targets.len == 0 {
			return error('no targets specified (use -h for help)')
		}
		return change_install_reason(args, &local_db, asdeps, asexplicit)
	}

	return error('no database operation specified (use -h for help)')
}

// =============================================================================
// Check mode (-Dk / -Dkk)
// =============================================================================

fn run_db_check(args &CliArgs, local_db &db.LocalDB) ! {
	mut errors := 0

	// 1. Check local database directory entries for missing desc/files.
	errors += check_local_db_files(local_db)

	// 2. Check missing dependencies.
	errors += check_local_db_deps(local_db)

	// 3. Check conflicts.
	errors += check_local_db_conflicts(local_db)

	// 4. Check filelist conflicts.
	errors += check_local_db_filelist_conflicts(local_db)

	if errors == 0 && !args.quiet {
		println('No database errors have been found!')
	}

	if errors > 0 {
		return error('${errors} error(s) found during database check')
	}
}

// check_local_db_files checks that every local DB package has desc and files.
fn check_local_db_files(local_db &db.LocalDB) int {
	mut errors := 0

	for pkgname, _ in local_db.pkgcache {
		// Find the package directory in the filesystem.
		// The local DB stores packages as {dbpath}/local/{name}-{version}/
		p := local_db.pkgcache[pkgname] or { continue }
		pkg_dir_name := '${pkgname}-${p.version}'
		pkg_dir := os.join_path(local_db.dbpath, pkg_dir_name)

		if !os.is_dir(pkg_dir) {
			eprintln(err_str("package directory for '${pkgname}' is missing"))
			errors++
			continue
		}

		desc_path := os.join_path(pkg_dir, 'desc')
		if !os.exists(desc_path) {
			eprintln(err_str("'${pkgname}': description file is missing"))
			errors++
		}

		files_path := os.join_path(pkg_dir, 'files')
		if !os.exists(files_path) {
			eprintln(err_str("'${pkgname}': file list is missing"))
			errors++
		}
	}

	return errors
}

// check_local_db_deps checks for missing dependencies.
fn check_local_db_deps(local_db &db.LocalDB) int {
	mut errors := 0

	for _, pkg in local_db.pkgcache {
		for dep in pkg.depends {
			// Check if the dependency is satisfied by any installed package.
			mut satisfied := false
			for _, other in local_db.pkgcache {
				if other.name == dep.name {
					satisfied = true
					break
				}
				// Also check provides.
				for prov in other.provides {
					if prov.name == dep.name {
						satisfied = true
						break
					}
				}
				if satisfied {
					break
				}
			}
			if !satisfied {
				eprintln(err_str("missing dependency '${dep.to_string()}' for '${pkg.name}'"))
				errors++
			}
		}
	}

	return errors
}

// check_local_db_conflicts checks for package conflicts.
fn check_local_db_conflicts(local_db &db.LocalDB) int {
	mut errors := 0

	for _, pkg in local_db.pkgcache {
		for conflict in pkg.conflicts {
			mut found := false
			for _, other in local_db.pkgcache {
				if other.name == conflict.name {
					// Check if the conflicting package provides the conflict target.
					// In a basic check, just flag any package name match.
					if other.name == conflict.name {
						eprintln(err_str("'${pkg.name}' conflicts with '${other.name}'"))
						errors++
						found = true
						break
					}
				}
			}
			if found {
				break
			}
		}
	}

	return errors
}

// check_local_db_filelist_conflicts checks for file ownership conflicts.
fn check_local_db_filelist_conflicts(local_db &db.LocalDB) int {
	// Build a map of file -> package, flagging duplicates.
	mut file_owner := map[string]string{}
	mut errors := 0

	for _, pkg in local_db.pkgcache {
		for f in pkg.files.files {
			// Only check files (skip directories, which end in '/').
			if f.name.len > 0 && f.name[f.name.len - 1] == `/` {
				continue
			}
			if existing := file_owner[f.name] {
				eprintln(err_str("file owned by '${existing}' and '${pkg.name}': '${f.name}'"))
				errors++
			} else {
				file_owner[f.name] = pkg.name
			}
		}
	}

	return errors
}

// =============================================================================
// Change install reason (--asdeps / --asexplicit)
// =============================================================================

fn change_install_reason(args &CliArgs, local_db &db.LocalDB, asdeps bool, _ bool) ! {
	reason := if asdeps { db.PackageReason.depend } else { db.PackageReason.explicit }
	reason_label := if asdeps {
		"installed as dependency"
	} else {
		"explicitly installed"
	}

	mut errors := []string{}

	for target in args.targets {
		mut p := local_db.pkgcache[target] or {
			errors << "'${target}' was not found"
			continue
		}

		// Update the reason in memory.
		p.reason = reason

		// Write back to the local database.
		db_path := os.dir(local_db.dbpath) // strip 'local/' suffix
		db.write_pkg(db_path, p, db.infrq_desc) or {
			errors << "'${target}': could not set install reason (${err.msg()})"
			continue
		}

		if !args.quiet {
			println("${target}: install reason has been set to '${reason_label}'")
		}
	}

	if errors.len > 0 {
		return error(errors.join('; '))
	}
}
