module gzip

import vibarchive.archive

// C function declarations needed for entry manipulation.
// These mirror declarations in archive/c.v and are linked
// against libarchive via the project's #flag -larchive.
fn C.archive_entry_set_pathname(&C.struct_archive_entry, &char)
fn C.archive_entry_set_size(&C.struct_archive_entry, i64)
fn C.archive_entry_set_filetype(&C.struct_archive_entry, u32)
fn C.archive_entry_set_perm(&C.struct_archive_entry, u32)
fn C.archive_read_support_format_raw(&C.struct_archive) i32
fn C.archive_read_support_format_empty(&C.struct_archive) i32
fn C.archive_write_open_memory(&C.struct_archive, voidptr, u64, &u64) i32

// compress compresses data using gzip compression (raw gzip stream, not tar).
pub fn compress(data []u8) ![]u8 {
	mut buf := []u8{len: data.len + 65536}
	mut used := u64(0)

	w := archive.new_writer()
	w.add_filter_gzip()!
	w.set_format_raw()!
	// Use C function directly to capture exact bytes written via used parameter
	check_result(w.inner, C.archive_write_open_memory(w.inner, buf.data, u64(buf.len), &used))!

	e := archive.new_entry()
	C.archive_entry_set_pathname(e.inner, 'data'.str)
	C.archive_entry_set_size(e.inner, i64(data.len))
	C.archive_entry_set_filetype(e.inner, u32(archive.ae_ifreg))
	C.archive_entry_set_perm(e.inner, 0o644)
	w.write_header(e)!
	w.write_data(data)!
	w.finish_entry()!
	w.close()!
	w.free()

	return buf[..int(used)]
}

fn check_result(_ &C.struct_archive, code i32) ! {
	if code == 0 {
		return
	}
	return error('libarchive error: ${code}')
}

// decompress decompresses gzip-compressed data.
pub fn decompress(data []u8) ![]u8 {
	r := archive.new_reader()
	r.support_filter_all()!
	C.archive_read_support_format_raw(r.inner)
	r.open_memory(data)!
	r.next_header()!

	mut out := []u8{len: data.len * 4} // generous buffer for uncompressed data
	n := C.archive_read_data(r.inner, out.data, u64(out.len))
	r.free()

	if n <= 0 {
		return error('libarchive: gzip decompress failed')
	}
	return out[..int(n)]
}

// new_gzip_reader creates an ArchiveReader pre-configured for gzip-compressed archives.
pub fn new_gzip_reader(path string) !&archive.ArchiveReader {
	r := archive.new_reader()
	r.support_filter_all()!
	r.support_format_all()!
	r.open_file(path)!
	return r
}

// new_gzip_writer creates an ArchiveWriter pre-configured for gzip-compressed tar archives.
pub fn new_gzip_writer(path string) !&archive.ArchiveWriter {
	w := archive.new_writer()
	w.add_filter_gzip()!
	w.set_format_pax_restricted()!
	w.open_file(path)!
	return w
}
