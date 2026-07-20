module trans

import db
import os
import util

// ---------------------------------------------------------------------------
// Helper: make a minimal Package for testing
// ---------------------------------------------------------------------------

fn make_pkg(name string) &db.Package {
	return &db.Package{
		name:      name
		name_hash: db.compute_name_hash(name)
		origin:    .sync_db
	}
}

fn make_pkg_with(name string, deps ...db.Dependency) &db.Package {
	mut pkg := make_pkg(name)
	for d in deps {
		// In test helpers we accept Dependency values to set into provides/conflicts.
	}
	return pkg
}

fn dep(name string) db.Dependency {
	return db.Dependency{
		name:      name
		name_hash: db.compute_name_hash(name)
	}
}

fn dep_with_hash(name string) db.Dependency {
	return dep(name)
}

// ---------------------------------------------------------------------------
// check_inner_conflicts
// ---------------------------------------------------------------------------

fn test_inner_conflicts_empty_targets() {
	conflicts := check_inner_conflicts([])
	assert conflicts.len == 0
}

fn test_inner_conflicts_single_target() {
	targets := [make_pkg('glibc')]
	conflicts := check_inner_conflicts(targets)
	assert conflicts.len == 0
}

fn test_inner_conflicts_no_conflict() {
	mut a := make_pkg('pkg-a')
	a.conflicts = [dep('pkg-c')]

	mut b := make_pkg('pkg-b')
	b.conflicts = [dep('pkg-d')]

	targets := [a, b]
	conflicts := check_inner_conflicts(targets)
	assert conflicts.len == 0
}

fn test_inner_conflicts_direct() {
	mut a := make_pkg('pkg-a')
	a.conflicts = [dep('pkg-b')]

	mut b := make_pkg('pkg-b')

	targets := [a, b]
	conflicts := check_inner_conflicts(targets)
	assert conflicts.len == 1, 'expected 1 conflict, got ${conflicts.len}'

	c := conflicts[0]
	assert c.package1 == 'pkg-a'
	assert c.package2 == 'pkg-b'
	assert c.reason.name == 'pkg-b'
}

fn test_inner_conflicts_bidirectional() {
	mut a := make_pkg('pkg-a')
	a.conflicts = [dep('pkg-b')]

	mut b := make_pkg('pkg-b')
	b.conflicts = [dep('pkg-a')]

	targets := [a, b]
	conflicts := check_inner_conflicts(targets)
	assert conflicts.len == 2

	assert conflicts[0].package1 == 'pkg-a'
	assert conflicts[0].package2 == 'pkg-b'
	assert conflicts[1].package1 == 'pkg-b'
	assert conflicts[1].package2 == 'pkg-a'
}

fn test_inner_conflicts_via_provides() {
	mut a := make_pkg('pkg-a')
	a.conflicts = [dep('virtual-foo')]

	mut b := make_pkg('pkg-b')
	b.provides = [dep('virtual-foo')]

	targets := [a, b]
	conflicts := check_inner_conflicts(targets)
	assert conflicts.len == 1, 'expected 1 conflict, got ${conflicts.len}'

	c := conflicts[0]
	assert c.package1 == 'pkg-a'
	assert c.package2 == 'pkg-b'
	assert c.reason.name == 'virtual-foo'
}

fn test_inner_conflicts_provider_conflict() {
	mut a := make_pkg('pkg-a')
	a.provides = [dep('virtual-bar')]

	mut b := make_pkg('pkg-b')
	b.provides = [dep('virtual-bar')]

	targets := [a, b]
	conflicts := check_inner_conflicts(targets)
	assert conflicts.len == 1, 'expected 1 provider conflict, got ${conflicts.len}'

	c := conflicts[0]
	assert c.package1 == 'pkg-a'
	assert c.package2 == 'pkg-b'
	assert c.reason.name == 'virtual-bar'
}

fn test_inner_conflicts_three_way() {
	mut a := make_pkg('pkg-a')
	a.conflicts = [dep('pkg-b')]

	mut b := make_pkg('pkg-b')
	b.conflicts = [dep('pkg-c')]

	mut c := make_pkg('pkg-c')
	c.conflicts = [dep('pkg-a')]

	targets := [a, b, c]
	conflicts := check_inner_conflicts(targets)
	// a-b from a side, b-c from b side, c-a from c side = 3
	assert conflicts.len == 3
}

fn test_inner_conflicts_multiple_conflicts_per_pkg() {
	mut a := make_pkg('pkg-a')
	a.conflicts = [dep('pkg-b'), dep('pkg-c')]

	mut b := make_pkg('pkg-b')

	mut c := make_pkg('pkg-c')

	targets := [a, b, c]
	conflicts := check_inner_conflicts(targets)
	assert conflicts.len == 2

	mut names := map[string]int{}
	for cf in conflicts {
		assert cf.package1 == 'pkg-a'
		names[cf.package2]++
	}
	assert names['pkg-b'] == 1
	assert names['pkg-c'] == 1
}

// ---------------------------------------------------------------------------
// check_outer_conflicts
// ---------------------------------------------------------------------------

fn test_outer_conflicts_empty_targets() {
	mut localdb := db.Database{}
	localdb.pkgcache['glibc'] = make_pkg('glibc')

	conflicts := check_outer_conflicts([], &localdb)
	assert conflicts.len == 0
}

fn test_outer_conflicts_no_conflict() {
	mut t := make_pkg('pkg-a')

	mut localdb := db.Database{}
	localdb.pkgcache['glibc'] = make_pkg('glibc')

	conflicts := check_outer_conflicts([t], &localdb)
	assert conflicts.len == 0
}

fn test_outer_conflicts_target_conflicts_installed() {
	mut t := make_pkg('pkg-a')
	t.conflicts = [dep('glibc')]

	mut localdb := db.Database{}
	localdb.pkgcache['glibc'] = make_pkg('glibc')

	conflicts := check_outer_conflicts([t], &localdb)
	assert conflicts.len == 1, 'expected 1 conflict, got ${conflicts.len}'

	c := conflicts[0]
	assert c.package1 == 'pkg-a'
	assert c.package2 == 'glibc'
	assert c.reason.name == 'glibc'
}

fn test_outer_conflicts_installed_conflicts_target() {
	mut t := make_pkg('pkg-a')

	mut installed := make_pkg('glibc')
	installed.conflicts = [dep('pkg-a')]

	mut localdb := db.Database{}
	localdb.pkgcache['glibc'] = installed

	conflicts := check_outer_conflicts([t], &localdb)
	assert conflicts.len == 1, 'expected 1 conflict, got ${conflicts.len}'

	c := conflicts[0]
	assert c.package1 == 'glibc'
	assert c.package2 == 'pkg-a'
	assert c.reason.name == 'pkg-a'
}

fn test_outer_conflicts_via_installed_provides() {
	mut t := make_pkg('pkg-a')
	t.conflicts = [dep('virtual-foo')]

	mut installed := make_pkg('glibc')
	installed.provides = [dep('virtual-foo')]

	mut localdb := db.Database{}
	localdb.pkgcache['glibc'] = installed

	conflicts := check_outer_conflicts([t], &localdb)
	assert conflicts.len == 1, 'expected 1 conflict, got ${conflicts.len}'

	c := conflicts[0]
	assert c.package1 == 'pkg-a'
	assert c.package2 == 'glibc'
	assert c.reason.name == 'virtual-foo'
}

fn test_outer_conflicts_skip_same_name_upgrade() {
	mut t := make_pkg('glibc')
	t.conflicts = [dep('glibc')] // would be unusual but we skip it

	mut localdb := db.Database{}
	localdb.pkgcache['glibc'] = make_pkg('glibc')

	conflicts := check_outer_conflicts([t], &localdb)
	assert conflicts.len == 0, 'expected 0 conflicts for same-name upgrade, got ${conflicts.len}'
}

fn test_outer_conflicts_multiple_installed() {
	mut t := make_pkg('pkg-a')
	t.conflicts = [dep('pkg-b'), dep('pkg-c')]

	mut localdb := db.Database{}
	localdb.pkgcache['pkg-b'] = make_pkg('pkg-b')
	localdb.pkgcache['pkg-c'] = make_pkg('pkg-c')
	localdb.pkgcache['pkg-d'] = make_pkg('pkg-d')

	conflicts := check_outer_conflicts([t], &localdb)
	assert conflicts.len == 2

	mut names := map[string]int{}
	for cf in conflicts {
		assert cf.package1 == 'pkg-a'
		names[cf.package2]++
	}
	assert names['pkg-b'] == 1
	assert names['pkg-c'] == 1
}

// ---------------------------------------------------------------------------
// resolve_conflicts
// ---------------------------------------------------------------------------

fn test_resolve_conflicts_empty() {
	resolved := resolve_conflicts([], [], db.Database{}) or {
		assert false, 'expected some resolution for empty list'
		return
	}
	assert resolved.len == 0
}

fn test_resolve_conflicts_replaces_resolves() {
	mut target_b := make_pkg('pkg-b')
	target_b.replaces = [dep('pkg-a')]

	conflict := db.Conflict{
		package1: 'pkg-b'
		package2: 'pkg-a'
		reason:   &db.Dependency{name: 'pkg-a', name_hash: db.compute_name_hash('pkg-a')}
	}

	resolved := resolve_conflicts([conflict], [target_b], db.Database{}) or {
		assert false, 'expected resolution for replaces-match'
		return
	}
	assert resolved.len == 1
	assert resolved[0].remove_pkg == 'pkg-a'
	assert resolved[0].package1 == 'pkg-b'
	assert resolved[0].package2 == 'pkg-a'
}

fn test_resolve_conflicts_reverse_replaces() {
	mut target_a := make_pkg('pkg-a')
	target_a.replaces = [dep('pkg-b')]

	// Conflict reports package1=installed, package2=target
	conflict := db.Conflict{
		package1: 'pkg-b'
		package2: 'pkg-a'
		reason:   &db.Dependency{name: 'pkg-b', name_hash: db.compute_name_hash('pkg-b')}
	}

	resolved := resolve_conflicts([conflict], [target_a], db.Database{}) or {
		assert false, 'expected resolution for reverse replaces-match'
		return
	}
	assert resolved.len == 1
	// Since pkg-a replaces pkg-b, pkg-b should be removed
	assert resolved[0].remove_pkg == 'pkg-b'
}

fn test_resolve_conflicts_not_resolvable() {
	mut target_a := make_pkg('pkg-a')
	// target_a does NOT replace pkg-b

	conflict := db.Conflict{
		package1: 'pkg-a'
		package2: 'pkg-b'
		reason:   &db.Dependency{name: 'pkg-b', name_hash: db.compute_name_hash('pkg-b')}
	}

	// Should return none (unresolvable)
	if _ := resolve_conflicts([conflict], [target_a], db.Database{}) {
		assert false, 'expected none for unresolvable conflict'
	}
}

fn test_resolve_conflicts_provider_conflict_resolvable() {
	mut a := make_pkg('pkg-a')
	a.provides = [dep('virtual-baz')]
	a.replaces = [dep('pkg-b')]

	mut b := make_pkg('pkg-b')
	b.provides = [dep('virtual-baz')]

	// Provider conflict: both provide virtual-baz
	conflict := db.Conflict{
		package1: 'pkg-a'
		package2: 'pkg-b'
		reason:   &db.Dependency{name: 'virtual-baz', name_hash: db.compute_name_hash('virtual-baz')}
	}

	resolved := resolve_conflicts([conflict], [a, b], db.Database{}) or {
		assert false, 'expected resolution for provider conflict with replaces'
		return
	}
	assert resolved.len == 1
	assert resolved[0].remove_pkg == 'pkg-b'
}

fn test_resolve_conflicts_provider_conflict_not_resolvable() {
	mut a := make_pkg('pkg-a')
	a.provides = [dep('virtual-baz')]

	mut b := make_pkg('pkg-b')
	b.provides = [dep('virtual-baz')]

	conflict := db.Conflict{
		package1: 'pkg-a'
		package2: 'pkg-b'
		reason:   &db.Dependency{name: 'virtual-baz', name_hash: db.compute_name_hash('virtual-baz')}
	}

	// Neither replaces the other → should return none
	if _ := resolve_conflicts([conflict], [a, b], db.Database{}) {
		assert false, 'expected none for unresolvable provider conflict'
	}
}

fn test_resolve_conflicts_mixed_resolvable_and_not() {
	mut a := make_pkg('pkg-a')
	a.replaces = [dep('pkg-b')]

	mut c := make_pkg('pkg-c')
	// c does NOT replace pkg-d

	conflicts := [
		db.Conflict{
			package1: 'pkg-a'
			package2: 'pkg-b'
			reason: &db.Dependency{name: 'pkg-b', name_hash: db.compute_name_hash('pkg-b')}
		},
		db.Conflict{
			package1: 'pkg-c'
			package2: 'pkg-d'
			reason: &db.Dependency{name: 'pkg-d', name_hash: db.compute_name_hash('pkg-d')}
		},
	]

	// Should return none because pkg-c vs pkg-d is unresolvable
	if _ := resolve_conflicts(conflicts, [a, c], db.Database{}) {
		assert false, 'expected none when one conflict is unresolvable'
	}
}

fn test_resolve_conflicts_multiple_resolvable() {
	mut a := make_pkg('pkg-a')
	a.replaces = [dep('pkg-b')]

	mut c := make_pkg('pkg-c')
	c.replaces = [dep('pkg-d')]

	conflicts := [
		db.Conflict{
			package1: 'pkg-a'
			package2: 'pkg-b'
			reason: &db.Dependency{name: 'pkg-b', name_hash: db.compute_name_hash('pkg-b')}
		},
		db.Conflict{
			package1: 'pkg-c'
			package2: 'pkg-d'
			reason: &db.Dependency{name: 'pkg-d', name_hash: db.compute_name_hash('pkg-d')}
		},
	]

	resolved := resolve_conflicts(conflicts, [a, c], db.Database{}) or {
		assert false, 'expected all resolvable'
		return
	}
	assert resolved.len == 2
	assert resolved[0].remove_pkg == 'pkg-b'
	assert resolved[1].remove_pkg == 'pkg-d'
}

// ---------------------------------------------------------------------------
// File conflict detection — helpers
// ---------------------------------------------------------------------------

fn make_pkg_with_files(name string, file_names []string) &db.Package {
	mut files := []db.FileInfo{}
	for f in file_names {
		files << db.FileInfo{
			name: f
		}
	}
	return &db.Package{
		name:      name
		name_hash: db.compute_name_hash(name)
		files:     db.FileList{files: files}
		origin:    .sync_db
	}
}

// ---------------------------------------------------------------------------
// check_file_conflicts
// ---------------------------------------------------------------------------

fn test_file_conflicts_empty_targets() {
	conflicts := check_file_conflicts(&util.Handle{}, []&db.Package{}, &db.Database{}) or {
		assert false, 'expected success for empty targets'
		return
	}
	assert conflicts.len == 0
}

fn test_file_conflicts_single_target_no_fs() {
	targets := [make_pkg_with_files('pkg-a', ['usr/bin/foo', 'usr/lib/libfoo.so'])]
	conflicts := check_file_conflicts(&util.Handle{}, targets, &db.Database{}) or {
		assert false, 'expected success'
		return
	}
	assert conflicts.len == 0
}

fn test_file_conflicts_target_vs_target() {
	a := make_pkg_with_files('pkg-a', ['usr/bin/common', 'usr/lib/liba.so'])
	b := make_pkg_with_files('pkg-b', ['usr/bin/common', 'usr/lib/libb.so'])
	targets := [a, b]

	conflicts := check_file_conflicts(&util.Handle{}, targets, &db.Database{}) or {
		assert false, 'expected success'
		return
	}
	assert conflicts.len == 1, 'expected 1 file conflict, got ${conflicts.len}'

	c := conflicts[0]
	assert c.file.ends_with('usr/bin/common')
	assert c.conflict_type == .target
}

fn test_file_conflicts_target_vs_target_overwrite() {
	a := make_pkg_with_files('pkg-a', ['usr/bin/common', 'usr/lib/liba.so'])
	b := make_pkg_with_files('pkg-b', ['usr/bin/common', 'usr/lib/libb.so'])
	targets := [a, b]

	handle := &util.Handle{
		overwrite_files: ['usr/bin/common']
	}

	conflicts := check_file_conflicts(handle, targets, &db.Database{}) or {
		assert false, 'expected success'
		return
	}
	// Common file should be skipped due to overwrite pattern
	assert conflicts.len == 0, 'expected 0 conflicts with overwrite, got ${conflicts.len}'
}

fn test_file_conflicts_no_overlap() {
	a := make_pkg_with_files('pkg-a', ['usr/bin/foo'])
	b := make_pkg_with_files('pkg-b', ['usr/bin/bar'])
	targets := [a, b]

	conflicts := check_file_conflicts(&util.Handle{}, targets, &db.Database{}) or {
		assert false, 'expected success'
		return
	}
	assert conflicts.len == 0
}

fn test_file_conflicts_target_vs_fs() {
	tmpdir := os.join_path(os.temp_dir(), 'ace_test_fs_conflict')
	os.mkdir_all(tmpdir) or { panic('could not create ${tmpdir}') }
	defer {
		os.rmdir_all(tmpdir) or {}
	}

	// Create a file on the "filesystem"
	file_path := os.join_path(tmpdir, 'usr', 'bin', 'existing')
	os.mkdir_all(os.dir(file_path)) or { panic('mkdir') }
	os.write_file(file_path, '') or { panic('write') }

	targets := [make_pkg_with_files('pkg-a', ['usr/bin/existing'])]
	handle := &util.Handle{root: tmpdir}

	conflicts := check_file_conflicts(handle, targets, &db.Database{}) or {
		assert false, 'expected success'
		return
	}
	assert conflicts.len == 1, 'expected 1 fs conflict, got ${conflicts.len}'

	c := conflicts[0]
	assert c.file.ends_with('usr/bin/existing')
	assert c.conflict_type == .filesystem
	assert c.ctarget == ''
}

fn test_file_conflicts_target_vs_fs_overwrite() {
	tmpdir := os.join_path(os.temp_dir(), 'ace_test_fs_overwrite')
	os.mkdir_all(tmpdir) or { panic('could not create ${tmpdir}') }
	defer {
		os.rmdir_all(tmpdir) or {}
	}

	file_path := os.join_path(tmpdir, 'usr', 'bin', 'existing')
	os.mkdir_all(os.dir(file_path)) or { panic('mkdir') }
	os.write_file(file_path, '') or { panic('write') }

	targets := [make_pkg_with_files('pkg-a', ['usr/bin/existing'])]
	handle := &util.Handle{
		root:            tmpdir
		overwrite_files: ['usr/bin/existing']
	}

	conflicts := check_file_conflicts(handle, targets, &db.Database{}) or {
		assert false, 'expected success'
		return
	}
	assert conflicts.len == 0, 'expected 0 conflicts with overwrite, got ${conflicts.len}'
}

fn test_file_conflicts_file_vs_dir() {
	tmpdir := os.join_path(os.temp_dir(), 'ace_test_file_dir_conflict')
	os.mkdir_all(tmpdir) or { panic('could not create ${tmpdir}') }
	defer {
		os.rmdir_all(tmpdir) or {}
	}

	// Create a directory where the package wants a regular file
	dir_path := os.join_path(tmpdir, 'usr', 'bin', 'conflict_dir')
	os.mkdir_all(dir_path) or { panic('mkdir') }

	// Package has a file entry (no trailing slash) at same path
	targets := [make_pkg_with_files('pkg-a', ['usr/bin/conflict_dir'])]
	handle := &util.Handle{root: tmpdir}

	conflicts := check_file_conflicts(handle, targets, &db.Database{}) or {
		assert false, 'expected success'
		return
	}
	assert conflicts.len == 1, 'expected 1 dir conflict, got ${conflicts.len}'

	c := conflicts[0]
	assert c.conflict_type == .filesystem
}

fn test_file_conflicts_dir_in_pkg_vs_file_on_fs() {
	tmpdir := os.join_path(os.temp_dir(), 'ace_test_pkg_dir_vs_file')
	os.mkdir_all(tmpdir) or { panic('could not create ${tmpdir}') }
	defer {
		os.rmdir_all(tmpdir) or {}
	}

	// Create a regular file where the package wants a directory
	file_path := os.join_path(tmpdir, 'usr', 'share', 'app')
	os.mkdir_all(os.dir(file_path)) or { panic('mkdir') }
	os.write_file(file_path, 'content') or { panic('write') }

	// Package has a directory entry (trailing slash) at the same path
	targets := [make_pkg_with_files('pkg-a', ['usr/share/app/'])]
	handle := &util.Handle{root: tmpdir}

	conflicts := check_file_conflicts(handle, targets, &db.Database{}) or {
		assert false, 'expected success'
		return
	}
	// Package wants dir, filesystem has file — conflict
	assert conflicts.len == 1, 'expected 1 dir conflict, got ${conflicts.len}'
}

fn test_file_conflicts_multiple_targets() {
	a := make_pkg_with_files('pkg-a', ['usr/bin/common', 'usr/lib/liba.so'])
	b := make_pkg_with_files('pkg-b', ['usr/bin/common', 'usr/lib/libb.so'])
	c := make_pkg_with_files('pkg-c', ['usr/bin/other', 'usr/lib/libc.so'])
	targets := [a, b, c]

	conflicts := check_file_conflicts(&util.Handle{}, targets, &db.Database{}) or {
		assert false, 'expected success'
		return
	}
	// Only a and b share 'usr/bin/common' — one conflict
	assert conflicts.len == 1, 'expected 1 conflict, got ${conflicts.len}'
}

fn test_file_conflicts_localdb_upgrade_skip() {
	tmpdir := os.join_path(os.temp_dir(), 'ace_test_upgrade')
	os.mkdir_all(tmpdir) or { panic('could not create ${tmpdir}') }
	defer {
		os.rmdir_all(tmpdir) or {}
	}

	// Create a file on the filesystem that IS in the old version
	file_path := os.join_path(tmpdir, 'usr', 'bin', 'existing')
	os.mkdir_all(os.dir(file_path)) or { panic('mkdir') }
	os.write_file(file_path, '') or { panic('write') }

	// New version of the package has the same file
	targets := [make_pkg_with_files('pkg-a', ['usr/bin/new', 'usr/bin/existing'])]

	// Old (installed) version also had 'usr/bin/existing'
	mut localdb := db.Database{}
	localdb.pkgcache['pkg-a'] = make_pkg_with_files('pkg-a-old', ['usr/bin/existing'])
	// Overwrite name to match the target (it's the same package, just older)
	localdb.pkgcache['pkg-a'].name = 'pkg-a'
	localdb.pkgcache['pkg-a'].name_hash = db.compute_name_hash('pkg-a')

	handle := &util.Handle{root: tmpdir}

	conflicts := check_file_conflicts(handle, targets, &localdb) or {
		assert false, 'expected success'
		return
	}
	// 'usr/bin/existing' was in the old version, so it's skipped.
	// 'usr/bin/new' is new but doesn't exist on fs.
	assert conflicts.len == 0, 'expected 0 conflicts for upgrade, got ${conflicts.len}'
}
