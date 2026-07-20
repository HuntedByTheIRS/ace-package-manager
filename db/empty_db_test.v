// Edge-case tests: empty databases, missing files, and corrupted states.
module db

import os

// ---------------------------------------------------------------------------
// Empty local database
// ---------------------------------------------------------------------------

fn test_local_db_empty_init() {
	tmpdir := os.join_path(os.temp_dir(), 'ace_test_empty_init')
	defer { os.rmdir_all(tmpdir) or {} }

	os.mkdir_all(os.join_path(tmpdir, 'local'), os.MkdirParams{}) or { panic('mkdir: ${err}') }
	os.write_file(os.join_path(tmpdir, 'local', 'ALPM_DB_VERSION'), '9\n') or { panic('write: ${err}') }

	mut ldb := init(tmpdir) or { assert false; return }
	ldb.populate() or { assert false; return }

	assert ldb.pkgcache.len == 0, 'empty DB should have 0 packages, got ${ldb.pkgcache.len}'
	assert ldb.get_pkgcache().len == 0

	// get_pkg on any name returns none
	if _ := ldb.get_pkg('anything') {
		assert false, 'get_pkg on empty DB should return none'
	}
}

fn test_local_db_empty_version_file() {
	tmpdir := os.join_path(os.temp_dir(), 'ace_test_empty_version')
	defer { os.rmdir_all(tmpdir) or {} }
	os.mkdir_all(os.join_path(tmpdir, 'local'), os.MkdirParams{}) or { panic('mkdir: ${err}') }
	os.write_file(os.join_path(tmpdir, 'local', 'ALPM_DB_VERSION'), '\n') or { panic('write: ${err}') }

	// Should error — empty version line
	init(tmpdir) or { return }
	assert false, 'expected error for empty ALPM_DB_VERSION'
}

fn test_local_db_missing_version_file() {
	tmpdir := os.join_path(os.temp_dir(), 'ace_test_missing_version')
	defer { os.rmdir_all(tmpdir) or {} }
	os.mkdir_all(os.join_path(tmpdir, 'local'), os.MkdirParams{}) or { panic('mkdir: ${err}') }
	// No ALPM_DB_VERSION file

	init(tmpdir) or { return }
	assert false, 'expected error for missing ALPM_DB_VERSION'
}

// ---------------------------------------------------------------------------
// Missing local database directory
// ---------------------------------------------------------------------------

fn test_local_db_missing_dir() {
	absent := os.join_path(os.temp_dir(), 'ace_test_missing_dir', 'local')
	init(absent) or { return }
	assert false, 'expected error for missing local directory'
}

// ---------------------------------------------------------------------------
// Sync database edge cases
// ---------------------------------------------------------------------------

fn test_sync_db_empty_string() {
	mut sdb := new_sync_db()
	// populate with empty path — should error
	populate(mut sdb, '') or { return }
	assert false, 'expected error for empty path'
}

fn test_sync_db_not_found() {
	mut sdb := new_sync_db()
	populate(mut sdb, '/nonexistent/db.db') or { return }
	assert false, 'expected error for nonexistent path'
}

fn test_sync_db_get_pkg_on_empty() {
	sdb := new_sync_db()
	if _ := get_pkg(&sdb, 'anything') {
		assert false, 'get_pkg on empty SyncDB should return none'
	}
}

fn test_sync_db_get_pkgcache_on_empty() {
	sdb := new_sync_db()
	pkgs := get_pkgcache(&sdb)
	assert pkgs.len == 0
}

// ---------------------------------------------------------------------------
// Package name parsing edge cases
// ---------------------------------------------------------------------------

fn test_split_name_version_no_digit() {
	// "foo-hyphen-no-digit" — the hyphen is not followed by a digit
	name, version := split_name_version('foo-bar')
	assert name == 'foo-bar'
	assert version == ''
}

fn test_split_name_version_non_standard() {
	// "name-1" — single-digit version
	name, version := split_name_version('pkg-1')
	assert name == 'pkg'
	assert version == '1'
}

fn test_split_name_version_numeric_name() {
	// "123-1.0-1" — name that is all digits
	name, version := split_name_version('123-1.0-1')
	assert name == '123'
	assert version == '1.0-1'
}

// ---------------------------------------------------------------------------
// Build_grpcache edge cases
// ---------------------------------------------------------------------------

fn test_build_grpcache_empty_db() {
	mut database := Database{
		pkgcache: map[string]&Package{}
		grpcache: map[string]Group{}
	}
	build_grpcache(mut database)
	assert database.grpcache.len == 0
}

fn test_build_grpcache_no_groups() {
	pkg := &Package{
		name:      'nogroup-pkg'
		version:   '1.0'
		name_hash: compute_name_hash('nogroup-pkg')
		groups:    []string{}
	}
	mut database := Database{
		pkgcache: {
			'nogroup-pkg': pkg
		}
		grpcache: map[string]Group{}
	}
	build_grpcache(mut database)
	assert database.grpcache.len == 0
}

fn test_build_grpcache_duplicate_group_entry() {
	pkg := &Package{
		name:      'dup-pkg'
		version:   '1.0'
		name_hash: compute_name_hash('dup-pkg')
		groups:    ['base', 'base']
	}
	mut database := Database{
		pkgcache: {
			'dup-pkg': pkg
		}
		grpcache: map[string]Group{}
	}
	build_grpcache(mut database)
	assert database.grpcache.len == 1
	assert database.grpcache['base'].packages.len == 1
}
