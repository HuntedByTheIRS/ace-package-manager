module snappy

import vibarchive.archive

#flag -larchive
#include "archive_entry.h"

pub struct C.struct_archive_entry {}

fn C.archive_entry_set_pathname(&C.struct_archive_entry, &char)
fn C.archive_entry_set_size(&C.struct_archive_entry, i64)
fn C.archive_entry_set_filetype(&C.struct_archive_entry, u32)
fn C.archive_entry_set_perm(&C.struct_archive_entry, u32)

// compress wraps data in an uncompressed tar archive and returns the result.
// Uses add_filter_none because libarchive has no dedicated snappy filter.
pub fn compress(data []u8) ![]u8 {
	mut buf := []u8{len: data.len + 4096}
	w := archive.new_writer()
	defer {
		w.free()
	}
	w.add_filter_none()!
	w.set_format_pax_restricted()!
	w.open_memory(mut buf)!
	e := archive.new_entry()
	defer {
		e.free()
	}
	C.archive_entry_set_pathname(e.inner, 'data'.str)
	C.archive_entry_set_size(e.inner, i64(data.len))
	C.archive_entry_set_filetype(e.inner, u32(archive.ae_ifreg))
	C.archive_entry_set_perm(e.inner, u32(0o644))
	w.write_header(e)!
	w.write_data(data)!
	w.finish_entry()!
	w.close()!
	return buf
}

// decompress extracts data from an uncompressed tar archive and returns the original bytes.
pub fn decompress(data []u8) ![]u8 {
	reader := archive.new_reader()
	defer {
		reader.free()
	}
	reader.support_filter_all()!
	reader.support_format_all()!
	reader.open_memory(data)!
	entry := reader.next_header()!
	mut result := []u8{len: int(entry.size())}
	n := reader.read_data(mut result)!
	_ = n
	return result
}

// new_snappy_reader creates an ArchiveReader configured for reading from a file.
pub fn new_snappy_reader(path string) !&archive.ArchiveReader {
	reader := archive.new_reader()
	reader.support_filter_all()!
	reader.support_format_all()!
	reader.open_file(path)!
	return reader
}

// new_snappy_writer creates an ArchiveWriter configured for writing to a file.
pub fn new_snappy_writer(path string) !&archive.ArchiveWriter {
	w := archive.new_writer()
	w.add_filter_none()!
	w.set_format_pax_restricted()!
	w.open_file(path)!
	return w
}
