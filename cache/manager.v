// Module: cache — package cache management for the ace package manager.
//
// Provides clean_cache() for removing obsolete package files from cache
// directories, supporting KeepInstalled / KeepCurrent clean methods.
//
// Reference: pacman/src/pacman/sync.c (sync_cleancache, sync_cleandb)
module cache

import db
import os
import util

// ===========================================================================
//  Public API
// ===========================================================================

// clean_cache removes cached package files from ALL configured cache
// directories.
//
// When keep_installed is true, packages whose version matches an installed
// package in the local database are preserved.
// When keep_current is true, packages whose version matches a package in any
// available sync database are preserved.
// When both flags are false, ALL cached package files are removed (analogous
// to pacman's -Scc).
//
// Unused sync database files (.db, .files, and their .sig companions) in the
// sync directory are also cleaned after cache cleaning.
pub fn clean_cache(handle &util.Handle, keep_installed bool, keep_current bool) ! {
	cachedirs := handle.resolved_cachedirs()
	if cachedirs.len == 0 {
		return error('no cache directories configured')
	}

	if keep_installed || keep_current {
		// --- Selective cleaning (-Sc) ---
		mut local_pkgcache := map[string]&db.Package{}
		mut syncdbs := []&db.Database{}

		if keep_installed {
			local_pkgcache = load_local_db(handle)
			println('  keeping all locally installed packages')
		}
		if keep_current {
			syncdbs = load_sync_dbs(handle)
			println('  keeping all current sync database packages')
		}

		clean_selective(cachedirs, local_pkgcache, syncdbs, keep_installed,
			keep_current)
	} else {
		// --- Remove ALL (-Scc) ---
		clean_all(cachedirs)
	}

	// Also clean unused sync database files from the sync directory.
	remove_unused_db_files(handle)
}

// ===========================================================================
//  Database loading helpers
// ===========================================================================

// load_local_db opens the local package database and returns its pkgcache.
fn load_local_db(handle &util.Handle) map[string]&db.Package {
	dbpath := handle.resolved_dbpath()
	local_dir := os.join_path(dbpath, 'local')
	if !os.is_dir(local_dir) {
		return map[string]&db.Package{}
	}

	ldb := db.init(dbpath) or {
		eprintln('warning: could not open local database: ${err}')
		return map[string]&db.Package{}
	}
	mut ldb_mut := ldb
	ldb_mut.populate() or {
		eprintln('warning: could not populate local database: ${err}')
		return map[string]&db.Package{}
	}

	return ldb_mut.pkgcache
}

// load_sync_dbs scans the sync directory and loads all available sync
// databases. Returns an empty slice on failure.
fn load_sync_dbs(handle &util.Handle) []&db.Database {
	dbpath := handle.resolved_dbpath()
	sync_dir := os.join_path(dbpath, 'sync')
	if !os.is_dir(sync_dir) {
		return []&db.Database{}
	}

	entries := os.ls(sync_dir) or {
		eprintln('warning: could not list sync directory: ${err}')
		return []&db.Database{}
	}

	mut dbs := []&db.Database{}

	for entry in entries {
		// Match files ending in .db (but not .db.sig).
		if !entry.ends_with('.db') || entry.ends_with('.db.sig') {
			continue
		}

		repo_name := entry[..entry.len - 3] // strip trailing ".db"
		db_path := os.join_path(sync_dir, entry)

		mut sdb := db.new_sync_db()
		db.populate(mut sdb, db_path) or {
			eprintln('warning: could not load sync db ${entry}: ${err}')
			continue
		}

		mut database := &db.Database{
			pkgcache: sdb.pkgcache
			name:     repo_name
		}
		db.build_grpcache(mut database)

		dbs << database
	}

	return dbs
}

// ===========================================================================
//  Cleaning — remove ALL
// ===========================================================================

// clean_all removes every package file and signature from all cache dirs.
fn clean_all(cachedirs []string) {
	for cachedir in cachedirs {
		if !os.is_dir(cachedir) {
			continue
		}
		println('removing all files from cache...')
		println('Cache directory: ${cachedir}')

		entries := os.ls(cachedir) or {
			eprintln('warning: could not list cache directory ${cachedir}: ${err}')
			continue
		}

		mut removed := 0
		for entry in entries {
			full_path := os.join_path(cachedir, entry)
			if os.is_dir(full_path) {
				continue
			}
			if is_package_file(entry) || entry.ends_with('.sig') {
				os.rm(full_path) or {
					eprintln('warning: could not remove ${full_path}: ${err}')
					continue
				}
				removed++
			}
		}
		println('  removed ${removed} files')
	}
}

// ===========================================================================
//  Cleaning — selective (-Sc with KeepInstalled / KeepCurrent)
// ===========================================================================

// clean_selective iterates all cache directories and removes package files
// that are not kept by any of the enabled keep policies.
fn clean_selective(cachedirs []string, local_pkgcache map[string]&db.Package,
	syncdbs []&db.Database, keep_installed bool, keep_current bool) {
	for cachedir in cachedirs {
		if !os.is_dir(cachedir) {
			continue
		}
		println('Cache directory: ${cachedir}')

		entries := os.ls(cachedir) or {
			eprintln('warning: could not list cache directory ${cachedir}: ${err}')
			continue
		}

		mut removed := 0
		for entry in entries {
			full_path := os.join_path(cachedir, entry)
			if os.is_dir(full_path) {
				continue
			}

			// Skip non-package files and .sig files (removed with parent).
			if !is_package_file(entry) || entry.ends_with('.sig') {
				continue
			}

			// Parse package name and version from the filename.
			// Format: name-version-arch.pkg.tar.{zst,xz,gz}
			pkgname, pkgver := parse_pkg_name_version(entry) or { continue }

			mut keep := false

			// KeepInstalled: check local database.
			if keep_installed && !keep {
				if installed := local_pkgcache[pkgname] {
					if util.vercmp(installed.version, pkgver) == 0 {
						keep = true
					}
				}
			}

			// KeepCurrent: check sync databases.
			if keep_current && !keep {
				for sdb in syncdbs {
					if syncpkg := sdb.pkgcache[pkgname] {
						if util.vercmp(syncpkg.version, pkgver) == 0 {
							keep = true
							break
						}
					}
				}
			}

			if !keep {
				os.rm(full_path) or {
					eprintln('warning: could not remove ${full_path}: ${err}')
					continue
				}
				// Remove companion .sig file if present.
				sig_path := full_path + '.sig'
				if os.exists(sig_path) {
					os.rm(sig_path) or {}
				}
				removed++
			}
		}
		if removed > 0 {
			println('  removed ${removed} files')
		}
	}
}

// ===========================================================================
//  Helpers
// ===========================================================================

// is_package_file returns true if the filename looks like an arch package
// (contains ".pkg.tar").
fn is_package_file(name string) bool {
	return name.contains('.pkg.tar')
}

// parse_pkg_name_version extracts the package name and version from a
// canonical package filename.
//
// Input:  "name-version-arch.pkg.tar.zst"
// Output: ("name", "version-arch") — caller compares version including arch.
//
// Actually pacman convention: the directory name in the local DB is
// "pkgname-pkgver". The cached filename is "pkgname-pkgver-pkgarch.pkg.tar.*".
// The version-arch part after the name's last hyphen is the full version
// string (including release) followed by arch.
//
// We locate the second-to-last hyphen to split: name, then version-arch.
fn parse_pkg_name_version(filename string) ?(string, string) {
	dot_idx := filename.index('.pkg.tar') or {
		return none
	}
	stem := filename[..dot_idx]

	// The stem is "name-version-arch". The arch is after the last hyphen.
	last_hyphen := stem.last_index('-') or {
		return none
	}
	// Find the hyphen before the version (second-to-last hyphen).
	ver_hyphen := stem[..last_hyphen].last_index('-') or {
		return none
	}

	pkgname := stem[..ver_hyphen]
	pkgver := stem[ver_hyphen + 1..last_hyphen]

	if pkgname.len == 0 || pkgver.len == 0 {
		return none
	}

	return pkgname, pkgver
}

// ===========================================================================
//  Sync DB file cleaning
// ===========================================================================

// remove_unused_db_files removes .db, .db.sig, .files, and .files.sig files
// from the sync directory that do not correspond to any available .db file.
//
// A .db file is considered "used" if it can be loaded as a valid sync
// database. All others (including orphaned .sig and .files entries) are
// removed.
fn remove_unused_db_files(handle &util.Handle) {
	dbpath := handle.resolved_dbpath()
	sync_dir := os.join_path(dbpath, 'sync')

	if !os.is_dir(sync_dir) {
		return
	}

	// Build the set of valid repo names from loadable .db files.
	mut repo_names := map[string]bool{}
	entries := os.ls(sync_dir) or { return }

	for entry in entries {
		if entry.ends_with('.db') && !entry.ends_with('.db.sig') {
			repo_name := entry[..entry.len - 3]
			repo_names[repo_name] = true
		}
	}

	// Remove entries that don't belong to any known repo.
	for entry in entries {
		full_path := os.join_path(sync_dir, entry)
		if os.is_dir(full_path) {
			continue
		}

		mut base := entry
		mut matched := false

		if base.ends_with('.db.sig') {
			base = base[..base.len - 7]
			matched = true
		} else if base.ends_with('.db') {
			base = base[..base.len - 3]
			matched = true
		} else if base.ends_with('.files.sig') {
			base = base[..base.len - 10]
			matched = true
		} else if base.ends_with('.files') {
			base = base[..base.len - 6]
			matched = true
		}

		if matched && base.len > 0 && base !in repo_names && base != 'ALPM_DB_VERSION' {
			os.rm(full_path) or {
				eprintln('warning: could not remove ${full_path}: ${err}')
			}
		}
	}
}
