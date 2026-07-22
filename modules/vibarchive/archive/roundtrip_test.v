module archive

fn test_roundtrip_tar_gz() {
	mut buf := []u8{len: 65536}
	w := new_writer()
	w.add_filter_gzip()!
	w.set_format_pax_restricted()!
	w.open_memory(mut buf)!
	e1 := new_entry()
	C.archive_entry_set_pathname(e1.inner, 'file1.txt'.str)
	C.archive_entry_set_size(e1.inner, 12)
	C.archive_entry_set_filetype(e1.inner, u32(ae_ifreg))
	C.archive_entry_set_perm(e1.inner, u32(0o644))
	w.write_header(e1)!
	w.write_data('hello world\n'.bytes())!
	w.finish_entry()!
	e1.free()
	e2 := new_entry()
	C.archive_entry_set_pathname(e2.inner, 'file2.txt'.str)
	C.archive_entry_set_size(e2.inner, 6)
	C.archive_entry_set_filetype(e2.inner, u32(ae_ifreg))
	C.archive_entry_set_perm(e2.inner, u32(0o644))
	w.write_header(e2)!
	w.write_data('foobar'.bytes())!
	w.finish_entry()!
	e2.free()
	e3 := new_entry()
	C.archive_entry_set_pathname(e3.inner, 'subdir'.str)
	C.archive_entry_set_size(e3.inner, 0)
	C.archive_entry_set_filetype(e3.inner, u32(ae_ifdir))
	C.archive_entry_set_perm(e3.inner, u32(0o755))
	w.write_header(e3)!
	w.finish_entry()!
	e3.free()
	w.close()!
	w.free()
	mut reader := new_reader()
	reader.support_filter_all()!
	reader.support_format_all()!
	reader.open_memory(buf)!
	mut entry_count := 0
	mut found_names := []string{}
	for {
		entry := reader.next_header() or { break }
		found_names << entry.pathname()
		entry_count++
		reader.skip_data()!
	}
	reader.free()
	assert entry_count == 3
	assert found_names.contains('file1.txt')
	assert found_names.contains('file2.txt')
	assert found_names.contains('subdir/')
}

fn test_roundtrip_zip() {
	mut buf := []u8{len: 65536}
	w := new_writer()
	w.set_format_zip()!
	w.open_memory(mut buf)!
	e1 := new_entry()
	C.archive_entry_set_pathname(e1.inner, 'hello.txt'.str)
	C.archive_entry_set_size(e1.inner, 5)
	C.archive_entry_set_filetype(e1.inner, u32(ae_ifreg))
	C.archive_entry_set_perm(e1.inner, u32(0o644))
	w.write_header(e1)!
	w.write_data('hello'.bytes())!
	w.finish_entry()!
	e1.free()
	e2 := new_entry()
	C.archive_entry_set_pathname(e2.inner, 'world.txt'.str)
	C.archive_entry_set_size(e2.inner, 5)
	C.archive_entry_set_filetype(e2.inner, u32(ae_ifreg))
	C.archive_entry_set_perm(e2.inner, u32(0o644))
	w.write_header(e2)!
	w.write_data('world'.bytes())!
	w.finish_entry()!
	e2.free()
	w.close()!
	w.free()
	mut reader := new_reader()
	reader.support_format_all()!
	reader.open_memory(buf)!
	entry1 := reader.next_header() or { assert false, 'should have entry'; return }
	assert entry1.pathname() == 'hello.txt'
	reader.skip_data()!
	entry2 := reader.next_header() or { assert false, 'should have second entry'; return }
	assert entry2.pathname() == 'world.txt'
	reader.skip_data()!
	reader.free()
}

fn test_roundtrip_large_entry() {
	mut buf := []u8{len: 1048576 + 65536}
	w := new_writer()
	w.add_filter_gzip()!
	w.set_format_pax_restricted()!
	w.open_memory(mut buf)!
	large_data := []u8{len: 1048576, init: u8(0x42)}
	e := new_entry()
	C.archive_entry_set_pathname(e.inner, 'large.bin'.str)
	C.archive_entry_set_size(e.inner, i64(1048576))
	C.archive_entry_set_filetype(e.inner, u32(ae_ifreg))
	C.archive_entry_set_perm(e.inner, u32(0o644))
	w.write_header(e)!
	w.write_data(large_data)!
	w.finish_entry()!
	e.free()
	w.close()!
	w.free()
	mut reader := new_reader()
	reader.support_filter_all()!
	reader.support_format_all()!
	reader.open_memory(buf)!
	entry := reader.next_header() or { assert false, 'should have entry'; return }
	assert entry.pathname() == 'large.bin'
	assert entry.size() == 1048576
	mut read_buf := []u8{len: 1048576}
	n := reader.read_data(mut read_buf)!
	assert n == 1048576
	assert read_buf[0] == u8(0x42)
	assert read_buf[1048575] == u8(0x42)
	reader.free()
}

fn test_error_corrupted_data() {
	corrupt_data := []u8{len: 100, init: u8(0xFF)}
	mut reader := new_reader()
	reader.support_format_all()!
	reader.open_memory(corrupt_data) or {
		assert err.msg().len > 0
		reader.free()
		return
	}
	reader.next_header() or {
		assert err.msg().len > 0
		reader.free()
		return
	}
	reader.skip_data() or {}
	reader.free()
}
