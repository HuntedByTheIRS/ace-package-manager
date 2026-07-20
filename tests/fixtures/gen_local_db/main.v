// gen_local_db — generates minimal local database fixture directories.
//
// Output: tests/fixtures/output/local/ (standard) and local-empty/ (empty)

import os

const output_dir = 'tests/fixtures/output'

fn ensure_output_dir() {
	os.mkdir_all(output_dir, os.MkdirParams{}) or { panic('mkdir: ${err}') }
}

fn write_file(path string, content string) {
	os.mkdir_all(os.dir(path), os.MkdirParams{}) or { panic('mkdir: ${err}') }
	os.write_file(path, content) or { panic('write: ${err}') }
}

fn make_pkg_dir(pkgname string, version string) string {
	dir := os.join_path(output_dir, 'local', '${pkgname}-${version}')
	os.mkdir_all(dir, os.MkdirParams{}) or { panic('mkdir: ${err}') }
	return dir
}

fn write_desc(pkg_dir string, sections []string) {
	mut content := ''
	mut i := 0
	for i < sections.len {
		key := sections[i]
		i++
		content += '%${key}%\n'
		for i < sections.len {
			val := sections[i]
			if val == '' {
				i++
				break
			}
			content += '${val}\n'
			i++
		}
		content += '\n'
	}
	write_file(os.join_path(pkg_dir, 'desc'), content)
}

fn write_files(pkg_dir string, files []string) {
	mut content := ''
	if files.len > 0 {
		content += '%FILES%\n'
		for f in files {
			content += '${f}\n'
		}
		content += '\n'
	}
	write_file(os.join_path(pkg_dir, 'files'), content)
}

fn build_standard_db() {
	local_dir := os.join_path(output_dir, 'local')
	os.mkdir_all(local_dir, os.MkdirParams{}) or { panic('mkdir: ${err}') }
	write_file(os.join_path(local_dir, 'ALPM_DB_VERSION'), '9\n')

	pd := make_pkg_dir('hello', '1.0-1')
	write_desc(pd, [
		'NAME', 'hello',
		'VERSION', '1.0-1',
		'DESC', 'A friendly greeting program',
		'ARCH', 'x86_64',
		'URL', 'https://example.com/hello',
		'LICENSE', 'GPL',
		'PACKAGER', 'Fixture Builder <test@ace.local>',
		'SIZE', '4096',
		'ISIZE', '8192',
		'BUILDDATE', '1700000000',
		'INSTALLDATE', '1700000001',
		'REASON', '0',
		'DEPENDS', 'glibc>=2.35', '',
		'PROVIDES', 'greeter', '',
	])
	write_files(pd, ['/usr/bin/hello', '/usr/share/man/man1/hello.1'])

	pd2 := make_pkg_dir('libfoo', '2.1-3')
	write_desc(pd2, [
		'NAME', 'libfoo',
		'VERSION', '2.1-3',
		'DESC', 'An example library',
		'ARCH', 'x86_64',
		'URL', 'https://example.com/libfoo',
		'LICENSE', 'LGPL',
		'PACKAGER', 'Fixture Builder <test@ace.local>',
		'SIZE', '2048',
		'ISIZE', '8192',
		'BUILDDATE', '1700000100',
		'INSTALLDATE', '1700000101',
		'REASON', '1',
		'DEPENDS', 'hello', '',
		'OPTDEPENDS', 'docs: for documentation', '',
	])
	write_files(pd2, ['/usr/lib/libfoo.so', '/usr/lib/libfoo.so.2', '/usr/include/foo.h'])

	pd3 := make_pkg_dir('glibc', '2.35-1')
	write_desc(pd3, [
		'NAME', 'glibc',
		'VERSION', '2.35-1',
		'DESC', 'GNU C Library',
		'ARCH', 'x86_64',
		'PACKAGER', 'Fixture Builder <test@ace.local>',
		'SIZE', '12345678',
		'ISIZE', '98765432',
		'BUILDDATE', '1690000000',
		'INSTALLDATE', '1690000001',
		'REASON', '0',
		'DEPENDS', 'linux-api-headers>=4.10', 'tzdata', '',
	])
	write_files(pd3, ['usr/', 'usr/lib/', 'usr/lib/libc.so.6'])
	println('  wrote ${os.join_path(output_dir, "local")}/')
}

fn build_empty_local_db() {
	local_dir := os.join_path(output_dir, 'local-empty')
	os.mkdir_all(local_dir, os.MkdirParams{}) or { panic('mkdir: ${err}') }
	write_file(os.join_path(local_dir, 'ALPM_DB_VERSION'), '9\n')
	println('  wrote ${local_dir}/')
}

fn main() {
	ensure_output_dir()
	println('Generating local database fixtures...')
	build_standard_db()
	build_empty_local_db()
	println('Done.')
}
