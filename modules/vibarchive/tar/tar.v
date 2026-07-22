module tar

import vibarchive.archive

// new_tar_reader opens a tar file for reading (no compression).
pub fn new_tar_reader(path string) !&archive.ArchiveReader {
	r := archive.new_reader()
	r.support_format_all()!
	r.open_file(path)!
	return r
}

// new_tar_writer opens a tar file for writing (no compression).
pub fn new_tar_writer(path string) !&archive.ArchiveWriter {
	w := archive.new_writer()
	w.add_filter_none()!
	w.set_format_pax_restricted()!
	w.open_file(path)!
	return w
}

// read_tar_file reads a tar file and calls the callback for each entry.
pub fn read_tar_file(path string, mut cb archive.Reader) ! {
	r := new_tar_reader(path)!
	archive.read_archive_callback(r, mut cb)!
	r.free()
}

// new_debug_reader returns a DebugReader for inspecting tar archives.
pub fn new_debug_reader() archive.DebugReader {
	return archive.DebugReader{}
}
