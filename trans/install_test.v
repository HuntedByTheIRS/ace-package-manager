// Tests for package extraction into a target root (trans/install.v).
module trans

import db
import os
import rand
import util

// make_test_archive builds a .pkg.tar.zst holding a directory, a regular
// file, a hard link to that file, and a symlink.  Returns the archive path.
// The archive is packed with tar/zstd, the same tools makepkg-driven
// fixtures use (see tests/fixtures/gen_pkg_tar_zst).
fn make_test_archive(tmp string) string {
	src := os.join_path(tmp, 'src')
	pay_dir := os.join_path(src, 'usr', 'share', 'ace')
	os.mkdir_all(pay_dir) or { panic('mkdir: ${err}') }

	data := os.join_path(pay_dir, 'data')
	os.write_file(data, 'payload\n') or { panic('write: ${err}') }
	os.link(data, os.join_path(pay_dir, 'data-link')) or { panic('link: ${err}') }
	os.symlink('data', os.join_path(pay_dir, 'data-sym')) or { panic('symlink: ${err}') }

	archive := os.join_path(tmp, 'ace-extract-test-1.0-1-x86_64.pkg.tar.zst')
	res := os.execute('tar --format=posix -cf - -C "${src}" usr | zstd -f -q -o "${archive}"')
	assert res.exit_code == 0, 'pack failed: ${res.output}'
	return archive
}

fn test_extract_preserves_hard_links() {
	tmp := os.join_path(os.temp_dir(), 'ace-install-test-${rand.u32():x}')
	root := os.join_path(tmp, 'root')
	dbpath := os.join_path(root, 'var', 'lib', 'ace')
	os.mkdir_all(os.join_path(dbpath, 'local')) or { panic('mkdir: ${err}') }
	defer {
		os.rmdir_all(tmp) or {}
	}

	archive := make_test_archive(tmp)
	mut handle := util.Handle{
		root:   root
		dbpath: dbpath
	}
	mut pkg := db.Package{
		name:    'ace-extract-test'
		version: '1.0-1'
	}
	extract_package_files(handle, archive, mut pkg) or {
		assert false, 'extraction failed: ${err}'
		return
	}

	data := os.join_path(root, 'usr', 'share', 'ace', 'data')
	link := os.join_path(root, 'usr', 'share', 'ace', 'data-link')
	sym := os.join_path(root, 'usr', 'share', 'ace', 'data-sym')

	// Regression: hard link entries carry no payload, and were silently
	// dropped before (ncurses ships ~1000 terminfo entries this way).
	assert os.exists(link), 'hard link was not extracted'
	assert !os.is_link(link), 'hard link must not be a symlink'
	data_stat := os.lstat(data) or { panic('lstat data: ${err}') }
	link_stat := os.lstat(link) or { panic('lstat link: ${err}') }
	assert link_stat.inode == data_stat.inode, 'hard link must share the inode of its target'
	assert link_stat.nlink >= 2, 'hard link must raise the target link count'
	assert link_stat.size == data_stat.size, 'hard link must expose the target size'
	assert os.read_file(link) or { '' } == os.read_file(data) or { '' }

	// Symlinks keep their target.
	assert os.is_link(sym)
	assert os.readlink(sym) or { '' } == 'data'

	// Every extracted path is recorded, so -Ql/-Qk see them too.
	names := pkg.files.files.map(it.name)
	assert 'usr/share/ace/data' in names
	assert 'usr/share/ace/data-link' in names
	assert 'usr/share/ace/data-sym' in names
}
