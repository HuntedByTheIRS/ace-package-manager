module zlib

import vibarchive.archive

// C function declarations using voidptr to avoid type conflicts
// with archive module's private C types. Linked via archive's #flag -larchive.
fn C.archive_write_set_format_raw(voidptr) i32
fn C.archive_error_string(voidptr) &char
fn C.archive_entry_set_pathname(voidptr, &char)
fn C.archive_entry_set_size(voidptr, i64)
fn C.archive_entry_set_filetype(voidptr, u32)
fn C.archive_entry_set_perm(voidptr, u32)
@[keep_args_alive]
fn C.archive_write_open_memory(voidptr, voidptr, u64, &u64) i32

// Mirror struct to extract private .inner from ArchiveWriter (first field at offset 0).
struct ZlibWriterInner { inner voidptr }

// Mirror struct to extract private .inner from ArchiveEntry (first field at offset 0).
struct ZlibEntryInner { inner voidptr }

// check maps a libarchive status code to a V error.
fn check(inner voidptr, code i32) ! {
	if code == 0 || code == 1 { return }
	msg := unsafe { cstring_to_vstring(C.archive_error_string(inner)) }
	return error('libarchive (${code}): ${msg}')
}

// compress compresses data using raw deflate with gzip filter wrapping,
// approximating zlib (RFC 1950) compression via libarchive.
pub fn compress(data []u8) ![]u8 {
	w := archive.new_writer()
	w.add_filter_gzip()!
	w_inner := unsafe { (&ZlibWriterInner(voidptr(w))).inner }
	check(w_inner, C.archive_write_set_format_raw(w_inner))!

	buf_size := data.len * 2 + 64
	mut out_buf := []u8{len: buf_size}
	mut used := u64(0)
	check(w_inner, C.archive_write_open_memory(w_inner, out_buf.data, u64(out_buf.len), &used))!

	e := archive.new_entry()
	e_inner := unsafe { (&ZlibEntryInner(voidptr(e))).inner }
	C.archive_entry_set_pathname(e_inner, 'data'.str)
	C.archive_entry_set_size(e_inner, i64(data.len))
	C.archive_entry_set_filetype(e_inner, u32(archive.ae_ifreg))
	C.archive_entry_set_perm(e_inner, u32(0o644))

	w.write_header(e)!
	w.write_data(data)!
	w.finish_entry()!
	w.close()!
	e.free()
	w.free()

	out_buf.trim(int(used))
	return out_buf
}

// decompress decompresses zlib-compressed data produced by compress.
pub fn decompress(data []u8) ![]u8 {
	r := archive.new_reader()
	defer { r.free() }
	r.support_filter_all()!
	r.support_format_all()!
	r.open_memory(data)!

	entry := r.next_header()!
	entry_size := int(entry.size())
	mut out_buf := []u8{len: entry_size}
	n := r.read_data(mut out_buf)!
	if n != i64(entry_size) {
		return error('zlib: incomplete read during decompression')
	}
	return out_buf
}

// new_zlib_reader opens a zlib-compressed file for reading.
// Caller must call .free() on the returned reader when done.
pub fn new_zlib_reader(path string) !&archive.ArchiveReader {
	r := archive.new_reader()
	r.support_filter_all()!
	r.support_format_all()!
	r.open_file(path)!
	return r
}

// new_zlib_writer creates a zlib-compressed file for writing.
// Caller must call .close() and .free() on the returned writer when done.
pub fn new_zlib_writer(path string) !&archive.ArchiveWriter {
	w := archive.new_writer()
	w.add_filter_gzip()!
	w_inner := unsafe { (&ZlibWriterInner(voidptr(w))).inner }
	check(w_inner, C.archive_write_set_format_raw(w_inner))!
	w.open_file(path)!
	return w
}
