module db

import os
import vibarchive.archive

// ---------------------------------------------------------------------------
// Helpers: build minimal .db.tar fixture
// ---------------------------------------------------------------------------

// build_test_db creates a temporary .db.tar archive with known packages for
// testing. Returns the path to the archive file and a cleanup callback.
fn build_test_db() (string, fn ()) {
	tmpdir := os.join_path(os.temp_dir(), 'ace_sync_test_' + os.args[0].hash().hex())
	os.mkdir_all(tmpdir) or { panic('mkdir_all: ${err}') }

	db_path := os.join_path(tmpdir, 'test.db.tar')

	mut w := archive.new_writer()
	w.set_format_pax_restricted() or { panic('set_format: ${err}') }
	w.add_filter_none() or { panic('add_filter: ${err}') }
	w.open_file(db_path) or { panic('open_file: ${err}') }

	// ---- pacman 6.0.1-2 ----
	w.add_directory('pacman-6.0.1-2') or { panic('add_dir: ${err}') }

	pacman_desc := [
		'%NAME%',
		'pacman',
		'%VERSION%',
		'6.0.1-2',
		'%DESC%',
		'A library-based package manager with dependency support',
		'%URL%',
		'https://archlinux.org/pacman/',
		'%ARCH%',
		'x86_64',
		'%PACKAGER%',
		'Developer <dev@archlinux.org>',
		'%BASE%',
		'pacman',
		'%SHA256SUM%',
		'abc123def456',
		'%PGPSIG%',
		'iQEzBAABCgAdFiEE...pacman-sig',
		'%FILENAME%',
		'pacman-6.0.1-2-x86_64.pkg.tar.zst',
		'%CSIZE%',
		'654321',
		'%ISIZE%',
		'2345678',
		'%LICENSE%',
		'GPL2',
		'',
	].join('\n')
	w.add_bytes('pacman-6.0.1-2/desc', pacman_desc.bytes()) or { panic('add_bytes: ${err}') }

	pacman_depends := [
		'glibc>=2.35',
		'libarchive>=3.6.0',
		'curl',
		'gpgme',
	].join('\n')
	w.add_bytes('pacman-6.0.1-2/depends', pacman_depends.bytes()) or { panic('add_bytes: ${err}') }

	pacman_files := [
		'usr/',
		'usr/bin/',
		'usr/bin/pacman',
		'usr/bin/makepkg',
		'usr/share/',
		'usr/share/man/',
		'usr/share/man/man8/pacman.8',
	].join('\n')
	w.add_bytes('pacman-6.0.1-2/files', pacman_files.bytes()) or { panic('add_bytes: ${err}') }

	// ---- glibc 2.35-1 ----
	w.add_directory('glibc-2.35-1') or { panic('add_dir: ${err}') }

	glibc_desc := [
		'%NAME%',
		'glibc',
		'%VERSION%',
		'2.35-1',
		'%DESC%',
		'GNU C Library',
		'%ARCH%',
		'x86_64',
		'%PACKAGER%',
		'Developer <dev@archlinux.org>',
		'%PGPSIG%',
		'iQEzBAABCgAdFiEE...glibc-sig',
		'%FILENAME%',
		'glibc-2.35-1-x86_64.pkg.tar.zst',
		'%CSIZE%',
		'12345678',
		'%ISIZE%',
		'98765432',
		'%LICENSE%',
		'LGPL',
		'%LICENSE%',
		'GPL',
		'%PROVIDES%',
		'glibc-minimal-libs>=2.35',
		'',
	].join('\n')
	w.add_bytes('glibc-2.35-1/desc', glibc_desc.bytes()) or { panic('add_bytes: ${err}') }

	glibc_depends := [
		'linux-api-headers>=5.10',
		'tzdata',
	].join('\n')
	w.add_bytes('glibc-2.35-1/depends', glibc_depends.bytes()) or { panic('add_bytes: ${err}') }

	// ---- linux 6.1-1 (name extracted from dir as fallback) ----
	w.add_directory('linux-6.1-1') or { panic('add_dir: ${err}') }

	// Deliberately NO %NAME% / %VERSION% to test directory-name fallback.
	linux_desc := [
		'%DESC%',
		'Linux kernel',
		'%ARCH%',
		'x86_64',
		'%PGPSIG%',
		'iQEzBAABCgAdFiEE...linux-sig',
		'%FILENAME%',
		'linux-6.1-1-x86_64.pkg.tar.zst',
		'%CSIZE%',
		'99999999',
		'%ISIZE%',
		'555555555',
		'',
	].join('\n')
	w.add_bytes('linux-6.1-1/desc', linux_desc.bytes()) or { panic('add_bytes: ${err}') }

	linux_depends := ['glibc>=2.35'].join('\n')
	w.add_bytes('linux-6.1-1/depends', linux_depends.bytes()) or { panic('add_bytes: ${err}') }

	w.free()

	return db_path, fn [tmpdir] () {
		os.rmdir_all(tmpdir) or {}
	}
}

// ---------------------------------------------------------------------------
// populate
// ---------------------------------------------------------------------------

fn test_populate_basic() {
	db_path, cleanup := build_test_db()
	defer {
		cleanup()
	}

	mut sdb := new_sync_db()
	populate(mut sdb, db_path) or { assert false, 'populate failed: ${err}' }

	assert sdb.pkgcache.len == 3, 'expected 3 packages, got ${sdb.pkgcache.len}'
}

fn test_populate_pacman_metadata() {
	db_path, cleanup := build_test_db()
	defer {
		cleanup()
	}

	mut sdb := new_sync_db()
	populate(mut sdb, db_path) or { assert false, 'populate failed: ${err}' }

	pkg := get_pkg(&sdb, 'pacman') or { assert false, 'pacman not found'; return }

	assert pkg.name == 'pacman', 'name: ${pkg.name}'
	assert pkg.version == '6.0.1-2', 'version: ${pkg.version}'
	assert pkg.desc == 'A library-based package manager with dependency support'
	assert pkg.url == 'https://archlinux.org/pacman/'
	assert pkg.arch == 'x86_64'
	assert pkg.packager == 'Developer <dev@archlinux.org>'
	assert pkg.base == 'pacman'
	assert pkg.sha256sum == 'abc123def456'
	assert pkg.filename == 'pacman-6.0.1-2-x86_64.pkg.tar.zst'
	assert pkg.download_size == 654321
	assert pkg.isize == 2345678
	assert pkg.origin == .sync_db
	assert pkg.name_hash == compute_name_hash('pacman')
}

fn test_populate_glibc_pgp_sig() {
	db_path, cleanup := build_test_db()
	defer {
		cleanup()
	}

	mut sdb := new_sync_db()
	populate(mut sdb, db_path) or { assert false, 'populate failed: ${err}' }

	pkg := get_pkg(&sdb, 'glibc') or { assert false, 'glibc not found'; return }

	// Verify %PGPSIG% parsing.
	assert pkg.base64_sig == 'iQEzBAABCgAdFiEE...glibc-sig',
		'PGPSIG: ${pkg.base64_sig}'

	// Verify multiple license values.
	assert pkg.licenses.len == 2, 'licenses count: ${pkg.licenses.len}'
	assert pkg.licenses[0] == 'LGPL'
	assert pkg.licenses[1] == 'GPL'

	// Verify provides parsing.
	assert pkg.provides.len == 1, 'provides count: ${pkg.provides.len}'
	assert pkg.provides[0].name == 'glibc-minimal-libs'
	assert pkg.provides[0].modifier == .ge
}

fn test_populate_depends() {
	db_path, cleanup := build_test_db()
	defer {
		cleanup()
	}

	mut sdb := new_sync_db()
	populate(mut sdb, db_path) or { assert false, 'populate failed: ${err}' }

	pkg := get_pkg(&sdb, 'pacman') or { assert false, 'pacman not found'; return }

	assert pkg.depends.len == 4, 'depends count: ${pkg.depends.len}'

	mut found_glibc := false
	mut found_curl := false
	for dep in pkg.depends {
		if dep.name == 'glibc' {
			found_glibc = true
			assert dep.version == '2.35'
			assert dep.modifier == .ge
		}
		if dep.name == 'curl' {
			found_curl = true
			assert dep.version == ''
			assert dep.modifier == .any
		}
	}
	assert found_glibc, 'dependency glibc>=2.35 not found'
	assert found_curl, 'dependency curl not found'
}

fn test_populate_files() {
	db_path, cleanup := build_test_db()
	defer {
		cleanup()
	}

	mut sdb := new_sync_db()
	populate(mut sdb, db_path) or { assert false, 'populate failed: ${err}' }

	pkg := get_pkg(&sdb, 'pacman') or { assert false, 'pacman not found'; return }

	assert pkg.files.files.len == 7, 'files count: ${pkg.files.files.len}'
	assert pkg.files.files[2].name == 'usr/bin/pacman'
	assert pkg.files.files[6].name == 'usr/share/man/man8/pacman.8'
}

fn test_populate_directory_name_fallback() {
	db_path, cleanup := build_test_db()
	defer {
		cleanup()
	}

	mut sdb := new_sync_db()
	populate(mut sdb, db_path) or { assert false, 'populate failed: ${err}' }

	// linux package has no %NAME%/%VERSION% in desc — falls back to dir name.
	pkg := get_pkg(&sdb, 'linux') or { assert false, 'linux not found (fallback failed)'; return }

	assert pkg.name == 'linux'
	assert pkg.version == '6.1-1'
	assert pkg.desc == 'Linux kernel'
}

fn test_get_pkg_not_found() {
	sdb := new_sync_db()
	result := get_pkg(&sdb, 'nonexistent')
	if _ := result {
		assert false, 'expected none for nonexistent package'
	}
}

fn test_get_pkgcache() {
	db_path, cleanup := build_test_db()
	defer {
		cleanup()
	}

	mut sdb := new_sync_db()
	populate(mut sdb, db_path) or { assert false, 'populate failed: ${err}' }

	pkgs := get_pkgcache(&sdb)
	assert pkgs.len == 3, 'get_pkgcache count: ${pkgs.len}'

	mut names := map[string]bool{}
	for p in pkgs {
		names[p.name] = true
	}
	assert 'pacman' in names
	assert 'glibc' in names
	assert 'linux' in names
}

fn test_populate_invalid_path() {
	mut sdb := new_sync_db()
	populate(mut sdb, '/nonexistent/path/core.db') or {
		err_msg := err.msg()
		assert err_msg.contains('not found'), 'unexpected error: ${err_msg}'
		return
	}
	assert false, 'expected error for invalid path'
}

// ---------------------------------------------------------------------------
// split_name_version
// ---------------------------------------------------------------------------

fn test_split_name_version_typical() {
	name, version := split_name_version('glibc-2.35-1')
	assert name == 'glibc'
	assert version == '2.35-1'
}

fn test_split_name_version_with_hyphens_in_name() {
	name, version := split_name_version('gtk-update-icon-cache-3.24.0-1')
	assert name == 'gtk-update-icon-cache'
	assert version == '3.24.0-1'
}

fn test_split_name_version_no_version() {
	name, version := split_name_version('foo')
	assert name == 'foo'
	assert version == ''
}

fn test_split_name_version_single_char_name() {
	name, version := split_name_version('a-1.0-1')
	assert name == 'a'
	assert version == '1.0-1'
}

fn test_split_name_version_digit_in_name() {
	name, version := split_name_version('libfoo2-3.0-1')
	assert name == 'libfoo2'
	assert version == '3.0-1'
}

// ---------------------------------------------------------------------------
// parse_desc edge cases
// ---------------------------------------------------------------------------

fn test_parse_desc_empty() {
	mut pkg := &Package{}
	parse_desc(mut pkg, '')
	assert pkg.name == ''
}

fn test_parse_desc_no_keys() {
	mut pkg := &Package{}
	parse_desc(mut pkg, 'some\ngarbage\ndata')
	assert pkg.name == ''
	assert pkg.version == ''
}

fn test_parse_desc_pgp_sig_extraction() {
	mut pkg := &Package{}
	desc := [
		'%NAME%', 'testpkg',
		'%VERSION%', '1.0-1',
		'%PGPSIG%',
		'iQEzBAABCgAdFiEE...multiline',
		'  continuation',
		'%FILENAME%', 'test.pkg.tar.zst',
		'',
	].join('\n')
	parse_desc(mut pkg, desc)

	assert pkg.base64_sig == 'iQEzBAABCgAdFiEE...multiline\n  continuation'
}
