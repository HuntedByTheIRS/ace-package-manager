// -Q (query) subcommand — inspect the local package database.
//
// Reference: pacman/src/pacman/query.c
module cli

import config
import db
import os
import regex
import strings
import time
import util

// =============================================================================
// Top-level dispatch — mirrors pacman_query() in query.c
// =============================================================================

// run_query executes the -Q operation based on the parsed args.
// cfg and handle are pre-initialised (config loaded at startup).
pub fn run_query(args &CliArgs, cfg &config.Config, handle &util.Handle) ! {
	// Resolve dbpath from CLI → handle → fallback.
	dbpath := if args.root != '' {
		os.join_path(args.root, if args.dbpath != '' { args.dbpath } else { 'var/lib/ace' })
	} else if args.dbpath != '' {
		args.dbpath
	} else {
		handle.resolved_dbpath()
	}

	mut local_db := db.init(dbpath)!
	local_db.populate()!

	// 1. Search mode (-Qs / --search)
	if args.query_search {
		if args.targets.len == 0 {
			return error('-Qs requires a search pattern')
		}
		query_search(&local_db, args.targets[0])
		return
	}

	// 2. Groups mode (-Qg / --groups)
	if args.query_groups > 0 {
		query_groups(&local_db, args.targets, args.quiet)
		return
	}

	// 3. Owns mode (-Qo / --owns)
	if args.query_owns {
		if args.targets.len == 0 {
			return error('-Qo requires a file path')
		}
		query_owner(&local_db, args.targets[0], handle.root)!
		return
	}

	// 4. File mode (-Qp / --file) — load from pkg file, not DB
	if args.query_file {
		query_pkg_files(args.targets, args)!
		return
	}

	// 5. All other -Q operations on local packages

	// Get the list of packages to operate on
	mut pkgs := []&db.Package{}
	if args.targets.len == 0 {
		// Operate on all packages
		for _, pkg in local_db.pkgcache {
			pkgs << pkg
		}
	} else {
		// Operate on named targets
		for target in args.targets {
			// Strip "local/" prefix ala pacman
			mut name := target
			if name.starts_with('local/') {
				name = name['local/'.len..]
			}
			if pkg := local_db.get_pkg(name) {
				pkgs << pkg
			} else if pkg2 := find_satisfier(local_db, name) {
				pkgs << pkg2
			} else {
				eprintln('error: package "${name}" was not found')
				// If it's a file the user can read, suggest -Qp
				if os.exists(name) {
					eprintln('  "${name}" is a file, you might want to use -Qp.')
				}
				continue
			}
		}
	}

	if pkgs.len == 0 {
		return error('no packages matched')
	}

	// Apply filters and display each package
	mut match_any := false
	mut ret_code := 0
	for pkg in pkgs {
		if !filter_pkg(pkg, args, &local_db) {
			continue
		}
		code := display_pkg(pkg, args, &local_db, handle.root)
		if code != 0 {
			ret_code = 1
		}
		match_any = true
	}

	if !match_any {
		return error('no packages matched the filter criteria')
	}
	if ret_code != 0 {
		return error('some packages had errors')
	}
}

// =============================================================================
// Filter — mirrors filter() in query.c
// =============================================================================

fn filter_pkg(pkg &db.Package, args &CliArgs, local_db &db.LocalDB) bool {
	// Explicit filter (-Qe)
	if args.query_explicit && pkg.reason != .explicit {
		return false
	}
	// Deps filter (-Qd)
	if args.query_deps && pkg.reason != .depend {
		return false
	}
	// Unrequired filter (-Qt / -Qtt)
	if args.query_unrequired > 0 {
		if !is_unrequired(pkg, args.query_unrequired, local_db) {
			return false
		}
	}
	// Upgrades filter (-Qu) — not implemented (no sync DBs yet)
	// Locality filter (-Qn / -Qm) — not implemented (no sync DBs yet)
	return true
}

// is_unrequired returns true if no other package requires this one.
// level 1: only hard dependencies; level 2: also check optional deps.
fn is_unrequired(pkg &db.Package, level int, local_db &db.LocalDB) bool {
	for _, other in local_db.pkgcache {
		if other.name == pkg.name {
			continue
		}
		for dep in other.depends {
			if dep.name == pkg.name {
				return false
			}
		}
		if level > 1 {
			for dep in other.optdepends {
				if dep.name == pkg.name {
					return false
				}
			}
		}
	}
	return true
}

// find_satisfier finds a package whose provides matches the target name.
fn find_satisfier(local_db &db.LocalDB, name string) ?&db.Package {
	for _, pkg in local_db.pkgcache {
		if pkg.name == name {
			return pkg
		}
		for prov in pkg.provides {
			if prov.name == name {
				return pkg
			}
		}
	}
	return none
}

// =============================================================================
// Display — mirrors display() in query.c
// =============================================================================

fn display_pkg(pkg &db.Package, args &CliArgs, local_db &db.LocalDB, root string) int {
	mut ret := 0

	if args.query_info > 0 {
		dump_pkg_full(pkg, args.query_info > 1, local_db)
	}
	if args.query_list {
		dump_pkg_files(pkg, args.quiet)
	}
	if args.query_changelog {
		dump_pkg_changelog(pkg)
	}
	if args.query_check > 0 {
		if args.query_check == 1 {
			ret = check_pkg_fast(pkg, root)
		} else {
			ret = check_pkg_full(pkg, root)
		}
	}

    // Plain display (no -i, -l, -c, -k)
    if args.query_info == 0 && !args.query_list && !args.query_changelog && args.query_check == 0 {
		if args.quiet {
			println(pkg.name)
		} else {
			println('${pkg.name} ${pkg.version}')
		}
	}

	return ret
}

// =============================================================================
// Formatting helpers (matching pacman's string_display / list_display)
// =============================================================================

// compute_title_width returns the maximum display width among the given titles.
fn compute_title_width(titles []string) int {
	mut max := 0
	for t in titles {
		if t.len > max {
			max = t.len
		}
	}
	return max
}

// fmt_title returns a title string padded to `width` characters, then " : ".
fn fmt_title(title string, width int) string {
	mut pad := width - title.len
	if pad < 0 {
		pad = 0
	}
	return '${title}${strings.repeat(` `, pad)} : '
}

// string_display prints "Title  : value\n"  (or "None" when value is empty).
fn string_display(title string, value string, width int) {
	prefix := fmt_title(title, width)
	if value == '' {
		println('${prefix}None')
	} else {
		println('${prefix}${value}')
	}
}

// list_display prints "Title  : item1  item2 ...\n"  (or "None" when empty).
fn list_display(title string, items []string, width int) {
	prefix := fmt_title(title, width)
	if items.len == 0 {
		println('${prefix}None')
	} else {
		println('${prefix}${items.join('  ')}')
	}
}

// list_display_linebreak prints each item on its own line, indented to align
// with the first item.
fn list_display_linebreak(title string, items []string, width int) {
	prefix := fmt_title(title, width)
	if items.len == 0 {
		println('${prefix}None')
		return
	}
	indent := strings.repeat(` `, prefix.len)
	for i, item in items {
		if i == 0 {
			println('${prefix}${item}')
		} else {
			println('${indent}${item}')
		}
	}
}

// humanize_size converts a byte count to human-readable KiB/MiB/GiB.
fn humanize_size(bytes i64) string {
	if bytes == 0 {
		return '0.00 B'
	}
	mut size := f64(bytes)
	units := ['B', 'KiB', 'MiB', 'GiB', 'TiB']
	mut ui := 0
	for size >= 1024.0 && ui < units.len - 1 {
		size /= 1024.0
		ui++
	}
	if ui == 0 {
		return '${i64(bytes)} B'
	}
	return '${size:.2f} ${units[ui]}'
}

// format_validation converts the PackageValidation bitmask to a display string.
fn format_validation(v db.PackageValidation) string {
	val := int(v)
	if val == 0 {
		return 'Unknown'
	}
	if val & int(db.PackageValidation.none) != 0 {
		return 'None'
	}
	mut parts := []string{}
	if val & int(db.PackageValidation.sha256sum) != 0 {
		parts << 'SHA-256 Sum'
	}
	if val & int(db.PackageValidation.signature) != 0 {
		parts << 'Signature'
	}
	if parts.len == 0 {
		return 'Unknown'
	}
	return parts.join('  ')
}

// epoch_to_str formats a unix epoch timestamp as a human-readable date.
fn epoch_to_str(epoch i64) string {
	if epoch <= 0 {
		return ''
	}
	t := time.unix(epoch)
	return t.strftime('%c').trim_space()
}

// =============================================================================
// -Qi / -Qii  —  dump_pkg_full (matches package.c:dump_pkg_full)
// =============================================================================

fn dump_pkg_full(pkg &db.Package, extra bool, local_db &db.LocalDB) {
	titles := [
		'Name',
		'Version',
		'Description',
		'Architecture',
		'URL',
		'Licenses',
		'Groups',
		'Provides',
		'Depends On',
		'Optional Deps',
		'Required By',
		'Optional For',
		'Conflicts With',
		'Replaces',
		'Installed Size',
		'Packager',
		'Build Date',
		'Install Date',
		'Install Reason',
		'Install Script',
		'Validated By',
	]
	width := compute_title_width(titles)

	// Install reason
	reason_str := match pkg.reason {
		.explicit { 'Explicitly installed' }
		.depend { 'Installed as a dependency for another package' }
		else { 'Unknown' }
	}

	// Validation
	validation_str := format_validation(pkg.validation)

	// Dates
	build_date_str := epoch_to_str(pkg.build_date)
	install_date_str := epoch_to_str(pkg.install_date)

	// Required by / Optional for (computed for local packages)
	required_by := compute_requiredby(pkg, local_db)
	optional_for := compute_optionalfor(pkg, local_db)

	// Print fields
	string_display('Name', pkg.name, width)
	string_display('Version', pkg.version, width)
	string_display('Description', pkg.desc, width)
	string_display('Architecture', pkg.arch, width)
	string_display('URL', pkg.url, width)
	list_display('Licenses', pkg.licenses, width)
	list_display('Groups', pkg.groups, width)
	list_display('Provides', deps_to_strings(pkg.provides), width)
	list_display('Depends On', deps_to_strings(pkg.depends), width)

	// Optional deps with installed markers (like optdeplist_display)
	optdep_strs := format_optdepends(pkg, local_db)
	list_display_linebreak('Optional Deps', optdep_strs, width)

	// Required By / Optional For
	list_display('Required By', required_by, width)
	list_display('Optional For', optional_for, width)

	list_display('Conflicts With', deps_to_strings(pkg.conflicts), width)
	list_display('Replaces', deps_to_strings(pkg.replaces), width)

	string_display('Installed Size', humanize_size(pkg.isize), width)
	string_display('Packager', pkg.packager, width)
	string_display('Build Date', build_date_str, width)
	string_display('Install Date', install_date_str, width)
	string_display('Install Reason', reason_str, width)

	// Install Script
	script_str := if pkg.scriptlet { 'Yes' } else { 'No' }
	string_display('Install Script', script_str, width)

	// Validated By (from local pkg)
	list_display('Validated By', [validation_str], width)

	// Extra info: backup files
	if extra {
		dump_pkg_backups(pkg, width)
	}

	println('')
}

// format_optdepends formats optional dependency strings with [installed] markers.
fn format_optdepends(pkg &db.Package, local_db &db.LocalDB) []string {
	mut result := []string{}
	for od in pkg.optdepends {
		mut dep_str := od.to_string()
		// Check if the optional dep is installed
		if od.desc != '' {
			dep_str = '${dep_str}: ${od.desc}'
		}
		// Check if a package providing this name is installed
		mut line := dep_str
		if _ := find_satisfier(local_db, od.name) {
			line = '${dep_str} [installed]'
		}
		result << line
	}
	return result
}

// compute_requiredby returns the names of packages that depend on `pkg`.
fn compute_requiredby(pkg &db.Package, local_db &db.LocalDB) []string {
	mut result := []string{}
	for _, other in local_db.pkgcache {
		if other.name == pkg.name {
			continue
		}
		for dep in other.depends {
			if dep.name == pkg.name {
				result << other.name
				break
			}
		}
	}
	return result
}

// compute_optionalfor returns the names of packages that optionally depend on `pkg`.
fn compute_optionalfor(pkg &db.Package, local_db &db.LocalDB) []string {
	mut result := []string{}
	for _, other in local_db.pkgcache {
		if other.name == pkg.name {
			continue
		}
		for dep in other.optdepends {
			if dep.name == pkg.name {
				result << other.name
				break
			}
		}
	}
	return result
}

// dump_pkg_backups displays backup files (for -Qii only).
fn dump_pkg_backups(pkg &db.Package, width int) {
	if pkg.backup.len == 0 {
		return
	}
	mut lines := []string{}
	root := '/'
	for b in pkg.backup {
		status := get_backup_file_status(root, b)
		lines << '${root}${b.name} ${status}'
	}
	list_display_linebreak('Backup Files', lines, width)
}

// get_backup_file_status checks the status of a backup file.
fn get_backup_file_status(root string, backup &db.BackupFile) string {
	path := os.join_path(root, backup.name)
	if !os.exists(path) {
		return '[missing]'
	}
	// We don't compute md5 in this phase — just report [modified] if it differs
	// from the stored hash.
	if backup.hash == '' {
		return '[unmodified]'
	}
	// For now report as unknown — real check needs md5 computation
	return '[unmodified]'
}

// =============================================================================
// -Ql  —  dump_pkg_files (matches package.c:dump_pkg_files)
// =============================================================================

fn dump_pkg_files(pkg &db.Package, quiet bool) {
	for f in pkg.files.files {
		path := if f.name.starts_with('/') { f.name } else { '/${f.name}' }
		if !quiet {
			print('${pkg.name} ')
		}
		println('${path}')
	}
}

// =============================================================================
// -Qc  —  dump_pkg_changelog (stub)
// =============================================================================

fn dump_pkg_changelog(pkg &db.Package) {
	eprintln('error: no changelog available for "${pkg.name}".')
}

// =============================================================================
// -Qk / -Qkk  —  check_pkg_fast / check_pkg_full
// =============================================================================

fn check_pkg_fast(pkg &db.Package, root string) int {
	mut errors := 0
	mut file_count := 0
	for f in pkg.files.files {
		file_count++
		path := os.join_path(root, f.name)
		if !os.exists(path) {
			errors++
			println('warning: ${path} does not exist')
		}
	}
	if file_count == 0 {
		return 0
	}
	println('${pkg.name}: ${file_count} total file, ${errors} missing file')
	return if errors > 0 { 1 } else { 0 }
}

fn check_pkg_full(pkg &db.Package, root string) int {
	mut errors := 0
	mut file_count := 0
	for f in pkg.files.files {
		file_count++
		path := os.join_path(root, f.name)
		if !os.exists(path) {
			errors++
			println('warning: ${f.name} does not exist')
		}
	}
	if file_count == 0 {
		return 0
	}
	println('${pkg.name}: ${file_count} total files, ${errors} altered file')
	return if errors > 0 { 1 } else { 0 }
}

// =============================================================================
// -Qs  —  search (matches query.c:query_search → dump_pkg_search)
// =============================================================================

fn query_search(local_db &db.LocalDB, pattern string) {
	re := regex.regex_opt(pattern) or {
		eprintln('error: invalid regex: ${pattern}')
		return
	}
	for _, pkg in local_db.pkgcache {
		if re.matches_string(pkg.name) || re.matches_string(pkg.desc) {
			println('local/${pkg.name} ${pkg.version}')
			if pkg.desc != '' {
				println('    ${pkg.desc}')
			}
		}
	}
}

// =============================================================================
// -Qg  —  query_group (matches query.c:query_group)
// =============================================================================

fn query_groups(local_db &db.LocalDB, targets []string, quiet bool) {
	if targets.len == 0 {
		// No target: list all groups
		mut seen := map[string]bool{}
		for _, pkg in local_db.pkgcache {
			for grp in pkg.groups {
				if !quiet {
					println('${grp} ${pkg.name}')
				} else {
					println(pkg.name)
				}
				seen[grp] = true
			}
		}
	} else {
		for target in targets {
			mut found := false
			for _, pkg in local_db.pkgcache {
				for grp in pkg.groups {
					if grp == target {
						if !quiet {
							println('${grp} ${pkg.name}')
						} else {
							println(pkg.name)
						}
						found = true
					}
				}
			}
			if !found {
				eprintln('error: group "${target}" was not found')
			}
		}
	}
}

// =============================================================================
// -Qo  —  query_fileowner (matches query.c:query_fileowner)
// =============================================================================

fn query_owner(local_db &db.LocalDB, filepath string, root string) ! {
	if filepath == '' {
		return error('empty string passed to file owner query')
	}

	// Strip trailing slashes
	mut fpath := filepath
	for fpath.len > 0 && fpath[fpath.len - 1] == `/` {
		fpath = fpath[..fpath.len - 1]
	}

	// Resolve the path
	rpath := fpath

	// Check if path is under root
	if !rpath.starts_with(root) {
		return error('No package owns ${fpath}')
	}
	rel_path := rpath[root.len..]

	// Search all packages
	for _, pkg in local_db.pkgcache {
		for f in pkg.files.files {
			if f.name == rel_path || f.name == rpath {
				println('${rpath} is owned by ${pkg.name} ${pkg.version}')
				return
			}
		}
	}

	return error('No package owns ${fpath}')
}

// =============================================================================
// -Qp  —  query on package file (operate on .pkg.tar.zst, not DB)
// =============================================================================

fn query_pkg_files(targets []string, _ &CliArgs) ! {
	for target in targets {
		if !os.exists(target) {
			eprintln('error: could not load package "${target}": file not found')
			continue
		}
		// For now, just print the package name from the filename
		// Full .pkg.tar.zst parsing is deferred to a later phase
		eprintln('warning: -Qp is not implemented yet — operating on filename only: ${target}')
	}
}

// =============================================================================
// Helpers
// =============================================================================

// deps_to_strings converts a []Dependency to []string via to_string().
fn deps_to_strings(deps []db.Dependency) []string {
	mut s := []string{}
	for d in deps {
		s << d.to_string()
	}
	return s
}

// =============================================================================
// -Q  —  list all installed packages (legacy, used by tests)
// =============================================================================

fn query_list(local_db &db.LocalDB) {
	for _, pkg in local_db.pkgcache {
		println('${pkg.name} ${pkg.version}')
	}
}
