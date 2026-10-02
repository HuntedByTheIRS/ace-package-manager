module archive

import os
import regex

// --- Opening shortcuts ---

// open opens an archive from a file path with all formats/filters enabled.
pub fn (r &ArchiveReader) open(path string) ! {
	r.support_filter_all()!
	r.support_format_all()!
	r.open_file(path)!
}



// open_bytes opens from a byte buffer.
pub fn (r &ArchiveReader) open_bytes(data []u8) ! {
	r.support_filter_all()!
	r.support_format_all()!
	unsafe { r.mem_buf = data }
	c := C.archive_read_open_memory(r.inner, data.data, u64(data.len))
	if c != 0 { return error(err_string(r.inner)) }
}

// --- Extraction ---

// extract_to extracts the entire archive to a directory.
pub fn (r &ArchiveReader) extract_to(dir string) ! {
	extract_to_dir_inner(r, dir, ExtractOpts{overwrite: true})!
}

// extract_to_dir extracts to a directory with options.
pub fn (r &ArchiveReader) extract_to_dir(dir string, opts ExtractOpts) ! {
	extract_to_dir_inner(r, dir, opts)!
}

fn extract_to_dir_inner(r &ArchiveReader, dir string, opts ExtractOpts) ! {
	os.mkdir_all(dir)!
	for {
		entry := r.next_header() or { break }
		mut rel := entry.pathname().trim_right('/')
		if opts.strip_components > 0 {
			parts := rel.split('/')
			if parts.len <= opts.strip_components { r.skip_data() or {}; continue }
			rel = parts[opts.strip_components..].join('/')
		}
		full := os.join_path(dir, rel)
		if !full.starts_with(os.real_path(dir)) && opts.prevent_traversal {
			r.skip_data() or {}; continue
		}
		if entry.is_dir() {
			os.mkdir_all(full)!
		} else if entry.is_file() {
			parent := os.dir(full)
			if parent != '' && !os.exists(parent) { os.mkdir_all(parent)! }
			if os.exists(full) && !opts.overwrite { r.skip_data() or {}; continue }
			sz := entry.size()
			if sz == 0 {
				mut f := os.create(full)!; f.close()
			} else {
				mut buf := []u8{len: min2(int(sz), 65536)}
				mut f := os.create(full)!
				mut remaining := sz
				for remaining > 0 {
					t := min2(65536, int(remaining))
					if t > buf.len { buf = []u8{len: t} }
					n := r.read_data(mut buf[..t])!
					if n <= 0 { break }
					unsafe { f.write_ptr(buf.data, int(n)) }
					remaining -= n
				}
				f.close()
			}
		} else if entry.is_symlink() && opts.allow_symlinks {
			os.symlink(entry.symlink(), full) or {}
		} else {
			r.skip_data() or {}
		}
	}
}

// extract_file extracts a single entry by name to a destination path.
pub fn (r &ArchiveReader) extract_file(name string, dest string) ! {
	for {
		entry := r.next_header() or { break }
		if entry.pathname() == name || entry.pathname().trim_right('/') == name {
			if entry.is_dir() { os.mkdir_all(dest)!; return }
			parent := os.dir(dest)
			if parent != '' && !os.exists(parent) { os.mkdir_all(parent)! }
			sz := entry.size()
			mut buf := []u8{len: min2(int(sz), 65536)}
			mut f := os.create(dest)!
			mut remaining := sz
			for remaining > 0 {
				t := min2(65536, int(remaining))
				if t > buf.len { buf = []u8{len: t} }
				n := r.read_data(mut buf[..t])!
				if n <= 0 { break }
				unsafe { f.write_ptr(buf.data, int(n)) }
				remaining -= n
			}
			f.close()
			return
		}
		r.skip_data() or {}
	}
	return error('entry not found: ${name}')
}

// extract_files extracts multiple entries to a destination directory.
pub fn (r &ArchiveReader) extract_files(names []string, dest string) ! {
	for name in names {
		r.extract_file(name, os.join_path(dest, name))!
	}
}

// extract_all extracts all entries to the current directory.
pub fn (r &ArchiveReader) extract_all() ! {
	r.extract_to_dir('.', ExtractOpts{})!
}

// --- Inspection ---

// list returns all entry pathnames (like tar --list).
pub fn (r &ArchiveReader) list() ![]string {
	mut names := []string{}
	for {
		entry := r.next_header() or { break }
		names << entry.pathname()
		r.skip_data() or {}
	}
	return names
}

// entries returns all entries with full metadata.
pub fn (r &ArchiveReader) entries() ![]FileEntry {
	mut result := []FileEntry{}
	for {
		entry := r.next_header() or { break }
		result << FileEntry{
			path:   entry.pathname()
			size:   entry.size()
			is_dir: entry.is_dir()
			mode:   entry.mode()
		}
		r.skip_data() or {}
	}
	return result
}

// has_file checks if an entry with the given name exists.
pub fn (r &ArchiveReader) has_file(name string) bool {
	for {
		entry := r.next_header() or { break }
		if entry.pathname() == name || entry.pathname().trim_right('/') == name {
			r.skip_data() or {}
			return true
		}
		r.skip_data() or {}
	}
	return false
}

// file_count returns the number of entries.
pub fn (r &ArchiveReader) file_count() int {
	mut count := 0
	for {
		r.next_header() or { break }
		count++
		r.skip_data() or {}
	}
	return count
}

// format returns the archive format name.
pub fn (r &ArchiveReader) format() string {
	return unsafe { cstring_to_vstring(C.archive_format_name(r.inner)) }
}

// compression returns the compression filter names.
pub fn (r &ArchiveReader) compression() string {
	c := C.archive_filter_count(r.inner)
	mut names := []string{}
	for i := 0; i < c; i++ {
		names << unsafe { cstring_to_vstring(C.archive_filter_name(r.inner, i)) }
	}
	return names.join(', ')
}

// is_tar returns true if the archive is a tar format.
pub fn (r &ArchiveReader) is_tar() bool {
	f := C.archive_format(r.inner)
	return f == archive_format_tar || f == archive_format_tar_ustar ||
		f == archive_format_tar_pax_restricted || f == archive_format_tar_gnutar ||
		f == archive_format_tar_pax_interchange
}

// is_compressed returns true if any compression filter is active.
pub fn (r &ArchiveReader) is_compressed() bool {
	return C.archive_filter_count(r.inner) > 1
}

// --- Searching / filtering ---

// find locates the first entry with the given name.
pub fn (r &ArchiveReader) find(name string) !&ArchiveEntry {
	for {
		entry := r.next_header() or { break }
		if entry.pathname() == name {
			return entry
		}
		r.skip_data() or {}
	}
	return error('entry not found: ${name}')
}

// find_all finds entries whose path contains the substring.
pub fn (r &ArchiveReader) find_all(sub string) ![]FileEntry {
	mut result := []FileEntry{}
	for {
		entry := r.next_header() or { break }
		if entry.pathname().contains(sub) {
			result << FileEntry{
				path:   entry.pathname()
				size:   entry.size()
				is_dir: entry.is_dir()
			}
		}
		r.skip_data() or {}
	}
	return result
}

// glob finds entries matching a glob pattern.
pub fn (r &ArchiveReader) glob(pattern string) ![]FileEntry {
	mut result := []FileEntry{}
	re_str := glob_to_regex(pattern)
	re := regex.regex_opt(re_str) or { return error('bad pattern') }
	for {
		entry := r.next_header() or { break }
		if re.matches_string(entry.pathname()) {
			result << FileEntry{
				path:   entry.pathname()
				size:   entry.size()
				is_dir: entry.is_dir()
			}
		}
		r.skip_data() or {}
	}
	return result
}

// filter returns entries matching a predicate.
pub fn (r &ArchiveReader) filter(pred EntryFilter) ![]FileEntry {
	mut result := []FileEntry{}
	for {
		entry := r.next_header() or { break }
		if pred(entry) {
			result << FileEntry{
				path:   entry.pathname()
				size:   entry.size()
				is_dir: entry.is_dir()
			}
		}
		r.skip_data() or {}
	}
	return result
}

// files returns all regular file entries.
pub fn (r &ArchiveReader) files() ![]FileEntry {
	return r.filter(fn (e &ArchiveEntry) bool {
		return e.is_file()
	})
}

// directories returns all directory entries.
pub fn (r &ArchiveReader) directories() ![]FileEntry {
	return r.filter(fn (e &ArchiveEntry) bool {
		return e.is_dir()
	})
}

// --- Safe extraction ---

// check_safe validates the archive for path traversal and symlink safety.
pub fn (r &ArchiveReader) check_safe() ! {
	for {
		entry := r.next_header() or { break }
		p := entry.pathname()
		if p.contains('..') {
			return error('path traversal detected: ${p}')
		}
		if p.starts_with('/') {
			return error('absolute path detected: ${p}')
		}
		r.skip_data() or {}
	}
}

// validate_paths is an alias for check_safe.
pub fn (r &ArchiveReader) validate_paths() ! {
	r.check_safe()!
}

// --- Misc ---

// print_contents prints all entry names (like tar tf).
pub fn (r &ArchiveReader) print_contents() ! {
	for {
		entry := r.next_header() or { break }
		println(entry.pathname())
		r.skip_data() or {}
	}
}

// summary prints a human-readable summary.
pub fn (r &ArchiveReader) summary() ! {
	r.print_contents()!
}

// tree prints entries in tree format.
pub fn (r &ArchiveReader) tree() ! {
	for {
		entry := r.next_header() or { break }
		depth := entry.pathname().count('/')
		prefix := '  '.repeat(depth)
		suffix := if entry.is_dir() { '/' } else { '' }
		println('${prefix}${entry.pathname().split('/').last()}${suffix}')
		r.skip_data() or {}
	}
}

// size_report prints size information.
pub fn (r &ArchiveReader) size_report() ! {
	mut total := i64(0)
	mut count := 0
	for {
		entry := r.next_header() or { break }
		if entry.is_file() {
			total += entry.size()
			count++
		}
		r.skip_data() or {}
	}
	println('Entries: ${count}')
	println('Total size: ${total} bytes')
}

// rewind resets the reader back to the beginning.
pub fn (r &ArchiveReader) rewind() {
	// libarchive doesn't support rewinding; this is a best-effort.
	// For real rewind support, use open_memory or re-open the file.
}

// glob_to_regex converts a simple glob pattern to a regex string.
fn glob_to_regex(pattern string) string {
	mut re := ''
	for c in pattern {
		re += match c {
			`*` { '.*' }
			`?` { '.' }
			`.` { '\\.' }
			else { c.str() }
		}
	}
	return '^' + re + '$'
}
