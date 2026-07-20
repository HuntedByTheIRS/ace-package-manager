// gen_core_db — generates minimal sync database (.db.tar) fixture files.
//
// Output: tests/fixtures/output/{core,empty,circular,epoch,large}.db

import os
import vibarchive.archive

const output_dir = 'tests/fixtures/output'

fn ensure_output_dir() {
	os.mkdir_all(output_dir, os.MkdirParams{}) or { panic('mkdir: ${err}') }
}

fn make_writer(path string) &archive.ArchiveWriter {
	mut w := archive.new_writer()
	w.set_format_pax_restricted() or { panic('set_format: ${err}') }
	w.add_filter_zstd() or { panic('add_filter_zstd: ${err}') }
	w.open_file(path) or { panic('open_file: ${err}') }
	return w
}

fn add_pkg_dir(mut w archive.ArchiveWriter, dirname string) {
	w.add_directory(dirname) or { panic('add_dir: ${err}') }
}

fn add_desc(mut w archive.ArchiveWriter, dirname string, lines []string) {
	content := lines.join('\n').bytes()
	w.add_bytes('${dirname}/desc', content) or { panic('add_desc: ${err}') }
}

fn add_depends(mut w archive.ArchiveWriter, dirname string, deps []string) {
	content := deps.join('\n').bytes()
	w.add_bytes('${dirname}/depends', content) or { panic('add_depends: ${err}') }
}

fn add_files(mut w archive.ArchiveWriter, dirname string, files []string) {
	content := files.join('\n').bytes()
	w.add_bytes('${dirname}/files', content) or { panic('add_files: ${err}') }
}

fn pack_db(path string, build fn (mut archive.ArchiveWriter)) {
	mut w := make_writer(path)
	build(mut w)
	w.free()
	println('  wrote ${path}')
}

fn build_core_db(mut w archive.ArchiveWriter) {
	add_pkg_dir(mut w, 'pacman-6.0.1-2')
	add_desc(mut w, 'pacman-6.0.1-2', [
		'%NAME%', 'pacman',
		'%VERSION%', '6.0.1-2',
		'%DESC%', 'A library-based package manager',
		'%ARCH%', 'x86_64',
		'%PACKAGER%', 'Fixture Builder <test@ace.local>',
		'%FILENAME%', 'pacman-6.0.1-2-x86_64.pkg.tar.zst',
		'%CSIZE%', '654321',
		'%ISIZE%', '2345678',
		'',
	])
	add_depends(mut w, 'pacman-6.0.1-2', ['glibc>=2.35', 'libarchive>=3.6.0', 'curl', 'gpgme'])
	add_files(mut w, 'pacman-6.0.1-2', ['usr/', 'usr/bin/', 'usr/bin/pacman', 'usr/share/man/man8/pacman.8'])

	add_pkg_dir(mut w, 'glibc-2.35-1')
	add_desc(mut w, 'glibc-2.35-1', [
		'%NAME%', 'glibc',
		'%VERSION%', '2.35-1',
		'%DESC%', 'GNU C Library',
		'%ARCH%', 'x86_64',
		'%PACKAGER%', 'Fixture Builder <test@ace.local>',
		'%FILENAME%', 'glibc-2.35-1-x86_64.pkg.tar.zst',
		'%CSIZE%', '12345678',
		'%ISIZE%', '98765432',
		'%LICENSE%', 'LGPL',
		'',
	])
	add_depends(mut w, 'glibc-2.35-1', ['linux-api-headers>=5.10', 'tzdata'])
	add_files(mut w, 'glibc-2.35-1', ['usr/', 'usr/lib/', 'usr/lib/libc.so.6'])

	add_pkg_dir(mut w, 'linux-6.1-1')
	add_desc(mut w, 'linux-6.1-1', [
		'%DESC%', 'Linux kernel',
		'%ARCH%', 'x86_64',
		'%FILENAME%', 'linux-6.1-1-x86_64.pkg.tar.zst',
		'%CSIZE%', '99999999',
		'%ISIZE%', '555555555',
		'',
	])
	add_depends(mut w, 'linux-6.1-1', ['glibc>=2.35'])
}

fn build_empty_db(mut w archive.ArchiveWriter) {
	_ := w
}

fn build_circular_db(mut w archive.ArchiveWriter) {
	add_pkg_dir(mut w, 'pkg-a-1.0-1')
	add_desc(mut w, 'pkg-a-1.0-1', ['%NAME%', 'pkg-a', '%VERSION%', '1.0-1', '%DESC%', 'Circular dep A', '%ARCH%', 'x86_64', ''])
	add_depends(mut w, 'pkg-a-1.0-1', ['pkg-b'])

	add_pkg_dir(mut w, 'pkg-b-1.0-1')
	add_desc(mut w, 'pkg-b-1.0-1', ['%NAME%', 'pkg-b', '%VERSION%', '1.0-1', '%DESC%', 'Circular dep B', '%ARCH%', 'x86_64', ''])
	add_depends(mut w, 'pkg-b-1.0-1', ['pkg-c'])

	add_pkg_dir(mut w, 'pkg-c-1.0-1')
	add_desc(mut w, 'pkg-c-1.0-1', ['%NAME%', 'pkg-c', '%VERSION%', '1.0-1', '%DESC%', 'Circular dep C', '%ARCH%', 'x86_64', ''])
	add_depends(mut w, 'pkg-c-1.0-1', ['pkg-a'])
}

fn build_epoch_db(mut w archive.ArchiveWriter) {
	add_pkg_dir(mut w, 'pkg-normal-1.0-1')
	add_desc(mut w, 'pkg-normal-1.0-1', ['%NAME%', 'pkg-normal', '%VERSION%', '1.0-1', '%DESC%', 'No epoch', '%ARCH%', 'x86_64', ''])

	add_pkg_dir(mut w, 'pkg-epoch-2:1.0-1')
	add_desc(mut w, 'pkg-epoch-2:1.0-1', ['%NAME%', 'pkg-epoch', '%VERSION%', '2:1.0-1', '%DESC%', 'With epoch', '%ARCH%', 'x86_64', ''])

	add_pkg_dir(mut w, 'pkg-epoch-zero-0:1.0-1')
	add_desc(mut w, 'pkg-epoch-zero-0:1.0-1', ['%NAME%', 'pkg-epoch-zero', '%VERSION%', '0:1.0-1', '%DESC%', 'Epoch zero', '%ARCH%', 'x86_64', ''])
}

fn build_large_db(mut w archive.ArchiveWriter) {
	mut idx := 0
	for name in ['filesystem', 'glibc', 'gcc-libs', 'tzdata', 'bash', 'coreutils'] {
		idx++
		ver := '${idx}.0-1'
		dir := '${name}-${ver}'
		add_pkg_dir(mut w, dir)
		add_desc(mut w, dir, ['%NAME%', name, '%VERSION%', ver, '%DESC%', '${name} fixture', '%ARCH%', 'x86_64', ''])
	}
	libs := ['pam', 'systemd', 'dbus', 'openssl', 'zlib', 'zstd', 'libarchive', 'curl']
	for name in libs {
		idx++
		ver := '${idx}.0-1'
		dir := '${name}-${ver}'
		add_pkg_dir(mut w, dir)
		add_desc(mut w, dir, ['%NAME%', name, '%VERSION%', ver, '%DESC%', '${name} fixture', '%ARCH%', 'x86_64', ''])
		add_depends(mut w, dir, ['glibc>=2.35'])
	}
	apps := ['pacman', 'python', 'perl', 'git', 'vim', 'nginx', 'sqlite']
	for name in apps {
		idx++
		ver := '${idx}.0-1'
		dir := '${name}-${ver}'
		add_pkg_dir(mut w, dir)
		add_desc(mut w, dir, ['%NAME%', name, '%VERSION%', ver, '%DESC%', '${name} fixture', '%ARCH%', 'x86_64', ''])
		add_depends(mut w, dir, ['glibc>=2.35', 'zlib'])
	}
}

fn main() {
	ensure_output_dir()
	println('Generating sync database fixtures...')
	pack_db('${output_dir}/core.db', build_core_db)
	pack_db('${output_dir}/empty.db', build_empty_db)
	pack_db('${output_dir}/circular.db', build_circular_db)
	pack_db('${output_dir}/epoch.db', build_epoch_db)
	pack_db('${output_dir}/large.db', build_large_db)
	println('Done.')
}
