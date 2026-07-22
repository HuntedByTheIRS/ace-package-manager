module archive

fn test_empty_archive() {
	// An empty byte buffer should produce an error when trying to read an entry
	r := new_reader()
	defer {
		r.free()
	}
	r.support_filter_all()!
	r.support_format_all()!
	r.open_memory([]u8{}) or {
		// open_memory itself may fail on empty buffer; that's acceptable
		assert err.msg().len > 0
		return
	}
	// If open succeeded, next_header must fail (no archive data)
	r.next_header() or {
		assert err.msg().len > 0
		return
	}
	assert false, 'expected error for empty archive — got a valid entry'
}

fn test_truncated_data() {
	// Write a valid ustar archive, then truncate the buffer to simulate an incomplete stream.
	// Truncating the end-of-archive marker should produce a read error.
	mut buf := []u8{len: 4096}
	w := new_writer()
	defer {
		w.free()
	}
	w.set_format_ustar()!
	w.open_memory(mut buf)!

	e := new_entry()
	defer {
		e.free()
	}
	C.archive_entry_set_pathname(e.inner, c'file.txt')
	C.archive_entry_set_size(e.inner, 0)
	C.archive_entry_set_filetype(e.inner, u32(ae_ifreg))
	C.archive_entry_set_perm(e.inner, u32(0o644))
	w.write_header(e)!
	w.finish_entry()!
	w.close()!

	// ustar archive: header (512B) + 2 EOF blocks (1024B) = 1536B minimum.
	// Truncate to only the first 512-byte block to remove EOF markers.
	truncated := buf[..512].clone()

	r := new_reader()
	defer {
		r.free()
	}
	r.support_format_all()!
	r.open_memory(truncated) or {
		// open may succeed even on truncated data
	}
	// First entry (0-size file header) may parse fine from the 512B truncation
	entry := r.next_header()!
	assert entry.pathname() == 'file.txt'
	r.skip_data()!
	// Second next_header must fail — EOF blocks were truncated away
	r.next_header() or {
		assert err.msg().len > 0
		return
	}
	assert false, 'expected error for second next_header on truncated archive'
}

fn test_zero_size_entry() {
	// Creating and reading back a zero-size entry
	mut buf := []u8{len: 4096}

	w := new_writer()
	defer {
		w.free()
	}
	w.add_filter_gzip()!
	w.set_format_pax_restricted()!
	w.open_memory(mut buf)!

	e := new_entry()
	defer {
		e.free()
	}
	C.archive_entry_set_pathname(e.inner, c'empty.txt')
	C.archive_entry_set_size(e.inner, 0)
	C.archive_entry_set_filetype(e.inner, u32(ae_ifreg))
	C.archive_entry_set_perm(e.inner, u32(0o644))
	w.write_header(e)!
	w.finish_entry()!
	w.close()!

	r := new_reader()
	defer {
		r.free()
	}
	r.support_filter_all()!
	r.support_format_all()!
	r.open_memory(buf)!

	entry := r.next_header() or {
		assert false, 'should have entry for zero-size file'
		return
	}
	assert entry.pathname() == 'empty.txt'
	assert entry.size() == 0

	// Reading from a zero-size entry should return 0 bytes (EOF), not an error
	mut out := []u8{len: 10}
	n := r.read_data(mut out) or {
		assert false, 'reading from zero-size entry should not error'
		return
	}
	assert n == 0
}

fn test_very_long_pathname() {
	// Write an entry with a 300-char pathname; verify it roundtrips via PAX extended headers.
	long_name := 'a'.repeat(300)
	mut buf := []u8{len: 65536}

	w := new_writer()
	defer {
		w.free()
	}
	w.add_filter_gzip()!
	// Use unrestricted PAX format so libarchive stores the full path via extended headers
	check_result(w.inner, C.archive_write_set_format_pax(w.inner))!
	w.open_memory(mut buf)!

	e := new_entry()
	defer {
		e.free()
	}
	C.archive_entry_set_pathname(e.inner, long_name.str)
	C.archive_entry_set_size(e.inner, 5)
	C.archive_entry_set_filetype(e.inner, u32(ae_ifreg))
	C.archive_entry_set_perm(e.inner, u32(0o644))
	w.write_header(e)!
	w.write_data('hello'.bytes())!
	w.finish_entry()!
	w.close()!

	// Read back — PAX reader should reconstruct the full pathname
	r := new_reader()
	defer {
		r.free()
	}
	r.support_filter_all()!
	r.support_format_all()!
	r.open_memory(buf)!

	entry := r.next_header() or {
		assert false, 'should have entry with long pathname'
		return
	}
	got_path := entry.pathname()
	assert got_path == long_name, 'expected full ${long_name.len}-char pathname, got ${got_path.len} chars'
}
