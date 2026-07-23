// Package archive metadata reader for .pkg.tar.* (Arch Linux packages).
//
// Parses .PKGINFO key=value metadata, extracts file lists, and detects
// .INSTALL/.CHANGELOG presence from a .pkg.tar.zst (or .gz, .xz, .lz4, etc.)
// archive using vibarchive (libarchive) for all I/O.
//
// Reference: pacman/lib/libalpm/be_package.c
module archive

import vibarchive.archive as va

// ------------------------------------------------------------------
// Internal helpers
// ------------------------------------------------------------------

// parse_i64 parses a decimal string to i64.  Non-digit characters stop
// parsing (safe — never panics, never returns an error).
fn parse_i64(s string) i64 {
	mut n := i64(0)
	for c in s {
		if c < `0` || c > `9` {
			break
		}
		n = n * 10 + i64(c - `0`)
	}
	return n
}

// read_entry_data reads all remaining data from the current archive entry
// and returns it as a byte slice.  The entry data is fully consumed.
fn read_entry_data(r &va.ArchiveReader, entry &va.ArchiveEntry) ![]u8 {
	sz := entry.size()
	if sz <= 0 {
		r.skip_data() or {}
		return []u8{}
	}
	mut data := []u8{len: 0, cap: int(sz)}
	mut buf := []u8{len: 8192}
	for {
		n := r.read_data(mut buf) or { break }
		if n <= 0 {
			break
		}
		data << buf[..n]
	}
	return data
}

// parse_pkginfo parses .PKGINFO key=value text (as raw bytes) into a
// Package struct.  Comment lines (starting with #) and blank lines are
// ignored.  Each line is split on the first '=' sign; both key and value
// are trimmed of surrounding whitespace.
fn parse_pkginfo(data []u8, mut pkg Package) {
	content := data.bytestr()
	for raw_line in content.split('\n') {
		ln := raw_line.trim_space()
		if ln == '' || ln.starts_with('#') {
			continue
		}
		eq_pos := ln.index('=') or { continue }
		key := ln[..eq_pos].trim_space()
		val := ln[eq_pos + 1..].trim_space()
		if key == '' || val == '' {
			continue
		}
		set_pkginfo_field(key, val, mut pkg)
	}
}

// set_pkginfo_field maps a single .PKGINFO key=value pair onto the
// corresponding field(s) of the Package struct.
fn set_pkginfo_field(key string, val string, mut pkg Package) {
	match key {
		'pkgname' {
			pkg.name = val
			pkg.name_hash = compute_name_hash(val)
		}
		'pkgbase' {
			pkg.base = val
		}
		'pkgver' {
			pkg.version = val
		}
		'pkgdesc' {
			pkg.desc = val
		}
		'url' {
			pkg.url = val
		}
		'builddate' {
			pkg.build_date = parse_i64(val)
		}
		'packager' {
			pkg.packager = val
		}
		'size' {
			pkg.isize = parse_i64(val)
		}
		'arch' {
			pkg.arch = val
		}
		'license' {
			pkg.licenses << val
		}
		'depend' {
			dep := Dependency{}.from_string(val) or { return }
			pkg.depends << dep
		}
		'optdepend' {
			// Format: "pkgname: description" — take just the name part
			dep_name := val.split(':')[0].trim_space()
			dep := Dependency{}.from_string(dep_name) or { return }
			pkg.optdepends << dep
		}
		'makedepend' {
			dep := Dependency{}.from_string(val) or { return }
			pkg.makedepends << dep
		}
		'checkdepend' {
			dep := Dependency{}.from_string(val) or { return }
			pkg.checkdepends << dep
		}
		'conflict' {
			dep := Dependency{}.from_string(val) or { return }
			pkg.conflicts << dep
		}
		'provides' {
			dep := Dependency{}.from_string(val) or { return }
			pkg.provides << dep
		}
		'replaces' {
			dep := Dependency{}.from_string(val) or { return }
			pkg.replaces << dep
		}
		'backup' {
			pkg.backup << BackupFile{
				name: val
				hash: ''
			}
		}
		'group' {
			pkg.groups << val
		}
		else {}
	}
}

// ------------------------------------------------------------------
// Public API
// ------------------------------------------------------------------

// load_pkg_metadata reads only .PKGINFO from a .pkg.tar.* archive and
// returns the resolved Package metadata.  Equivalent to `pacman -Qip`.
//
// The archive is opened with all format/filter support enabled (zst, gz,
// xz, lz4, bz2, …) via vibarchive.
pub fn load_pkg_metadata(path string) !Package {
	mut pkg := Package{
		origin: PackageOrigin.file
	}
	mut r := va.new_reader()
	r.open(path)!
	defer {
		r.free()
	}
	for {
		entry := r.next_header() or { break }
		if entry.pathname() == '.PKGINFO' {
			data := read_entry_data(r, entry)!
			parse_pkginfo(data, mut pkg)
			return pkg
		}
		r.skip_data() or {}
	}
	return pkg
}

// load_changelog reads the .CHANGELOG entry from a .pkg.tar.* archive and
// returns its contents as text.  Returns an error if the archive carries
// no changelog.  Equivalent to `pacman -Qcp <file>`.
pub fn load_changelog(path string) !string {
	mut r := va.new_reader()
	r.open(path)!
	defer {
		r.free()
	}
	for {
		entry := r.next_header() or { break }
		if entry.pathname() == '.CHANGELOG' {
			data := read_entry_data(r, entry)!
			return data.bytestr()
		}
		r.skip_data() or {}
	}
	return error('no changelog available')
}

// load_pkg_full reads the entire archive: metadata from .PKGINFO, filelist
// from all non-metadata entries, and flags such as scriptlet (.INSTALL).
//
// Metadata files (.BUILDINFO, .MTREE, .CHANGELOG) are skipped.  The
// presence of .INSTALL sets Package.scriptlet = true.
//
// The resulting file list (Package.files) includes every entry except the
// special metadata files listed above — files, directories, and symlinks
// are all recorded with their size and mode.
pub fn load_pkg_full(path string) !Package {
	mut pkg := Package{
		origin: PackageOrigin.file
	}
	mut r := va.new_reader()
	r.open(path)!
	defer {
		r.free()
	}
	for {
		entry := r.next_header() or { break }
		name := entry.pathname()
		if name == '.PKGINFO' {
			data := read_entry_data(r, entry)!
			parse_pkginfo(data, mut pkg)
		} else if name == '.INSTALL' {
			pkg.scriptlet = true
			r.skip_data() or {}
		} else if name == '.CHANGELOG' || name == '.BUILDINFO' || name == '.MTREE' {
			r.skip_data() or {}
		} else {
			pkg.files.files << FileInfo{
				name: name
				size: entry.size()
				mode: entry.mode()
			}
			r.skip_data() or {}
		}
	}
	return pkg
}
