module archive

import os

fn test_extract_to_dir() {
	tmp := os.join_path(os.temp_dir(), 'vibarchive_etd')
	os.rmdir_all(tmp) or {}
	os.mkdir_all(tmp) or {}

	tar_path := os.join_path(tmp, 'test.tar.gz')
	w := new_writer()
	w.add_filter_gzip()!
	w.set_format_pax_restricted()!
	w.open_file(tar_path)!

	e1 := new_entry()
	C.archive_entry_set_pathname(e1.inner, 'mydir'.str)
	C.archive_entry_set_size(e1.inner, 0)
	C.archive_entry_set_filetype(e1.inner, u32(ae_ifdir))
	C.archive_entry_set_perm(e1.inner, u32(0o755))
	w.write_header(e1)!
	w.finish_entry()!

	e2 := new_entry()
	C.archive_entry_set_pathname(e2.inner, 'mydir/hello.txt'.str)
	C.archive_entry_set_size(e2.inner, 12)
	C.archive_entry_set_filetype(e2.inner, u32(ae_ifreg))
	C.archive_entry_set_perm(e2.inner, u32(0o644))
	w.write_header(e2)!
	w.write_data('hello world\n'.bytes())!
	w.finish_entry()!
	w.close()!
	w.free()

	extract_dir := os.join_path(tmp, 'out')
	extract_to_dir(tar_path, extract_dir, ExtractOpts{})!

	assert os.is_dir(os.join_path(extract_dir, 'mydir'))
	assert os.is_file(os.join_path(extract_dir, 'mydir', 'hello.txt'))
	content := os.read_file(os.join_path(extract_dir, 'mydir', 'hello.txt')) or { panic(err) }
	assert content == 'hello world\n'
	os.rmdir_all(tmp) or {}
}

fn test_ls_archive() {
	tmp := os.join_path(os.temp_dir(), 'vibarchive_lsa')
	os.rmdir_all(tmp) or {}
	os.mkdir_all(tmp) or {}

	tar_path := os.join_path(tmp, 'list_test.tar')
	w := new_writer()
	w.add_filter_none()!
	w.set_format_pax_restricted()!
	w.open_file(tar_path)!

	e1 := new_entry()
	C.archive_entry_set_pathname(e1.inner, 'dir1'.str)
	C.archive_entry_set_size(e1.inner, 0)
	C.archive_entry_set_filetype(e1.inner, u32(ae_ifdir))
	C.archive_entry_set_perm(e1.inner, u32(0o755))
	w.write_header(e1)!
	w.finish_entry()!

	e2 := new_entry()
	C.archive_entry_set_pathname(e2.inner, 'dir1/file.txt'.str)
	C.archive_entry_set_size(e2.inner, 4)
	C.archive_entry_set_filetype(e2.inner, u32(ae_ifreg))
	C.archive_entry_set_perm(e2.inner, u32(0o644))
	w.write_header(e2)!
	w.write_data('test'.bytes())!
	w.finish_entry()!
	w.close()!
	w.free()

	entries := ls_archive(tar_path)!
	assert entries.len == 2
	assert entries[0].path == 'dir1'
	assert entries[0].is_dir
	assert entries[1].path == 'dir1/file.txt'
	assert entries[1].is_file
	assert entries[1].size == 4
	os.rmdir_all(tmp) or {}
}
