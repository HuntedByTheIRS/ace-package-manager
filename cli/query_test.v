// Tests for the -Q (query) subcommand and argument parsing.
module cli

import db
import os
import rand

// ---------------------------------------------------------------------------
// Fixture helpers
// ---------------------------------------------------------------------------

// create_fixture builds a pacman-format local database with test packages
// under a temp directory. Returns (db_path, cleanup_fn).
fn create_fixture() (string, fn ()) {
	tmp_root := os.join_path(os.temp_dir(), 'ace-test-${rand.u32():x}')
	os.mkdir_all(tmp_root, os.MkdirParams{}) or { panic('mkdir failed: ${err}') }

	db_path := os.join_path(tmp_root, 'var', 'lib', 'ace')
	os.mkdir_all(os.join_path(db_path, 'local'), os.MkdirParams{}) or {
		panic('mkdir failed: ${err}')
	}

	// ALPM_DB_VERSION is required by db.init.
	os.write_file(os.join_path(db_path, 'local', 'ALPM_DB_VERSION'), '9\n') or {
		panic('write version failed: ${err}')
	}

	// ---- package: hello-1.0-1 ----
	pkg_dir1 := os.join_path(db_path, 'local', 'hello-1.0-1')
	os.mkdir_all(pkg_dir1, os.MkdirParams{}) or { panic('mkdir failed: ${err}') }

	write_desc_file(pkg_dir1, [
		'%NAME%', '', 'hello',
		'%VERSION%', '', '1.0-1',
		'%DESC%', '', 'A friendly greeting program',
		'%ARCH%', '', 'x86_64',
		'%URL%', '', 'https://example.com/hello',
		'%LICENSE%', '', 'GPL',
		'%LICENSE%', '', 'MIT',
		'%PACKAGER%', '', 'Test User <test@example.com>',
	'%SIZE%', '', '4096',
	'%ISIZE%', '', '8192',
		'%BUILDDATE%', '', '1700000000',
		'%INSTALLDATE%', '', '1700000001',
		'%VALIDATION%', '', 'sha256',
		'%REASON%', '', '0',
		'%DEPENDS%', '', 'glibc>=2.35',
		'%PROVIDES%', '', 'greeter',
	])

	write_files_file(pkg_dir1, [
		'/usr/bin/hello',
		'/usr/share/man/man1/hello.1',
	])

	// ---- package: libfoo-2.1-3 ----
	pkg_dir2 := os.join_path(db_path, 'local', 'libfoo-2.1-3')
	os.mkdir_all(pkg_dir2, os.MkdirParams{}) or { panic('mkdir failed: ${err}') }

	write_desc_file(pkg_dir2, [
		'%NAME%', '', 'libfoo',
		'%VERSION%', '', '2.1-3',
		'%DESC%', '', 'An example library',
		'%ARCH%', '', 'x86_64',
		'%URL%', '', 'https://example.com/libfoo',
		'%LICENSE%', '', 'LGPL',
		'%PACKAGER%', '', 'Test User <test@example.com>',
		'%SIZE%', '', '2048',
		'%ISIZE%', '', '8192',
		'%BUILDDATE%', '', '1700000100',
		'%INSTALLDATE%', '', '1700000101',
		'%VALIDATION%', '', 'sha256',
		'%REASON%', '', '1',
		'%DEPENDS%', '', 'hello',
		'%OPTDEPENDS%', '', 'docs: for documentation',
	])

	write_files_file(pkg_dir2, [
		'/usr/lib/libfoo.so',
		'/usr/lib/libfoo.so.2',
		'/usr/include/foo.h',
	])

	cleanup := fn [tmp_root] () {
		os.rmdir_all(tmp_root) or {}
	}

	return db_path, cleanup
}

// write_desc_file creates a pacman-format desc file.
// Values with the same key are accumulated as multi-line entries.
fn write_desc_file(pkg_dir string, entries []string) {
	mut sections := map[string][]string{}
	for i in 0 .. entries.len / 3 {
		key := entries[i * 3]
		val := entries[i * 3 + 2]
		sections[key] << val
	}
	mut content := ''
	for key, vals in sections {
		content += '${key}\n'
		for v in vals {
			content += '${v}\n'
		}
		content += '\n'
	}
	os.write_file(os.join_path(pkg_dir, 'desc'), content) or {
		panic('write desc failed: ${err}')
	}
}

// write_files_file creates a pacman-format files file.
fn write_files_file(pkg_dir string, files []string) {
	mut content := '%FILES%\n'
	for f in files {
		content += '${f}\n'
	}
	os.write_file(os.join_path(pkg_dir, 'files'), content) or {
		panic('write files failed: ${err}')
	}
}

// setup_db creates a fixture and returns a populated LocalDB + cleanup.
fn setup_db() (db.LocalDB, fn ()) {
	db_path, cleanup := create_fixture()
	mut local_db := db.init(db_path) or { panic('init failed: ${err}') }
	local_db.populate() or { panic('populate failed: ${err}') }
	return local_db, cleanup
}

// ---------------------------------------------------------------------------
// parse_args tests
// ---------------------------------------------------------------------------

fn test_parse_args_empty() {
	args := parse_args_from(['ace'])
	assert args.operation == .main
	assert args.targets.len == 0
}

fn test_parse_args_q_list() {
	args := parse_args_from(['ace', '-Q'])
	assert args.operation == .query
	assert args.query_op == .list
	assert args.targets.len == 0
}

fn test_parse_args_qi() {
	args := parse_args_from(['ace', '-Qi', 'hello'])
	assert args.operation == .query
	assert args.query_op == .info
	assert args.targets == ['hello']
}

fn test_parse_args_ql() {
	args := parse_args_from(['ace', '-Ql', 'hello'])
	assert args.operation == .query
	assert args.query_op == .files
	assert args.targets == ['hello']
}

fn test_parse_args_qs() {
	args := parse_args_from(['ace', '-Qs', 'hello'])
	assert args.operation == .query
	assert args.query_op == .search
	assert args.targets == ['hello']
}

fn test_parse_args_qo() {
	args := parse_args_from(['ace', '-Qo', '/usr/bin/hello'])
	assert args.operation == .query
	assert args.query_op == .owner
	assert args.targets == ['/usr/bin/hello']
}

fn test_parse_args_deptest() {
	args := parse_args_from(['ace', '-T', 'glibc', 'glibc>=2.35'])
	assert args.operation == .deptest
	assert args.targets == ['glibc', 'glibc>=2.35']
}

fn test_parse_args_deptest_no_targets() {
	args := parse_args_from(['ace', '-T'])
	assert args.operation == .deptest
	assert args.targets.len == 0
}

fn test_parse_args_root_flag() {
	args := parse_args_from(['ace', '--root', '/mnt', '-Q'])
	assert args.operation == .query
	assert args.root == '/mnt'
}

fn test_parse_args_dbpath_flag() {
	args := parse_args_from(['ace', '--dbpath', '/custom/db', '-Q'])
	assert args.operation == .query
	assert args.dbpath == '/custom/db'
}

fn test_parse_args_qii() {
	args := parse_args_from(['ace', '-Qii', 'hello'])
	assert args.operation == .query
	assert args.query_info == 2
	assert args.targets == ['hello']
}

fn test_parse_args_qkk() {
	args := parse_args_from(['ace', '-Qkk', 'hello'])
	assert args.operation == .query
	assert args.query_check == 2
	assert args.targets == ['hello']
}

fn test_parse_args_qdt() {
	args := parse_args_from(['ace', '-Qdt'])
	assert args.operation == .query
	assert args.query_deps == true
	assert args.query_unrequired == 1
}

fn test_parse_args_qtd() {
	args := parse_args_from(['ace', '-Qtd'])
	assert args.operation == .query
	assert args.query_unrequired == 1
	assert args.query_deps == true
}

fn test_parse_args_qtt() {
	args := parse_args_from(['ace', '-Qtt'])
	assert args.operation == .query
	assert args.query_unrequired == 2
}

fn test_parse_args_qn() {
	args := parse_args_from(['ace', '-Qn', 'hello'])
	assert args.operation == .query
	assert args.query_native == true
	assert args.targets == ['hello']
}

fn test_parse_args_qm() {
	args := parse_args_from(['ace', '-Qm'])
	assert args.operation == .query
	assert args.query_foreign == true
}

fn test_parse_args_qu() {
	args := parse_args_from(['ace', '-Qu'])
	assert args.operation == .query
	assert args.query_upgrades == true
}

fn test_parse_args_qc() {
	args := parse_args_from(['ace', '-Qc', 'hello'])
	assert args.operation == .query
	assert args.query_changelog == true
	assert args.targets == ['hello']
}

fn test_parse_args_qg() {
	args := parse_args_from(['ace', '-Qg'])
	assert args.operation == .query
	assert args.query_groups == 1
}

fn test_parse_args_qp() {
	args := parse_args_from(['ace', '-Qp', 'pkg.tar.zst'])
	assert args.operation == .query
	assert args.query_file == true
	assert args.targets == ['pkg.tar.zst']
}

fn test_parse_args_qde() {
	args := parse_args_from(['ace', '-Qde'])
	assert args.operation == .query
	assert args.query_deps == true
	assert args.query_explicit == true
}

fn test_parse_args_q_all_flags() {
	args := parse_args_from(['ace', '-Qcdeiklmnoqstuy', 'target'])
	assert args.operation == .query
	assert args.query_changelog == true
	assert args.query_deps == true
	assert args.query_explicit == true
	assert args.query_info == 1
	// 'k' and 'y' are not valid -Q flags, silently ignored
	assert args.query_list == true
	assert args.query_foreign == true
	assert args.query_native == true
	assert args.query_owns == true
	assert args.quiet == true
	assert args.query_search == true
	assert args.query_unrequired == 1
	assert args.query_upgrades == true
	assert args.targets == ['target']
}

// ---------------------------------------------------------------------------
// Query operation tests
// ---------------------------------------------------------------------------

fn test_query_list() {
	local_db, cleanup := setup_db()
	defer { cleanup() }

	pkgs := local_db.get_pkgcache()
	assert pkgs.len == 2

	mut names := map[string]bool{}
	for pkg in pkgs {
		names[pkg.name] = true
	}
	assert names['hello'] == true
	assert names['libfoo'] == true
}

fn test_query_info() {
	local_db, cleanup := setup_db()
	defer { cleanup() }

	pkg := local_db.get_pkg('hello') or { panic('get_pkg failed: ${err}') }

	assert pkg.name == 'hello'
	assert pkg.version == '1.0-1'
	assert pkg.desc == 'A friendly greeting program'
	assert pkg.arch == 'x86_64'
	assert pkg.url == 'https://example.com/hello'
	assert pkg.licenses.len == 2
	assert 'GPL' in pkg.licenses
	assert 'MIT' in pkg.licenses
	assert pkg.packager == 'Test User <test@example.com>'
	assert pkg.isize == 4096
	assert pkg.build_date == 1700000000
	assert pkg.install_date == 1700000001
	assert pkg.reason == .explicit
	assert pkg.depends.len == 1
	assert pkg.depends[0].to_string() == 'glibc>=2.35'
	assert pkg.provides.len == 1
	assert pkg.provides[0].to_string() == 'greeter'
}

fn test_query_info_dep_pkg() {
	local_db, cleanup := setup_db()
	defer { cleanup() }

	pkg := local_db.get_pkg('libfoo') or { panic('get_pkg failed: ${err}') }

	assert pkg.name == 'libfoo'
	assert pkg.reason == .depend
	assert pkg.depends.len == 1
	assert pkg.depends[0].to_string() == 'hello'
	assert pkg.optdepends.len == 1
	assert pkg.optdepends[0].to_string() == 'docs: for documentation'
}

fn test_query_info_not_found() {
	local_db, cleanup := setup_db()
	defer { cleanup() }

	pkg := local_db.get_pkg('nonexistent') or {
		// Expected — none returned
		return
	}
	assert false, 'expected none for nonexistent package, got ${pkg.name}'
}

fn test_query_files() {
	local_db, cleanup := setup_db()
	defer { cleanup() }

	pkg := local_db.get_pkg('hello') or { panic('get_pkg failed: ${err}') }
	assert pkg.files.files.len == 2
	assert pkg.files.files[0].name == '/usr/bin/hello'
	assert pkg.files.files[1].name == '/usr/share/man/man1/hello.1'
}

fn test_query_files_second_pkg() {
	local_db, cleanup := setup_db()
	defer { cleanup() }

	pkg := local_db.get_pkg('libfoo') or { panic('get_pkg failed: ${err}') }
	assert pkg.files.files.len == 3

	mut names := []string{}
	for f in pkg.files.files {
		names << f.name
	}
	assert '/usr/lib/libfoo.so' in names
	assert '/usr/lib/libfoo.so.2' in names
	assert '/usr/include/foo.h' in names
}

fn test_query_owner() {
	local_db, cleanup := setup_db()
	defer { cleanup() }

	hello := local_db.get_pkg('hello') or { panic('get_pkg failed: ${err}') }
	libfoo := local_db.get_pkg('libfoo') or { panic('get_pkg failed: ${err}') }

	// hello owns /usr/bin/hello
	mut found := false
	for f in hello.files.files {
		if f.name == '/usr/bin/hello' {
			found = true
			break
		}
	}
	assert found

	// libfoo owns /usr/include/foo.h
	found = false
	for f in libfoo.files.files {
		if f.name == '/usr/include/foo.h' {
			found = true
			break
		}
	}
	assert found
}

fn test_query_owner_not_found() {
	local_db, cleanup := setup_db()
	defer { cleanup() }

	mut found_owner := false
	pkgs := local_db.get_pkgcache()
	for pkg in pkgs {
		for f in pkg.files.files {
			if f.name == '/nonexistent/file' {
				found_owner = true
				break
			}
		}
		if found_owner {
			break
		}
	}
	assert found_owner == false
}

fn test_query_search() {
	local_db, cleanup := setup_db()
	defer { cleanup() }

	pkgs := local_db.get_pkgcache()

	mut hello_found := false
	mut libfoo_found := false
	for pkg in pkgs {
		if pkg.name == 'hello' {
			hello_found = true
		}
		if pkg.name == 'libfoo' {
			libfoo_found = true
		}
	}
	assert hello_found
	assert libfoo_found
}

fn test_query_list_all_versions() {
	local_db, cleanup := setup_db()
	defer { cleanup() }

	pkgs := local_db.get_pkgcache()

	mut hello_found := false
	mut libfoo_found := false
	for pkg in pkgs {
		if pkg.name == 'hello' {
			assert pkg.version == '1.0-1'
			hello_found = true
		}
		if pkg.name == 'libfoo' {
			assert pkg.version == '2.1-3'
			libfoo_found = true
		}
	}
	assert hello_found
	assert libfoo_found
}

// ---------------------------------------------------------------------------
// Edge-case tests
// ---------------------------------------------------------------------------

fn test_query_list_empty_db() {
	tmp_root := os.join_path(os.temp_dir(), 'ace-test-empty-${rand.u32():x}')
	defer { os.rmdir_all(tmp_root) or {} }

	os.mkdir_all(tmp_root, os.MkdirParams{}) or { panic('mkdir failed: ${err}') }

	db_path := os.join_path(tmp_root, 'var', 'lib', 'ace')
	os.mkdir_all(os.join_path(db_path, 'local'), os.MkdirParams{}) or {
		panic('mkdir failed: ${err}')
	}
	os.write_file(os.join_path(db_path, 'local', 'ALPM_DB_VERSION'), '9\n') or {
		panic('write version failed: ${err}')
	}

	mut local_db := db.init(db_path) or { panic('init failed: ${err}') }
	local_db.populate() or { panic('populate failed: ${err}') }

	pkgs := local_db.get_pkgcache()
	assert pkgs.len == 0
}

fn test_missing_db_errors_gracefully() {
	absent_path := os.join_path(os.temp_dir(), 'ace-test-nonexistent-${rand.u32():x}', 'var', 'lib', 'ace')
	db.init(absent_path) or {
		assert err.msg().contains('does not exist')
		return
	}
	assert false, 'expected error for missing DB'
}

// ---------------------------------------------------------------------------
// -D (database) parsing tests
// ---------------------------------------------------------------------------

fn test_parse_args_database() {
	args := parse_args_from(['ace', '-D'])
	assert args.operation == .database
	assert args.targets.len == 0
}

fn test_parse_args_database_k() {
	args := parse_args_from(['ace', '-Dk'])
	assert args.operation == .database
	assert args.database_check == 1
}

fn test_parse_args_database_kk() {
	args := parse_args_from(['ace', '-Dkk'])
	assert args.operation == .database
	assert args.database_check == 2
}

fn test_parse_args_database_kq() {
	args := parse_args_from(['ace', '-Dkq'])
	assert args.operation == .database
	assert args.database_check == 1
	assert args.quiet == true
}

fn test_parse_args_database_asdeps() {
	args := parse_args_from(['ace', '-D', '--asdeps', 'hello'])
	assert args.operation == .database
	assert args.asdeps == true
	assert args.targets == ['hello']
}

fn test_parse_args_database_asexplicit() {
	args := parse_args_from(['ace', '-D', '--asexplicit', 'hello'])
	assert args.operation == .database
	assert args.asexplicit == true
	assert args.targets == ['hello']
}

fn test_parse_args_database_check_long() {
	args := parse_args_from(['ace', '-D', '--check', 'hello'])
	assert args.operation == .database
	assert args.database_check == 1
	assert args.targets == ['hello']
}

// ---------------------------------------------------------------------------
// -F (files) parsing tests
// ---------------------------------------------------------------------------

fn test_parse_args_files() {
	args := parse_args_from(['ace', '-F'])
	assert args.operation == .files
	assert args.targets.len == 0
}

fn test_parse_args_files_list() {
	args := parse_args_from(['ace', '-Fl'])
	assert args.operation == .files
	assert args.files_list == true
}

fn test_parse_args_files_y() {
	args := parse_args_from(['ace', '-Fy'])
	assert args.operation == .files
	assert args.files_refresh == 1
}

fn test_parse_args_files_yy() {
	args := parse_args_from(['ace', '-Fyy'])
	assert args.operation == .files
	assert args.files_refresh == 2
}

fn test_parse_args_files_x() {
	args := parse_args_from(['ace', '-Fx', 'pattern'])
	assert args.operation == .files
	assert args.files_regex == true
	assert args.targets == ['pattern']
}

fn test_parse_args_files_quiet() {
	args := parse_args_from(['ace', '-Fq'])
	assert args.operation == .files
	assert args.quiet == true
}

fn test_parse_args_files_machinereadable() {
	args := parse_args_from(['ace', '-F', '--machinereadable'])
	assert args.operation == .files
	assert args.files_machinereadable == true
}

fn test_parse_args_files_list_long() {
	args := parse_args_from(['ace', '-F', '--list'])
	assert args.operation == .files
	assert args.files_list == true
}

fn test_parse_args_files_refresh_long() {
	args := parse_args_from(['ace', '-F', '--refresh'])
	assert args.operation == .files
	assert args.files_refresh == 1
}

fn test_parse_args_files_regex_long() {
	args := parse_args_from(['ace', '-F', '--regex', 'pattern'])
	assert args.operation == .files
	assert args.files_regex == true
	assert args.targets == ['pattern']
}

fn test_parse_args_files_combined() {
	args := parse_args_from(['ace', '-Fly', 'searchterm'])
	assert args.operation == .files
	assert args.files_list == true
	assert args.files_refresh == 1
	assert args.targets == ['searchterm']
}

fn test_parse_args_files_lyx() {
	args := parse_args_from(['ace', '-Flyx', 'pattern'])
	assert args.operation == .files
	assert args.files_list == true
	assert args.files_refresh == 1
	assert args.files_regex == true
	assert args.targets == ['pattern']
}
