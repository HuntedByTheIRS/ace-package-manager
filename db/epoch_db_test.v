// Edge-case tests: epoch-prefixed versions in sync database parsing.
module db

import os
import vibarchive.archive

// ---------------------------------------------------------------------------
// Helpers: build a mini .db.tar with epoch versions
// ---------------------------------------------------------------------------

fn build_epoch_test_db() (string, fn ()) {
	tmpdir := os.join_path(os.temp_dir(), 'ace_epoch_test_' + os.args[0].hash().hex())
	os.mkdir_all(tmpdir) or { panic('mkdir_all: ${err}') }
	db_path := os.join_path(tmpdir, 'epoch.db.tar')

	mut w := archive.new_writer()
	w.set_format_pax_restricted() or { panic('set_format: ${err}') }
	w.add_filter_none() or { panic('add_filter: ${err}') }
	w.open_file(db_path) or { panic('open_file: ${err}') }

	// ---- pkg-epoch 2:1.0-1 ----
	w.add_directory('pkg-epoch-2:1.0-1') or { panic('add_dir: ${err}') }
	epoch_desc := [
		'%NAME%',
		'pkg-epoch',
		'%VERSION%',
		'2:1.0-1',
		'%DESC%',
		'Package with epoch 2',
		'%ARCH%',
		'x86_64',
		'',
	].join('\n')
	w.add_bytes('pkg-epoch-2:1.0-1/desc', epoch_desc.bytes()) or { panic('add_bytes: ${err}') }

	// ---- pkg-zero-epoch 0:1.0-1 ----
	w.add_directory('pkg-zero-epoch-0:1.0-1') or { panic('add_dir: ${err}') }
	zero_desc := [
		'%NAME%',
		'pkg-zero-epoch',
		'%VERSION%',
		'0:1.0-1',
		'%DESC%',
		'Package with epoch 0',
		'%ARCH%',
		'x86_64',
		'',
	].join('\n')
	w.add_bytes('pkg-zero-epoch-0:1.0-1/desc', zero_desc.bytes()) or { panic('add_bytes: ${err}') }

	// ---- pkg-no-epoch 1.0-1 ----
	w.add_directory('pkg-no-epoch-1.0-1') or { panic('add_dir: ${err}') }
	noepoch_desc := [
		'%NAME%',
		'pkg-no-epoch',
		'%VERSION%',
		'1.0-1',
		'%DESC%',
		'Package without epoch',
		'%ARCH%',
		'x86_64',
		'',
	].join('\n')
	w.add_bytes('pkg-no-epoch-1.0-1/desc', noepoch_desc.bytes()) or { panic('add_bytes: ${err}') }

	w.free()
	return db_path, fn [tmpdir] () {
		os.rmdir_all(tmpdir) or {}
	}
}

fn build_epoch_dep_db() (string, fn ()) {
	tmpdir := os.join_path(os.temp_dir(), 'ace_epoch_dep_test_' + os.args[0].hash().hex())
	os.mkdir_all(tmpdir) or { panic('mkdir_all: ${err}') }
	db_path := os.join_path(tmpdir, 'epoch-dep.db.tar')

	mut w := archive.new_writer()
	w.set_format_pax_restricted() or { panic('set_format: ${err}') }
	w.add_filter_none() or { panic('add_filter: ${err}') }
	w.open_file(db_path) or { panic('open_file: ${err}') }

	// ---- libfoo 2:1.0-1 (provides libfoo.so=2 with epoch version) ----
	w.add_directory('libfoo-2:1.0-1') or { panic('add_dir: ${err}') }
	lf_desc := [
		'%NAME%',
		'libfoo',
		'%VERSION%',
		'2:1.0-1',
		'%DESC%',
		'Lib with epoch version',
		'%ARCH%',
		'x86_64',
		'%PROVIDES%',
		'libfoo.so=2',
		'',
	].join('\n')
	w.add_bytes('libfoo-2:1.0-1/desc', lf_desc.bytes()) or { panic('add_bytes: ${err}') }

	w.free()
	return db_path, fn [tmpdir] () {
		os.rmdir_all(tmpdir) or {}
	}
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn test_populate_epoch_version() {
	db_path, cleanup := build_epoch_test_db()
	defer {
		cleanup()
	}

	mut sdb := new_sync_db()
	populate(mut sdb, db_path) or { assert false, 'populate failed: ${err}' }

	// pkg-epoch should have version "2:1.0-1"
	pkg := get_pkg(&sdb, 'pkg-epoch') or { assert false, 'pkg-epoch not found'; return }
	assert pkg.version == '2:1.0-1', 'expected 2:1.0-1, got ${pkg.version}'
}

fn test_populate_zero_epoch_version() {
	db_path, cleanup := build_epoch_test_db()
	defer {
		cleanup()
	}

	mut sdb := new_sync_db()
	populate(mut sdb, db_path) or { assert false, 'populate failed: ${err}' }

	pkg := get_pkg(&sdb, 'pkg-zero-epoch') or { assert false, 'pkg-zero-epoch not found'; return }
	assert pkg.version == '0:1.0-1', 'expected 0:1.0-1, got ${pkg.version}'
}

fn test_populate_no_epoch_version() {
	db_path, cleanup := build_epoch_test_db()
	defer {
		cleanup()
	}

	mut sdb := new_sync_db()
	populate(mut sdb, db_path) or { assert false, 'populate failed: ${err}' }

	pkg := get_pkg(&sdb, 'pkg-no-epoch') or { assert false, 'pkg-no-epoch not found'; return }
	assert pkg.version == '1.0-1', 'expected 1.0-1, got ${pkg.version}'
}

fn test_split_name_version_with_epoch() {
	// Directory names with epoch colons
	name, version := split_name_version('libfoo-2:1.0-1')
	assert name == 'libfoo'
	assert version == '2:1.0-1'
}

fn test_split_name_version_zero_epoch() {
	name, version := split_name_version('libfoo-0:1.0-1')
	assert name == 'libfoo'
	assert version == '0:1.0-1'
}

fn test_split_name_version_epoch_only_dir() {
	// Edge: name with epoch in directory but no version after
	name, version := split_name_version('pkg-5:0')
	assert name == 'pkg'
	assert version == '5:0'
}

fn test_populate_epoch_dep_provides() {
	db_path, cleanup := build_epoch_dep_db()
	defer {
		cleanup()
	}

	mut sdb := new_sync_db()
	populate(mut sdb, db_path) or { assert false, 'populate failed: ${err}' }

	pkg := get_pkg(&sdb, 'libfoo') or { assert false, 'libfoo not found'; return }
	assert pkg.version == '2:1.0-1'
	assert pkg.provides.len == 1
	assert pkg.provides[0].name == 'libfoo.so'
	assert pkg.provides[0].version == '2'
}

fn test_epoch_version_in_local_db() {
	tmpdir := os.join_path(os.temp_dir(), 'ace_local_epoch_test')
	defer { os.rmdir_all(tmpdir) or {} }

	os.mkdir_all(os.join_path(tmpdir, 'local', 'epoch-pkg-2:1.0-1'), os.MkdirParams{}) or {
		panic('mkdir: ${err}')
	}
	os.write_file(os.join_path(tmpdir, 'local', 'ALPM_DB_VERSION'), '9\n') or { panic('write: ${err}') }
	os.write_file(os.join_path(tmpdir, 'local', 'epoch-pkg-2:1.0-1', 'desc'), '%NAME%\nepoch-pkg\n%VERSION%\n2:1.0-1\n%REASON%\n0\n\n') or {
		panic('write desc: ${err}')
	}

	mut ldb := init(tmpdir) or { assert false; return }
	ldb.populate() or { assert false; return }
	pkg := ldb.get_pkg('epoch-pkg') or { assert false, 'epoch-pkg not found'; return }
	assert pkg.version == '2:1.0-1', 'expected 2:1.0-1, got ${pkg.version}'
}
