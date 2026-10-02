module archive

import os

// extract_to_dir extracts the contents of an archive to a destination directory.
pub fn extract_to_dir(archive_path string, dest_dir string, opts ExtractOpts) ! {
	os.mkdir_all(dest_dir)!

	r := new_reader()
	r.support_filter_all()!
	r.support_format_all()!
	r.open_file(archive_path)!

	for {
		entry := r.next_header() or { break }
		rel_path := entry.pathname().trim_right('/')
		full_path := os.join_path(dest_dir, rel_path)

		if entry.is_dir() {
			os.mkdir_all(full_path)!
		} else if entry.is_symlink() {
			target := entry.symlink()
			if os.exists(full_path) {
				if !opts.overwrite { r.skip_data() or {}; continue }
				os.rm(full_path) or {}
			}
			os.symlink(target, full_path) or {}
		} else if entry.is_file() {
			parent := os.dir(full_path)
			if parent != '' && !os.exists(parent) {
				os.mkdir_all(parent)!
			}
			if os.exists(full_path) && !opts.overwrite {
				r.skip_data() or {}; continue
			}
			sz := entry.size()
			if sz == 0 {
				mut f := os.create(full_path)!
				f.close()
			} else {
				mut buf := []u8{len: min2(int(sz), 65536)}
				mut f := os.create(full_path)!
				mut remaining := sz
				for remaining > 0 {
					to_read := min2(65536, int(remaining))
					if to_read > buf.len { buf = []u8{len: to_read} }
					n := r.read_data(mut buf[..to_read])!
					if n <= 0 { break }
					unsafe { f.write_ptr(buf.data, int(n)) }
					remaining -= n
				}
				f.close()
			}
		} else {
			r.skip_data() or {}
		}
	}
	r.free()
}

// ls_archive lists the entries in an archive, similar to os.ls().
pub fn ls_archive(archive_path string) ![]FileEntry {
	mut entries := []FileEntry{}

	r := new_reader()
	r.support_filter_all()!
	r.support_format_all()!
	r.open_file(archive_path)!

	for {
		entry := r.next_header() or { break }
		entries << FileEntry{
			path:     entry.pathname().trim_right('/')
			size:     entry.size()
			is_dir:   entry.is_dir()
			is_file:  entry.is_file()
			is_link:  entry.is_symlink()
			mode:     entry.mode()
			uid:      entry.uid()
			gid:      entry.gid()
			mod_time: entry.mtime()
		}
		r.skip_data() or {}
	}
	r.free()

	return entries
}

fn min2(a int, b int) int {
	if a < b { return a }
	return b
}
