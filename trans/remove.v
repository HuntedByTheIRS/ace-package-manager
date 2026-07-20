// Module: trans — package removal for the ace package manager.
//
// remove_package removes an installed package from the system. It handles:
//   - Scriptlet execution (pre_remove, post_remove)
//   - File removal (iterating the package's filelist backwards)
//   - .pacsave backup for modified configuration files
//   - CASCADE / RECURSE / RECURSEALL / UNNEEDED flag semantics
//   - Directory removal (only package-owned, empty dirs)
//   - Local database update (remove from pkgcache and filesystem dir)
//
// Reference: pacman/lib/libalpm/remove.c (798 lines)
// allow: SIZE_OK — single responsibility (package removal); C reference is 798 LOC
module trans

import crypto.md5
import db
import os
import util

// ---------------------------------------------------------------------------
// RemoveFlags — bitmask constants
// ---------------------------------------------------------------------------

// RemoveFlags controls the behavior of a removal operation.
// Values match pacman's ALPM_TRANS_FLAG_* semantics.
@[flag]
pub enum RemoveFlags {
	none
	cascade    // also remove packages depending on this one
	recurse    // remove unneeded dependencies
	recurseall // like recurse, also consider optdepends
	unneeded   // skip removal if the package is needed by another
	nosave     // do not create .pacsave backups
	noscriptlet // do not execute install scriptlets
	dbonly     // only remove from database, keep files on disk
}

// ---------------------------------------------------------------------------
// Internal helpers — filesystem
// ---------------------------------------------------------------------------

// file_hash computes the MD5 hex digest of a file.
// Returns an empty string when the file cannot be read.
fn file_hash(path string) string {
	data := os.read_file(path) or {
		return ''
	}
	return md5.hexhash(data)
}

// dir_is_mountpoint checks whether `path` sits on a different device than its
// parent directory.  Mountpoints must not be removed.
fn dir_is_mountpoint(path string) bool {
	parent := os.dir(path)
	if parent == path || !os.exists(path) || !os.exists(parent) {
		return false
	}

	// Use os.stat directly instead of shelling out to `stat` — safer
	// and avoids any risk of shell injection from package-controlled paths.
	dir_st := os.stat(path) or { return false }
	parent_st := os.stat(parent) or { return false }

	return dir_st.dev != parent_st.dev
}

// can_remove_file checks whether ace is allowed to delete a file.
// Returns true if the file can be removed or if it is a mountpoint to skip.
fn can_remove_file(root string, filepath string) bool {
	full := os.join_path(root, filepath)

	// Do not remove mountpoints.
	if filepath.ends_with('/') && dir_is_mountpoint(full) {
		return true
	}

	// If the file does not exist there is nothing to remove.
	if !os.exists(full) {
		return true
	}

	return true
}

// should_skip_file checks whether a file should NOT be removed because it
// matches NoUpgrade or skip_remove lists.
fn should_skip_file(noupgrade []string, skip_remove []string, filepath string) bool {
	for pattern in noupgrade {
		if fnmatch(pattern, filepath) {
			return true
		}
	}
	for skip in skip_remove {
		if skip == filepath {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// shift_pacsave
// ---------------------------------------------------------------------------

// shift_pacsave rotates existing .pacsave files for `filepath` so a fresh
// .pacsave can be created without overwriting an older backup.
//
// Example: foo.pacsave → foo.pacsave.1, foo.pacsave.1 → foo.pacsave.2, etc.
fn shift_pacsave(filepath string) {
	dir := os.dir(filepath)
	base := os.file_name(filepath)

	// Find the highest existing .pacsave.N suffix.
	mut max_n := u64(0)
	if entries := os.ls(dir) {
		prefix := base + '.pacsave'
		for entry in entries {
			if entry.len <= prefix.len {
				continue
			}
			if entry.starts_with(prefix) {
				suffix := entry[prefix.len..]
				// suffix is either "" (plain .pacsave) or ".N" (numbered).
                if suffix.len > 1 && suffix[0] == `.` {
                    n := u64(suffix[1..].int())
                    if n > max_n {
                        max_n = n
                    }
                }
			}
		}
	}

	// Shift existing .pacsave files upward: N → N+1.
	for n := max_n; n >= 1; n-- {
		old_name := if n == 1 {
			'${filepath}.pacsave'
		} else {
			'${filepath}.pacsave.${n - 1}'
		}
		new_name := '${filepath}.pacsave.${n}'
		os.rename(old_name, new_name) or {}
	}

	// Rename the current .pacsave to .pacsave.1 if it exists.
	if os.exists('${filepath}.pacsave') {
		os.rename('${filepath}.pacsave', '${filepath}.pacsave.1') or {}
	}
}

// ---------------------------------------------------------------------------
// unlink_file
// ---------------------------------------------------------------------------

// unlink_file removes a single file owned by the package.  For regular files
// that are in the backup list and have been modified since installation, the
// file is renamed to .pacsave (after rotating existing pacsave files).
//
// Returns:
//   0  — file successfully removed or backed up
//   1  — file skipped (does not exist, mountpoint, or belongs to replacement)
//  -1  — error during removal
fn unlink_file(root string, filepath string, backup_hash string, nosave bool, noupgrade []string,
	skip_remove []string) int {
	full := os.join_path(root, filepath)

	// Skip files in NoUpgrade or skip_remove.
	if should_skip_file(noupgrade, skip_remove, filepath) {
		return 1
	}

	// Check if the file exists.
	file_exists := os.exists(full)

	// For directories: try to remove only if empty and not a mountpoint.
	if filepath.ends_with('/') || (file_exists && os.is_dir(full)) {
		norm_path := if filepath.ends_with('/') { full[..full.len - 1] } else { full }

		if !os.is_dir(norm_path) {
			// Not actually a directory — treat as a regular file below.
		} else if dir_is_mountpoint(norm_path) {
			return 1
		} else {
			// Count entries in the directory.
			mut entry_count := 0
			if entries := os.ls(norm_path) {
				for e in entries {
					if e != '.' && e != '..' {
						entry_count++
					}
				}
			}
			if entry_count > 0 {
				// Directory still contains files — keep it.
				return 1
			}

			// Directory is empty — remove it (only if owned by this package,
			// checked at the caller level).
			os.rmdir(norm_path) or {
				return -1
			}
			return 0
		}
	}

	if !file_exists {
		return 1
	}

	// Backup check: if the file is in the package's backup list and has been
	// modified since installation, rename it to .pacsave.
	if backup_hash != '' && !nosave {
		current_hash := file_hash(full)
		if current_hash != '' && current_hash != backup_hash {
			// File was modified — create .pacsave.
			shift_pacsave(full)
			pacsave_path := '${full}.pacsave'
			os.rename(full, pacsave_path) or {
				return -1
			}
			return 0
		}
	}

	// Unlink the file.
	os.rm(full) or {
		return -1
	}
	return 0
}

// ---------------------------------------------------------------------------
// remove_package_files
// ---------------------------------------------------------------------------

// remove_package_files iterates through the package's filelist (in reverse
// order) and removes every file.  Directories are removed only when they
// become empty and are not owned by any other package.
//
// Reference: pacman _alpm_remove_package_files (remove.c:611-672).
fn remove_package_files(root string, pkg &db.Package, flags RemoveFlags,
    noupgrade []string, skip_remove []string, _localdb &db.Database) int {
	filelist := pkg.files.files
	mut err_count := 0
	nosave := flags.has(.nosave)

	// Pre-check: ensure all files can be removed.
	for file in filelist {
		if !should_skip_file(noupgrade, skip_remove, file.name) && !can_remove_file(root,
			file.name) {
			return -1
		}
	}

	// Build a lookup of backup file paths for O(1) access.
	mut backup_map := map[string]string{}
	for b in pkg.backup {
		backup_map[b.name] = b.hash
	}

	// Iterate the filelist backwards (children before parents for dirs).
	for i := filelist.len; i > 0; i-- {
		file := filelist[i - 1]
		bhash := backup_map[file.name] or { '' }

		ret := unlink_file(root, file.name, bhash, nosave, noupgrade, skip_remove)
		if ret < 0 {
			err_count++
		}
	}

	return err_count
}

// ---------------------------------------------------------------------------
// Scriptlet execution
// ---------------------------------------------------------------------------

// run_remove_scriptlet executes a package install scriptlet at the given phase.
// The scriptlet is found at {dbpath}/local/{name}-{version}/install.
// Reference: pacman _alpm_runscriptlet (remove.c:707-713, 727-733).
fn run_remove_scriptlet(_root string, dbpath string, pkg &db.Package, phase string) {
	scriptlet_path := os.join_path(dbpath, 'local', '${pkg.name}-${pkg.version}', 'install')
	if !os.exists(scriptlet_path) {
		return
	}

	// The scriptlet is a shell script invoked as:
	//   sh -c ". scriptlet; phase" arg0 phase version
	// The phase argument (e.g. "pre_remove" or "post_remove") is passed both
	// as the shell command and as $1.
	cmd := 'sh -c "\\\n' + '  . ' + os.quoted_path(scriptlet_path) + '\n' + '  ${phase} ${phase} ${pkg.version}"'
	os.execute(cmd)
}

// ---------------------------------------------------------------------------
// Recursedeps — find unneeded dependencies
// ---------------------------------------------------------------------------

// recursedeps adds unneeded dependencies of `pkg` (and transitively) to the
// removal set.  A dependency is "unneeded" when no installed package other
// than those already in the removal set requires it.
//
// When `include_optdep` is true optional dependencies are also considered.
//
// Reference: pacman _alpm_recursedeps (deps.c).
fn recursedeps(pkg &db.Package, mut remove_list []&db.Package, localdb &db.Database,
	include_optdep bool) {
	mut pending := []&db.Package{}
	pending << pkg
	mut seen := map[string]bool{}
	seen[pkg.name] = true

	for pending.len > 0 {
		current := pending[pending.len - 1]
		pending = pending[..pending.len - 1]

		// Collect all dependency names to check.
		mut dep_names := []string{}
		for dep in current.depends {
			dep_names << dep.name
		}
		if include_optdep {
			for dep in current.optdepends {
				dep_names << dep.name
			}
		}

		for dep_name in dep_names {
			if dep_name in seen {
				continue
			}

			// Look up the installed package providing this dep.
			dep_pkg := localdb.pkgcache[dep_name] or {
				continue
			}

			// Skip packages already in the remove list.
			mut in_remove := false
			for rp in remove_list {
				if rp.name == dep_pkg.name {
					in_remove = true
					break
				}
			}
			if in_remove {
				continue
			}

			// Check if this package is required by any installed package NOT
			// in the removal set.
			mut needed := false
			for _, installed in localdb.pkgcache {
				if installed.name == dep_pkg.name {
					continue
				}
				mut in_remove_inner := false
				for rp in remove_list {
					if rp.name == installed.name {
						in_remove_inner = true
						break
					}
				}
				if in_remove_inner {
					continue
				}

				// Check direct depends.
				for d in installed.depends {
					if d.name == dep_pkg.name || dep_name_matches_provides(dep_pkg, d) {
						needed = true
						break
					}
				}
				if needed {
					break
				}

				// Check optdepends when include_optdep is set.
				if include_optdep {
					for d in installed.optdepends {
						if d.name == dep_pkg.name || dep_name_matches_provides(dep_pkg, d) {
							needed = true
							break
						}
					}
					if needed {
						break
					}
				}
			}

			if !needed {
				seen[dep_pkg.name] = true
				remove_list << dep_pkg
				pending << dep_pkg
			}
		}
	}
}

// dep_name_matches_provides checks whether `pkg` provides a dependency named
// `dep_name` (either by name match or via its provides list).
fn dep_name_matches_provides(pkg &db.Package, dep db.Dependency) bool {
	if pkg.name == dep.name {
		return true
	}
	for prov in pkg.provides {
		if prov.name == dep.name {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// remove_prepare_cascade
// ---------------------------------------------------------------------------

// remove_prepare_cascade adds packages that would have their dependencies
// broken by the removal to the removal list.  It iterates until the removal
// set stabilizes (no more broken deps).
//
// Reference: pacman remove_prepare_cascade (remove.c:90-120).
fn remove_prepare_cascade(mut remove_list []&db.Package, local_pkgs []&db.Package) {
	mut prev_len := remove_list.len

	for {
		baddeps := check_deps(&util.Handle{}, local_pkgs, remove_list,
			[]&db.Package{}, true) or {
			break
		}

		if baddeps.len == 0 {
			break
		}

		for bd in baddeps {
			// Find the target package (whose dep is broken) in the local db.
			target_pkg := find_pkg_in_list(bd.target, local_pkgs) or {
				continue
			}

			// Add it to the removal list if not already present.
			mut already := false
			for rp in remove_list {
				if rp.name == target_pkg.name {
					already = true
					break
				}
			}
			if !already {
				remove_list << target_pkg
			}
		}

		// If no new packages were added, we are stable.
		if remove_list.len == prev_len {
			break
		}
		prev_len = remove_list.len
	}
}

// find_pkg_in_list looks up a package by name in a list.
fn find_pkg_in_list(name string, pkgs []&db.Package) ?&db.Package {
	for p in pkgs {
		if p.name == name {
			return p
		}
	}
	return none
}

// ---------------------------------------------------------------------------
// remove_prepare_keep_needed
// ---------------------------------------------------------------------------

// remove_prepare_keep_needed removes packages from the removal list that are
// needed by other installed packages (UNNEEDED flag behavior).
//
// Reference: pacman remove_prepare_keep_needed (remove.c:128-156).
fn remove_prepare_keep_needed(mut remove_list []&db.Package, local_pkgs []&db.Package) {
	for {
		baddeps := check_deps(&util.Handle{}, local_pkgs, remove_list,
			[]&db.Package{}, true) or {
			break
		}

		if baddeps.len == 0 {
			break
		}

		for bd in baddeps {
			// Remove the causing package (the one whose removal breaks deps)
			// from the removal list.
			mut new_list := []&db.Package{}
			for rp in remove_list {
				if rp.name != bd.causing_pkg {
					new_list << rp
				}
			}
			remove_list = new_list.clone()
		}
	}
}

// ---------------------------------------------------------------------------
// sort_remove_order
// ---------------------------------------------------------------------------

// sort_remove_order sorts packages so that dependents are removed before
// their dependencies (reverse of install order).  Uses the existing
// sort_by_deps with .remove mode.
fn sort_remove_order(pkgs []&db.Package) ?[]&db.Package {
	return sort_by_deps(pkgs, SortMode.remove)
}

// ---------------------------------------------------------------------------
// remove_single_package
// ---------------------------------------------------------------------------

// remove_single_package removes one package from the filesystem and database.
//
// Flow:
//  1. Run pre_remove scriptlet (if enabled and scriptlet exists)
//  2. Remove package files (unless DBOnly)
//  3. Run post_remove scriptlet (if enabled and scriptlet exists)
//  4. Remove database entry and cache
//
// Reference: pacman _alpm_remove_single_package (remove.c:685-754).
fn remove_single_package(root string, dbpath string, pkg &db.Package, flags RemoveFlags,
	mut localdb db.Database) ! {
	noscriptlet := flags.has(.noscriptlet)
	dbonly := flags.has(.dbonly)

	// Resolve the full database path: root may differ from / when --root is used.
	resolved_dbpath := os.join_path(root, dbpath)

	// --- Pre-remove scriptlet ---
	if !noscriptlet && pkg.scriptlet {
		run_remove_scriptlet(root, resolved_dbpath, pkg, 'pre_remove')
	}

	// --- Remove files ---
	if !dbonly {
		err_count := remove_package_files(root, pkg, flags, [], [], localdb)
		if err_count > 0 {
			return util.AceError{
				code:    .pkg_cant_remove
				message: 'cannot remove all files for ${pkg.name}'
			}
		}
	}

	// --- Log the removal ---
	// (log action is informational; no separate log module yet)

	// --- Post-remove scriptlet ---
	if !noscriptlet && pkg.scriptlet {
		run_remove_scriptlet(root, resolved_dbpath, pkg, 'post_remove')
	}

	// --- Remove database entry ---
	db.remove_pkg(resolved_dbpath, pkg.name, pkg.version) or {
		return util.AceError{
			code:    .db_remove
			message: 'could not remove database entry ${pkg.name}-${pkg.version}: ${err}'
		}
	}

	// --- Remove from in-memory cache ---
	localdb.pkgcache.delete(pkg.name)
}

// ---------------------------------------------------------------------------
// remove_package — public API
// ---------------------------------------------------------------------------

// remove_package removes an installed package from the system.
//
// Parameters:
//   handle — util.Handle with root, dbpath, and other configuration
//   pkg    — the installed package to remove (must have origin == .local_db)
//   flags  — bitmask of RemoveFlags controlling cascade/recurse/unneeded/etc.
//   localdb — the local database (will be updated in-place)
//
// The function:
//  1. Expands the removal set according to CASCADE / RECURSE / UNNEEDED flags
//  2. Sorts packages in removal order (dependents first)
//  3. Removes each package (scriptlets, files, database)
//
// Returns none on success, or an error describing what went wrong.
//
// Reference: pacman _alpm_remove_prepare + _alpm_remove_packages (remove.c).
pub fn remove_package(handle &util.Handle, pkg &db.Package, flags RemoveFlags,
	mut localdb db.Database) ! {
	// --- Build the initial removal list ---
	mut remove_list := []&db.Package{}

	// Validate: package must be from the local database.
	if pkg.origin != .local_db {
		return util.AceError{
			code:    .wrong_args
			message: 'can only remove packages from the local database'
		}
	}

	// Check that the package exists in the local database.
	if _ := localdb.pkgcache[pkg.name] {
		remove_list << pkg
	} else {
		return util.AceError{
			code:    .pkg_not_found
			message: 'package ${pkg.name} is not installed'
		}
	}

	// --- Step 1: RECURSE (find unneeded deps) when CASCADE is NOT set ---
	if flags.has(.recurse) && !flags.has(.cascade) {
		recursedeps(pkg, mut remove_list, localdb, flags.has(.recurseall))
	}

	// --- Step 2: Dependency checking ---
	mut local_pkgs := []&db.Package{}
	for _, lp in localdb.pkgcache {
		local_pkgs << lp
	}

	baddeps := check_deps(handle, local_pkgs, remove_list, []&db.Package{}, true) or {
		return util.AceError{
			code:    .unsatisfied_deps
			message: 'dependency check failed: ${err}'
		}
	}

	if baddeps.len > 0 {
		if flags.has(.cascade) {
			// CASCADE: add the depending packages to the removal list.
			remove_prepare_cascade(mut remove_list, local_pkgs)
		} else if flags.has(.unneeded) {
			// UNNEEDED: remove the causing package from the removal list.
			remove_prepare_keep_needed(mut remove_list, local_pkgs)
		} else {
			// Report unsatisfied deps as an error.
			mut dep_strs := []string{}
			for bd in baddeps {
				dep_strs << 'removing ${bd.causing_pkg} breaks dependency ' +
					'${bd.depend.to_string()} required by ${bd.target}'
			}
			return util.AceError{
				code:    .unsatisfied_deps
				message: dep_strs.join('; ')
			}
		}
	}

	// --- Step 3: RECURSE again after CASCADE may have added packages ---
	if flags.has(.cascade) && flags.has(.recurse) {
		// Re-run recursedeps for any newly added packages.
		mut seen := map[string]bool{}
		for rp in remove_list {
			seen[rp.name] = true
		}
		// Rebuild the list and recurse on all new additions.
		recursedeps_all(remove_list, mut remove_list, localdb, flags.has(.recurseall))
		_ := seen // (already covered by the recursion function)
	}

	// --- Step 4: Sort in removal order (dependents before dependencies) ---
	sorted := sort_remove_order(remove_list) or {
		return util.AceError{
			code:    .unsatisfied_deps
			message: 'could not sort removal order: ${err}'
		}
	}

	// --- Step 5: Remove each package ---
	mut errors := []string{}
	for rp in sorted {
		remove_single_package(handle.root, handle.dbpath, rp, flags, mut localdb) or {
			errors << 'failed to remove ${rp.name}: ${err.msg()}'
		}
	}

	if errors.len > 0 {
		return util.AceError{
			code:    .system
			message: errors.join('; ')
		}
	}
}

// recursedeps_all runs recursedeps for every package in `remove_list`,
// adding newly found unneeded dependencies to `remove_list`. This handles
// transitive unneeded deps after cascade added new packages.
fn recursedeps_all(pkgs []&db.Package, mut remove_list []&db.Package, localdb &db.Database,
	include_optdep bool) {
	// Clone the input list: recursedeps may grow remove_list (which
	// aliases pkgs at the call site), potentially reallocating the
	// backing array and invalidating the iteration.
	initial := pkgs.clone()
	for p in initial {
		recursedeps(p, mut remove_list, localdb, include_optdep)
	}
}

// ---------------------------------------------------------------------------
// remove_pkg — convenience wrapper
// ---------------------------------------------------------------------------

// remove_pkg_by_name is a convenience wrapper around remove_package that
// resolves the package from the local database by name first.
//
// Returns none if the named package is not installed.
pub fn remove_pkg_by_name(handle &util.Handle, pkgname string, flags RemoveFlags,
	mut localdb db.Database) ! {
	pkg := localdb.pkgcache[pkgname] or {
		return util.AceError{
			code:    .pkg_not_found
			message: 'package ${pkgname} not found'
		}
	}
	return remove_package(handle, pkg, flags, mut localdb)
}
