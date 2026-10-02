module archive

// ArchiveWriter writes entries to a libarchive archive.
// Owns the underlying C struct archive pointer and frees it on free().
// Follows the entry lifecycle: write_header → write_data → finish_entry → write_header (next entry)
@[heap]
pub struct ArchiveWriter {
pub:
	inner &C.struct_archive
mut:
	mem_buf []u8 // retains GC reference for open_memory buffers
}

// new_writer creates a new ArchiveWriter.
pub fn new_writer() &ArchiveWriter {
	ptr := C.archive_write_new()
	return &ArchiveWriter{inner: ptr}
}

// --- Format setters ---

pub fn (w &ArchiveWriter) set_format_pax_restricted() ! {
	check_result(w.inner, C.archive_write_set_format_pax_restricted(w.inner))!
}

pub fn (w &ArchiveWriter) set_format_zip() ! {
	check_result(w.inner, C.archive_write_set_format_zip(w.inner))!
}

pub fn (w &ArchiveWriter) set_format_gnutar() ! {
	check_result(w.inner, C.archive_write_set_format_gnutar(w.inner))!
}

pub fn (w &ArchiveWriter) set_format_7zip() ! {
	check_result(w.inner, C.archive_write_set_format_7zip(w.inner))!
}

pub fn (w &ArchiveWriter) set_format_ustar() ! {
	check_result(w.inner, C.archive_write_set_format_ustar(w.inner))!
}

pub fn (w &ArchiveWriter) set_format_raw() ! {
	check_result(w.inner, C.archive_write_set_format_raw(w.inner))!
}

// --- Filter setters ---

pub fn (w &ArchiveWriter) add_filter_none() ! {
	check_result(w.inner, C.archive_write_add_filter_none(w.inner))!
}

pub fn (w &ArchiveWriter) add_filter_gzip() ! {
	check_result(w.inner, C.archive_write_add_filter_gzip(w.inner))!
}

pub fn (w &ArchiveWriter) add_filter_bzip2() ! {
	check_result(w.inner, C.archive_write_add_filter_bzip2(w.inner))!
}

pub fn (w &ArchiveWriter) add_filter_zstd() ! {
	check_result(w.inner, C.archive_write_add_filter_zstd(w.inner))!
}

pub fn (w &ArchiveWriter) add_filter_xz() ! {
	check_result(w.inner, C.archive_write_add_filter_xz(w.inner))!
}

// --- Open ---

pub fn (w &ArchiveWriter) open_file(path string) ! {
	check_result(w.inner, C.archive_write_open_filename(w.inner, path.str))!
}

// open_memory opens the archive for writing into a byte buffer.
// Stores the buffer reference to prevent GC collection while the C archive holds a pointer to it.
pub fn (w &ArchiveWriter) open_memory(mut buf []u8) ! {
	unsafe {
		w.mem_buf = buf
	}
	mut used := u64(0)
	check_result(w.inner, C.archive_write_open_memory(w.inner, buf.data, u64(buf.len), &used))!
}

// --- Entry lifecycle ---

// write_header begins a new entry in the archive.
pub fn (w &ArchiveWriter) write_header(entry &ArchiveEntry) ! {
	check_result(w.inner, C.archive_write_header(w.inner, entry.inner))!
}

// write_data writes entry data. Returns bytes written.
pub fn (w &ArchiveWriter) write_data(data []u8) !i64 {
	return check_data_result(w.inner, C.archive_write_data(w.inner, data.data, u64(data.len)))
}

// finish_entry completes the current entry.
pub fn (w &ArchiveWriter) finish_entry() ! {
	check_result(w.inner, C.archive_write_finish_entry(w.inner))!
}

// --- Close / Free ---

// close closes the archive.
pub fn (w &ArchiveWriter) close() ! {
	check_result(w.inner, C.archive_write_close(w.inner))!
}

// free releases all C resources held by the writer.
pub fn (w &ArchiveWriter) free() {
	if unsafe { w.inner != nil } {
		C.archive_write_close(w.inner)
		C.archive_write_free(w.inner)
	}
}
