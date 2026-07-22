module lz

import vibarchive.archive

// Format specifies the LZ compression variant.
pub enum Format {
	lz4
	lzma
	xz
	lzip
	lzop
}

// set_filter_for_format adds the appropriate compression filter to the writer
// by calling the C archive_write_add_filter_* function directly.
fn set_filter_for_format(w &archive.ArchiveWriter, format Format) ! {
	code := match format {
		.lz4 { C.archive_write_add_filter_lz4(w.inner) }
		.lzma { C.archive_write_add_filter_lzma(w.inner) }
		.xz { C.archive_write_add_filter_xz(w.inner) }
		.lzip { C.archive_write_add_filter_lzip(w.inner) }
		.lzop { C.archive_write_add_filter_lzop(w.inner) }
	}
	archive.check_result(w.inner, code)!
}

// compress compresses data using the specified LZ compression variant.
pub fn compress(data []u8, format Format) ![]u8 {
	mut buf := []u8{len: data.len + 65536}
	w := archive.new_writer()
	defer {
		w.free()
	}
	set_filter_for_format(w, format)!
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

// decompress decompresses data compressed with any LZ compression variant.
// libarchive auto-detects the compression filter at read time.
pub fn decompress(data []u8, format Format) ![]u8 {
	_ = format
	r := archive.new_reader()
	defer {
		r.free()
	}
	r.support_filter_all()!
	r.support_format_all()!
	r.open_memory(data)!
	entry := r.next_header()!
	mut out := []u8{len: int(entry.size())}
	n := r.read_data(mut out)!
	_ = n
	return out
}

// --- Per-variant convenience functions ---

// compress_lz4 compresses data using LZ4.
pub fn compress_lz4(data []u8) ![]u8 {
	return compress(data, .lz4)
}

// decompress_lz4 decompresses LZ4-compressed data.
pub fn decompress_lz4(data []u8) ![]u8 {
	return decompress(data, .lz4)
}

// compress_lzma compresses data using LZMA.
pub fn compress_lzma(data []u8) ![]u8 {
	return compress(data, .lzma)
}

// decompress_lzma decompresses LZMA-compressed data.
pub fn decompress_lzma(data []u8) ![]u8 {
	return decompress(data, .lzma)
}

// compress_xz compresses data using XZ.
pub fn compress_xz(data []u8) ![]u8 {
	return compress(data, .xz)
}

// decompress_xz decompresses XZ-compressed data.
pub fn decompress_xz(data []u8) ![]u8 {
	return decompress(data, .xz)
}

// compress_lzip compresses data using lzip.
pub fn compress_lzip(data []u8) ![]u8 {
	return compress(data, .lzip)
}

// decompress_lzip decompresses lzip-compressed data.
pub fn decompress_lzip(data []u8) ![]u8 {
	return decompress(data, .lzip)
}

// compress_lzop compresses data using lzop.
pub fn compress_lzop(data []u8) ![]u8 {
	return compress(data, .lzop)
}

// decompress_lzop decompresses lzop-compressed data.
pub fn decompress_lzop(data []u8) ![]u8 {
	return decompress(data, .lzop)
}

// --- File-level reader/writer construction ---

// new_lz_reader creates an ArchiveReader pre-configured for reading LZ-compressed archives from a file.
// libarchive auto-detects the compression filter at read time.
pub fn new_lz_reader(path string, format Format) !&archive.ArchiveReader {
	_ = format
	r := archive.new_reader()
	r.support_filter_all()!
	r.support_format_all()!
	r.open_file(path)!
	return r
}

// new_lz_writer creates an ArchiveWriter pre-configured for writing LZ-compressed tar archives to a file.
pub fn new_lz_writer(path string, format Format) !&archive.ArchiveWriter {
	w := archive.new_writer()
	set_filter_for_format(w, format)!
	w.set_format_pax_restricted()!
	w.open_file(path)!
	return w
}
