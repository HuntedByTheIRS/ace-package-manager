module db

import os

struct FixturePaths {
	tmp_root string
	db_path  string
}

fn create_fixture() FixturePaths {
	tmp_root := os.join_path(os.temp_dir(), 'ace-db-test')
	os.mkdir_all(tmp_root, os.MkdirParams{}) or { panic('mkdir tmp_root: ${err}') }
	db_path := tmp_root
	os.mkdir_all(os.join_path(db_path, 'local'), os.MkdirParams{}) or { panic('mkdir local: ${err}') }
	os.write_file(os.join_path(db_path, 'local', 'ALPM_DB_VERSION'), '9\n') or { panic('write version: ${err}') }
	return FixturePaths{tmp_root, db_path}
}

fn destroy_fixture(fx FixturePaths) {
	os.rmdir_all(fx.tmp_root) or {}
}

fn write_desc(pkg_dir string, sections []string) {
	// Format: flat array where sections are separated by '' terminators.
	// Two calling conventions:
	//   ['KEY', 'val', ..., '', 'KEY2', 'val', ..., '']  — with '' terminators
	//   ['KEY', 'val', ..., 'KEY2', 'val', ...]           — without '' (implicit boundary)
	// In the second form, a section key is any ALL-UPPERCASE identifier.
	mut content := ''
	mut i := 0
	for i < sections.len {
		key := sections[i]
		i++
		content += '%${key}%\n'
		// Read values until '' terminator or the next section key
		for i < sections.len {
			val := sections[i]
			if val == '' {
				i++
				break
			}
			// Check if this looks like a new section key (all uppercase letters).
			// A value that is all uppercase AND is followed by '' or a value-like item
			// is likely the next key.
			if looks_like_key(val) && i + 1 < sections.len {
				next := sections[i + 1]
				if next == '' || !looks_like_key(next) {
					// val is likely the next section key
					break
				}
			}
			content += '${val}\n'
			i++
		}
		content += '\n'
	}
	os.write_file(os.join_path(pkg_dir, 'desc'), content) or { panic('write desc: ${err}') }
}

// looks_like_key returns true if s is a non-empty string of only uppercase
// ASCII letters (it could be a section key like NAME, VERSION, DEPENDS, …).
fn looks_like_key(s string) bool {
	if s.len == 0 {
		return false
	}
	for c in s {
		if c < `A` || c > `Z` {
			return false
		}
	}
	return true
}

fn write_files(pkg_dir string, files []string, backups []string) {
	mut content := ''
	if files.len > 0 {
		content += '%FILES%\n'
		for f in files { content += '${f}\n' }
		content += '\n'
	}
	if backups.len > 0 {
		content += '%BACKUP%\n'
		for b in backups { content += '${b}\n' }
		content += '\n'
	}
	os.write_file(os.join_path(pkg_dir, 'files'), content) or { panic('write files: ${err}') }
}

fn test_init_valid_version() {
	fx := create_fixture()
	defer { destroy_fixture(fx) }
	ldb := init(fx.db_path) or { assert false; return }
	assert ldb.dbpath == os.join_path(fx.db_path, 'local')
	assert ldb.pkgcache.len == 0
}

fn test_init_wrong_version() {
	fx := create_fixture()
	defer { destroy_fixture(fx) }
	os.write_file(os.join_path(fx.db_path, 'local', 'ALPM_DB_VERSION'), '8\n') or { panic('write: ${err}') }
	init(fx.db_path) or { return }
	assert false
}

fn test_init_missing_version() {
	fx := create_fixture()
	defer { destroy_fixture(fx) }
	os.rm(os.join_path(fx.db_path, 'local', 'ALPM_DB_VERSION')) or { panic('rm: ${err}') }
	init(fx.db_path) or { return }
	assert false
}

fn test_populate_and_get_pkg() {
	fx := create_fixture()
	defer { destroy_fixture(fx) }
	pkg_dir := os.join_path(fx.db_path, 'local', 'glibc-2.35-1')
	os.mkdir_all(pkg_dir, os.MkdirParams{}) or { panic('mkdir: ${err}') }
	write_desc(pkg_dir, [
		'NAME', 'glibc',
		'VERSION', '2.35-1',
		'DESC', 'The GNU C Library',
		'ARCH', 'x86_64',
		'BUILDDATE', '1234567890',
		'INSTALLDATE', '1234567890',
		'REASON', '0',
		'SIZE', '12345678',
		'DEPENDS', 'glibc>=2.35', 'linux-api-headers>=4.10', '',
		'CONFLICTS', 'glibc-utils', '',
		'PROVIDES', 'glibc-provides', '',
	])
	write_files(pkg_dir, ['usr/', 'usr/bin/', 'usr/bin/foo'], ['etc/foo.conf\tabc123hash'])

	mut ldb := init(fx.db_path) or { panic('init') }
	ldb.populate() or { panic('populate') }
	assert ldb.pkgcache.len == 1, 'expected 1 pkg'

	pkg := ldb.get_pkg('glibc') or { assert false; return }
	assert pkg.name == 'glibc'
	assert pkg.version == '2.35-1'
	assert pkg.desc == 'The GNU C Library'
	assert pkg.arch == 'x86_64'
	assert pkg.build_date == 1234567890
	assert pkg.install_date == 1234567890
	assert pkg.reason == .explicit
	assert pkg.isize == 12345678
	assert pkg.origin == .local_db
	assert pkg.depends.len == 2
	assert pkg.depends[0].to_string() == 'glibc>=2.35'
	assert pkg.depends[1].to_string() == 'linux-api-headers>=4.10'
	assert pkg.conflicts.len == 1 && pkg.conflicts[0].to_string() == 'glibc-utils'
	assert pkg.provides.len == 1 && pkg.provides[0].to_string() == 'glibc-provides'
	assert pkg.files.files.len == 3
	assert pkg.files.files[0].name == 'usr/'
	assert pkg.files.files[2].name == 'usr/bin/foo'
	assert pkg.backup.len == 1
	assert pkg.backup[0].name == 'etc/foo.conf'
	assert pkg.backup[0].hash == 'abc123hash'
	assert ldb.get_pkgcache().len == 1
	if _ := ldb.get_pkg('nonexistent') { assert false }
}

fn test_multiple_packages() {
	fx := create_fixture()
	defer { destroy_fixture(fx) }
	d := os.join_path(fx.db_path, 'local')
	os.mkdir_all(os.join_path(d, 'glibc-2.35-1'), os.MkdirParams{}) or { panic("mkdir: ${err}") }
	write_desc(os.join_path(d, 'glibc-2.35-1'), ['NAME', 'glibc', 'VERSION', '2.35-1', 'DESC', 'GNU C Library', 'ARCH', 'x86_64', 'REASON', '0'])
	os.mkdir_all(os.join_path(d, 'systemd-250-1'), os.MkdirParams{}) or { panic("mkdir: ${err}") }
	write_desc(os.join_path(d, 'systemd-250-1'), ['NAME', 'systemd', 'VERSION', '250-1', 'DESC', 'System manager', 'ARCH', 'x86_64', 'REASON', '1', 'DEPENDS', 'glibc>=2.35', ''])
	os.mkdir_all(os.join_path(d, 'gtk-update-icon-cache-3.24-1'), os.MkdirParams{}) or { panic("mkdir: ${err}") }
	write_desc(os.join_path(d, 'gtk-update-icon-cache-3.24-1'), ['NAME', 'gtk-update-icon-cache', 'VERSION', '3.24-1', 'DESC', 'GTK icon cache', 'ARCH', 'x86_64', 'REASON', '0'])

	mut ldb := init(fx.db_path) or { panic('init') }
	ldb.populate() or { panic('populate') }
	assert ldb.pkgcache.len == 3, 'expected 3 pkgs got ${ldb.pkgcache.len}'

	mut names := []string{}
	for p in ldb.get_pkgcache() { names << p.name }
	assert 'glibc' in names
	assert 'systemd' in names
	assert 'gtk-update-icon-cache' in names

	pkg := ldb.get_pkg('systemd') or { panic('not found') }
	assert pkg.reason == .depend
	assert pkg.depends.len == 1
}

fn test_write_pkg_roundtrip() {
	fx := create_fixture()
	defer { destroy_fixture(fx) }
	pkg := &Package{
		name: 'test-pkg'
		name_hash: compute_name_hash('test-pkg')
		version: '1.0-1'
		desc: 'A test package'
		arch: 'x86_64'
		url: 'https://example.com/test'
		packager: 'Test User'
		build_date: 1700000000
		install_date: 1700000001
		isize: 12345
		reason: .explicit
		origin: .local_db
		licenses: ['MIT']
		groups: ['testing']
		depends: [Dependency.from_string('glibc>=2.35') or { panic('') }]
		conflicts: [Dependency.from_string('old-test') or { panic('') }]
		provides: [Dependency.from_string('test') or { panic('') }]
		files: FileList{files: [FileInfo{name: 'usr/'}, FileInfo{name: 'usr/bin/'}, FileInfo{name: 'usr/bin/test'}]}
		backup: [BackupFile{name: 'etc/test.conf', hash: 'abc123'}]
	}
	write_pkg(fx.db_path, pkg, infrq_desc|infrq_files) or { assert false; return }
	pkg_dir := os.join_path(fx.db_path, 'local', 'test-pkg-1.0-1')
	assert os.is_dir(pkg_dir)
	assert os.exists(os.join_path(pkg_dir, 'desc'))
	assert os.exists(os.join_path(pkg_dir, 'files'))

	mut ldb := init(fx.db_path) or { panic('init') }
	ldb.populate() or { panic('populate') }
	rp := ldb.get_pkg('test-pkg') or { assert false; return }
	assert rp.name == 'test-pkg'
	assert rp.version == '1.0-1'
	assert rp.desc == 'A test package'
	assert rp.arch == 'x86_64'
	assert rp.url == 'https://example.com/test'
	assert rp.build_date == 1700000000 && rp.install_date == 1700000001
	assert rp.isize == 12345 && rp.reason == .explicit
	assert rp.licenses.len == 1 && rp.licenses[0] == 'MIT'
	assert rp.groups.len == 1 && rp.groups[0] == 'testing'
	assert rp.depends.len == 1 && rp.depends[0].to_string() == 'glibc>=2.35'
	assert rp.conflicts.len == 1 && rp.conflicts[0].to_string() == 'old-test'
	assert rp.provides.len == 1 && rp.provides[0].to_string() == 'test'
	assert rp.files.files.len == 3
	assert rp.backup.len == 1 && rp.backup[0].name == 'etc/test.conf' && rp.backup[0].hash == 'abc123'
}

fn test_write_pkg_desc_only() {
	fx := create_fixture()
	defer { destroy_fixture(fx) }
	pkg := &Package{ name: 'minimal', name_hash: compute_name_hash('minimal'), version: '0.1-1', desc: 'Minimal', reason: .explicit, origin: .local_db }
	write_pkg(fx.db_path, pkg, infrq_desc) or { assert false; return }
	pkg_dir := os.join_path(fx.db_path, 'local', 'minimal-0.1-1')
	assert os.exists(os.join_path(pkg_dir, 'desc'))
	assert !os.exists(os.join_path(pkg_dir, 'files'))
	mut ldb := init(fx.db_path) or { panic('init') }
	ldb.populate() or { panic('populate') }
	rp := ldb.get_pkg('minimal') or { assert false; return }
	assert rp.version == '0.1-1'
}

fn test_remove_pkg() {
	fx := create_fixture()
	defer { destroy_fixture(fx) }
	pkg := &Package{ name: 'removable', name_hash: compute_name_hash('removable'), version: '1.0-1', desc: 'Bye', reason: .explicit, origin: .local_db, files: FileList{files: [FileInfo{name: 'f'}]} }
	write_pkg(fx.db_path, pkg, infrq_desc|infrq_files) or { assert false; return }
	pkg_dir := os.join_path(fx.db_path, 'local', 'removable-1.0-1')
	assert os.is_dir(pkg_dir)
	remove_pkg(fx.db_path, 'removable', '1.0-1') or { assert false; return }
	assert !os.exists(pkg_dir)
	mut ldb := init(fx.db_path) or { panic('init') }
	ldb.populate() or { panic('populate') }
	if _ := ldb.get_pkg('removable') { assert false }
}

fn test_remove_pkg_not_found() {
	fx := create_fixture()
	defer { destroy_fixture(fx) }
	remove_pkg(fx.db_path, 'nonexistent', '1.0') or { return }
	assert false
}

fn test_write_pkg_full_metadata() {
	fx := create_fixture()
	defer { destroy_fixture(fx) }
	val_both := 4 | 8
	pkg := &Package{
		name: 'fullmeta'
		name_hash: compute_name_hash('fullmeta')
		version: '2.0-1'
		base: 'fullmeta-base'
		desc: 'Full metadata package'
		arch: 'x86_64'
		url: 'https://ex.com'
		packager: 'Alice'
		build_date: 1500000000
		install_date: 1500000001
		isize: 99999
		reason: .depend
		origin: .local_db
		licenses: ['GPL', 'MIT']
		groups: ['base', 'base-devel']
		validation: unsafe { PackageValidation(val_both) }
		depends: [Dependency.from_string('glibc>=2.35') or { panic('') }]
		optdepends: [Dependency.from_string('python: for scripts') or { panic('') }]
		makedepends: [Dependency.from_string('cmake>=3.0') or { panic('') }]
		checkdepends: [Dependency.from_string('valgrind') or { panic('') }]
		conflicts: [Dependency.from_string('old-fullmeta') or { panic('') }]
		provides: [Dependency.from_string('fullmeta-prev') or { panic('') }]
		replaces: [Dependency.from_string('old-fullmeta<2.0') or { panic('') }]
		xdata: [XData{name: 'pkgtype', value: 'debug'}]
		files: FileList{files: [FileInfo{name: 'readme.txt'}]}
		backup: [BackupFile{name: 'etc/config', hash: 'def456'}]
	}
	write_pkg(fx.db_path, pkg, infrq_desc|infrq_files) or { assert false; return }
	mut ldb := init(fx.db_path) or { panic('init') }
	ldb.populate() or { panic('populate') }
	rp := ldb.get_pkg('fullmeta') or { assert false; return }
	assert rp.base == 'fullmeta-base'
	assert rp.licenses.len == 2 && rp.groups.len == 2
	assert rp.optdepends.len == 1 && rp.optdepends[0].to_string() == 'python'
	assert rp.makedepends.len == 1 && rp.makedepends[0].to_string() == 'cmake>=3.0'
	assert rp.checkdepends.len == 1 && rp.checkdepends[0].to_string() == 'valgrind'
	assert rp.replaces.len == 1 && rp.replaces[0].to_string() == 'old-fullmeta<2.0'
	assert int(rp.validation) == val_both
	assert rp.xdata.len == 1 && rp.xdata[0].name == 'pkgtype' && rp.xdata[0].value == 'debug'
}
