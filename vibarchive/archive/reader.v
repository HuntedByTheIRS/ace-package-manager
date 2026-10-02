module archive



// ArchiveReader reads entries from a libarchive archive.
// Owns the underlying C struct archive pointer and frees it on free().
// When opened from memory, retains the buffer in mem_buf to prevent GC collection.
@[heap]
pub struct ArchiveReader {
pub:
	inner &C.struct_archive
mut:
	mem_buf []u8 // retains GC reference for open_memory buffers
}

// new_reader creates a new ArchiveReader with all format and filter support enabled.
pub fn new_reader() &ArchiveReader {
	ptr := C.archive_read_new()
	return &ArchiveReader{inner: ptr}
}

// support_format_all enables all available format handlers.
pub fn (r &ArchiveReader) support_format_all() ! {
	check_result(r.inner, C.archive_read_support_format_all(r.inner))!
}

// support_filter_all enables all available filter handlers.
pub fn (r &ArchiveReader) support_filter_all() ! {
	check_result(r.inner, C.archive_read_support_filter_all(r.inner))!
}

// open_file opens an archive from a file path.
pub fn (r &ArchiveReader) open_file(path string) ! {
	check_result(r.inner, C.archive_read_open_filename(r.inner, path.str, u64(10240)))!
}

// open_memory opens an archive from a byte buffer.
// Stores the buffer reference in ArchiveReader.mem_buf to prevent GC collection
// while the C archive holds a pointer to it.
pub fn (r &ArchiveReader) open_memory(data []u8) ! {
	unsafe {
		r.mem_buf = data
	}
	check_result(r.inner, C.archive_read_open_memory(r.inner, data.data, u64(data.len)))!
}

// next_header reads the next entry header from the archive.
// Returns a pointer to an ArchiveEntry, or an error at end of archive.
pub fn (r &ArchiveReader) next_header() !&ArchiveEntry {
	entry_ptr := unsafe { &C.struct_archive_entry(nil) }
	code := C.archive_read_next_header(r.inner, &entry_ptr)
	if code == archive_eof {
		return error('end of archive')
	}
	if code != archive_ok {
		return error(err_string(r.inner))
	}
	return &ArchiveEntry{inner: entry_ptr}
}

// read_data reads entry data into the provided buffer.
// Returns the number of bytes read (0 at end of entry data).
pub fn (r &ArchiveReader) read_data(mut buf []u8) !i64 {
	return check_data_result(r.inner, C.archive_read_data(r.inner, buf.data, u64(buf.len)))
}

// skip_data skips the current entry's data entirely.
pub fn (r &ArchiveReader) skip_data() ! {
	check_result(r.inner, C.archive_read_data_skip(r.inner))!
}

// close closes the archive.
pub fn (r &ArchiveReader) close() ! {
	check_result(r.inner, C.archive_read_close(r.inner))!
}

// free releases all C resources held by the reader.
pub fn (r &ArchiveReader) free() {
	if unsafe { r.inner != nil } {
		C.archive_read_close(r.inner)
		C.archive_read_free(r.inner)
		unsafe {
			r.mem_buf = []
		}
	}
}
