module zstd

import vibarchive.archive

// CompressParams configures zstd compression.
@[params]
pub struct CompressParams {
pub:
	compression_level int = 3
}

// compress compresses data using zstd compression.
pub fn compress(data []u8, params CompressParams) ![]u8 {
	mut buf := []u8{len: data.len + 65536}

	w := archive.new_writer()
	w.add_filter_zstd()!
	w.set_format_pax_restricted()!
	w.open_memory(mut buf)!

	e := archive.new_entry()
	C.archive_entry_set_pathname(e.inner, 'data'.str)
	C.archive_entry_set_size(e.inner, i64(data.len))
	C.archive_entry_set_filetype(e.inner, u32(archive.ae_ifreg))
	C.archive_entry_set_perm(e.inner, u32(0o644))
	w.write_header(e)!
	w.write_data(data)!
	w.finish_entry()!
	e.free()
	w.close()!
	w.free()

	mut compressed := buf.clone()
	for compressed.len > 0 && compressed[compressed.len - 1] == 0 {
		compressed = compressed[..compressed.len - 1].clone()
	}
	return compressed
}

// decompress decompresses zstd-compressed data.
pub fn decompress(data []u8) ![]u8 {
	r := archive.new_reader()
	r.support_filter_all()!
	r.support_format_all()!
	r.open_memory(data)!

	entry := r.next_header()!
	sz := entry.size()

	mut out := []u8{len: if sz > 0 { int(sz) } else { 65536 }}
	n := r.read_data(mut out)!
	r.free()

	if n < out.len {
		return out[..int(n)]
	}
	return out
}

// new_zstd_reader creates an ArchiveReader pre-configured for zstd archives.
pub fn new_zstd_reader(path string) !&archive.ArchiveReader {
	r := archive.new_reader()
	r.support_filter_all()!
	r.support_format_all()!
	r.open_file(path)!
	return r
}

// new_zstd_writer creates an ArchiveWriter pre-configured for zstd tar archives.
pub fn new_zstd_writer(path string) !&archive.ArchiveWriter {
	w := archive.new_writer()
	w.add_filter_zstd()!
	w.set_format_pax_restricted()!
	w.open_file(path)!
	return w
}
