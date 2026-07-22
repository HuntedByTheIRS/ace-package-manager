module deflate

import vibarchive.archive

#flag -larchive
#include "archive.h"
#include "archive_entry.h"

// C.memcpy for reading inner pointers (fields are not pub from outside the archive module).
fn C.memcpy(voidptr, voidptr, u64) voidptr

// C function declarations with voidptr — C.struct_archive is scoped to the archive
// module and inaccessible from here; voidptr bridges the type gap.
fn C.archive_write_set_format_raw(voidptr) i32
fn C.archive_write_open_memory(voidptr, voidptr, u64, &u64) i32
fn C.archive_read_support_format_raw(voidptr) i32
fn C.archive_read_support_filter_none(voidptr) i32
fn C.archive_error_string(voidptr) &char
fn C.archive_entry_set_pathname(voidptr, &char)
fn C.archive_entry_set_size(voidptr, i64)
fn C.archive_entry_set_filetype(voidptr, u32)
fn C.archive_entry_set_perm(voidptr, u32)

// writer_inner reads the inner `&C.struct_archive` field (offset 0) from an ArchiveWriter
// via C.memcpy. The field is not pub, so this is the only way to get the C handle
// from outside the archive module.
fn writer_inner(w &archive.ArchiveWriter) voidptr {
	mut p := unsafe { nil }
	unsafe { C.memcpy(&p, w, u64(sizeof(voidptr))) }
	return p
}

// reader_inner reads the inner `&C.struct_archive` field (offset 0) from an ArchiveReader.
fn reader_inner(r &archive.ArchiveReader) voidptr {
	mut p := unsafe { nil }
	unsafe { C.memcpy(&p, r, u64(sizeof(voidptr))) }
	return p
}

// entry_inner reads the inner `&C.struct_archive_entry` field (offset 0) from an ArchiveEntry.
fn entry_inner(e &archive.ArchiveEntry) voidptr {
	mut p := unsafe { nil }
	unsafe { C.memcpy(&p, e, u64(sizeof(voidptr))) }
	return p
}

// check_result maps a libarchive status code to a V error for the deflate module.
// Mirrors archive.check_result but takes voidptr instead of &C.struct_archive.
fn check_result(a voidptr, code i32) ! {
	if code == archive.archive_ok || code == archive.archive_eof {
		return
	}
	msg := unsafe { cstring_to_vstring(C.archive_error_string(a)) }
	return error('libarchive (${code}): ${msg}')
}

// check_call calls a C libarchive function that returns an i32 status code,
// and checks the result against archive_ok / archive_eof.
fn check_call(a voidptr, code i32) ! {
	check_result(a, code)!
}

// new_deflate_writer creates a new ArchiveWriter configured for raw deflate output.
// Uses raw format with no compression wrapping — libarchive's raw format
// handles the raw deflate stream; the caller provides already-compressed data.
pub fn new_deflate_writer(path string) !&archive.ArchiveWriter {
	w := archive.new_writer()
	w.add_filter_none()!
	inner := writer_inner(w)
	check_call(inner, C.archive_write_set_format_raw(inner))!
	w.open_file(path)!
	return w
}

// new_deflate_reader creates a new ArchiveReader configured for raw deflate input.
pub fn new_deflate_reader(path string) !&archive.ArchiveReader {
	r := archive.new_reader()
	inner := reader_inner(r)
	check_call(inner, C.archive_read_support_format_raw(inner))!
	check_call(inner, C.archive_read_support_filter_none(inner))!
	r.open_file(path)!
	return r
}

// compress writes data as a single raw deflate entry into a byte buffer.
// Uses raw format with no filter — data passes through uncompressed.
pub fn compress(data []u8) ![]u8 {
	if data.len == 0 {
		return []u8{}
	}
	w := archive.new_writer()
	w.add_filter_none()!
	w_inner := writer_inner(w)
	check_call(w_inner, C.archive_write_set_format_raw(w_inner))!

	// Use direct C open_memory to track bytes written (the V wrapper discards `used`).
	mut buf := []u8{len: data.len + 4096}
	mut used := u64(0)
	check_call(w_inner, C.archive_write_open_memory(w_inner, buf.data, u64(buf.len), &used))!

	e := archive.new_entry()
	e_inner := entry_inner(e)
	C.archive_entry_set_pathname(e_inner, c'data')
	C.archive_entry_set_size(e_inner, i64(data.len))
	C.archive_entry_set_filetype(e_inner, u32(archive.ae_ifreg))
	C.archive_entry_set_perm(e_inner, u32(0o644))
	w.write_header(e)!
	_ := w.write_data(data)!
	w.finish_entry()!
	e.free()
	w.close()!
	w.free()

	return buf[..int(used)]
}

// decompress reads the first entry from raw deflate data and returns its content.
// Raw format does not provide entry sizes — data is read in chunks until EOF.
pub fn decompress(data []u8) ![]u8 {
	if data.len == 0 {
		return []u8{}
	}
	mut r := archive.new_reader()
	r_inner := reader_inner(r)
	check_call(r_inner, C.archive_read_support_format_raw(r_inner))!
	check_call(r_inner, C.archive_read_support_filter_none(r_inner))!
	r.open_memory(data)!

	_ := r.next_header()!
	mut result := []u8{}
	mut buf := []u8{len: 4096}
	for {
		n := r.read_data(mut buf)!
		if n == 0 {
			break
		}
		result << buf[..int(n)]
	}
	r.free()
	return result
}
