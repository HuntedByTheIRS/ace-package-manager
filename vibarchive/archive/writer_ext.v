module archive

import os

// --- Creation ---

// create creates an archive at the given path, auto-detecting format from the extension.
pub fn (w &ArchiveWriter) create(path string) ! {
	if path.ends_with('.tar.gz') || path.ends_with('.tgz') {
		w.add_filter_gzip()!
		w.set_format_pax_restricted()!
	} else if path.ends_with('.tar.bz2') {
		w.add_filter_bzip2()!
		w.set_format_pax_restricted()!
	} else if path.ends_with('.tar.zst') {
		C.archive_write_add_filter_zstd(w.inner)
		w.set_format_pax_restricted()!
	} else if path.ends_with('.tar.xz') {
		C.archive_write_add_filter_xz(w.inner)
		w.set_format_pax_restricted()!
	} else if path.ends_with('.zip') {
		w.set_format_zip()!
	} else if path.ends_with('.tar') {
		w.set_format_pax_restricted()!
	} else {
		w.add_filter_gzip()!
		w.set_format_pax_restricted()!
	}
	w.open_file(path)!
}

// create_bytes opens a memory buffer for writing.
pub fn (w &ArchiveWriter) create_bytes(mut buf []u8) ! {
	w.open_memory(mut buf)!
}

// --- Adding entries ---

// add_file reads a file from disk and adds it as an entry.
pub fn (w &ArchiveWriter) add_file(path string) ! {
	data := os.read_bytes(path) or { return error('cannot read ${path}') }
	name := os.file_name(path)
	w.add_bytes(name, data)!
}

// add_file_as adds a file with a custom entry name.
pub fn (w &ArchiveWriter) add_file_as(source string, name string) ! {
	data := os.read_bytes(source) or { return error('cannot read ${source}') }
	w.add_bytes(name, data)!
}

// add_bytes adds a raw byte buffer as an entry.
pub fn (w &ArchiveWriter) add_bytes(name string, data []u8) ! {
	e := new_entry()
	C.archive_entry_set_pathname(e.inner, name.str)
	C.archive_entry_set_size(e.inner, i64(data.len))
	C.archive_entry_set_filetype(e.inner, u32(ae_ifreg))
	C.archive_entry_set_perm(e.inner, u32(0o644))
	w.write_header(e)!
	if data.len > 0 {
		w.write_data(data)!
	}
	w.finish_entry()!
	e.free()
}

// add_directory adds a directory entry.
pub fn (w &ArchiveWriter) add_directory(name string) ! {
	entry_name := if name.ends_with('/') { name } else { name + '/' }
	e := new_entry()
	C.archive_entry_set_pathname(e.inner, entry_name.str)
	C.archive_entry_set_size(e.inner, 0)
	C.archive_entry_set_filetype(e.inner, u32(ae_ifdir))
	C.archive_entry_set_perm(e.inner, u32(0o755))
	w.write_header(e)!
	w.finish_entry()!
	e.free()
}

// --- Settings ---

// set_compression configures the compression filter.
pub fn (w &ArchiveWriter) set_compression(c Compression) ! {
	match c {
		.none { C.archive_write_add_filter_none(w.inner) }
		.gzip { C.archive_write_add_filter_gzip(w.inner) }
		.bzip2 { C.archive_write_add_filter_bzip2(w.inner) }
		.zstd { C.archive_write_add_filter_zstd(w.inner) }
		.xz { C.archive_write_add_filter_xz(w.inner) }
		.lz4 { C.archive_write_add_filter_lz4(w.inner) }
		.lzma { C.archive_write_add_filter_lzma(w.inner) }
	}
}

// set_format configures the archive format.
pub fn (w &ArchiveWriter) set_format(f ArchiveFormat) ! {
	match f {
		.tar { w.set_format_pax_restricted()! }
		.tar_gz { w.set_format_pax_restricted()! }
		.tar_bz2 { w.set_format_pax_restricted()! }
		.tar_zst { w.set_format_pax_restricted()! }
		.tar_xz { w.set_format_pax_restricted()! }
		.zip { w.set_format_zip()! }
		.raw { w.set_format_raw()! }
		.seven_zip { w.set_format_7zip()! }
	}
}

