// Sync database reader for the ace package manager.
//
// A sync database is a compressed tar archive (.db.tar.{zst,xz,gz}) containing
// one directory per package. Each package directory holds:
//   desc     — %KEY% format metadata
//   depends  — dependency specifiers (one per line)
//   files    — file manifest (optional; present in .files databases only)
//
// Reference: pacman/lib/libalpm/be_sync.c
module db

import os
import vibarchive.archive

// ---------------------------------------------------------------------------
// SyncDB
// ---------------------------------------------------------------------------

// SyncDB represents a sync (repository) package database.
pub struct SyncDB {
pub mut:
	pkgcache map[string]&Package
}

// new_sync_db creates a new empty SyncDB.
pub fn new_sync_db() SyncDB {
	return SyncDB{}
}

// ---------------------------------------------------------------------------
// populate — open a .db archive and parse every package
// ---------------------------------------------------------------------------

// populate opens a sync database archive, iterates its tar entries, and
// populates the SyncDB with parsed Package structs.
//
// dbpath is the full path to the .db file (e.g.
// "/var/lib/pacman/sync/core.db").
pub fn populate(mut sdb SyncDB, dbpath string) ! {
	if !os.exists(dbpath) {
		return error('sync db not found: ${dbpath}')
	}

	mut r := archive.new_reader()
	defer {
		r.free()
	}
	r.support_filter_all()!
	r.support_format_all()!
	r.open_file(dbpath)!

	mut cur_pkg := &Package{}
	mut cur_dir := ''
	mut has_desc := false

	for {
		entry := r.next_header() or { break }
		pathname := entry.pathname()

		if entry.is_dir() {
			// Directory entry — signals a new package group.
			dir := pathname.trim_right('/')
			if !dir.contains('/') {
				if has_desc && cur_pkg.name != '' {
					finalize_pkg(mut sdb, mut cur_pkg)
				}
				cur_dir = dir
				cur_pkg = &Package{}
				has_desc = false
			}
			continue
		}

		// File entry — extract directory name and filename from path.
		// Path format: "pkgname-version/filename"
		slash_idx := pathname.last_index('/') or {
			continue
		}
		pkg_dir := pathname[..slash_idx]
		filename := pathname[slash_idx + 1..]

		// Detect transition to a new package.
		if pkg_dir != cur_dir {
			if has_desc && cur_pkg.name != '' {
				finalize_pkg(mut sdb, mut cur_pkg)
			}
			cur_dir = pkg_dir
			cur_pkg = &Package{}
			has_desc = false
		}

		// Read the full entry data.
		content := read_entry_data(r, entry) or {
			// If we can't read the data, skip and continue to next entry.
			r.skip_data() or {}
			continue
		}

		match filename {
			'desc' {
				parse_desc(mut cur_pkg, content)
				// Fallback: if desc didn't set name/version, try directory name.
				if cur_pkg.name == '' {
					cur_pkg.name, cur_pkg.version = split_name_version(cur_dir)
				}
				has_desc = true
			}
			'depends' {
				parse_depends(mut cur_pkg, content)
			}
			'files' {
				parse_files(mut cur_pkg, content)
			}
			else {}
		}
	}

	// Finalize the last package.
	if has_desc && cur_pkg.name != '' {
		finalize_pkg(mut sdb, mut cur_pkg)
	}
}

// read_entry_data reads the complete data for an archive entry.
fn read_entry_data(r &archive.ArchiveReader, entry &archive.ArchiveEntry) !string {
	sz := entry.size()
	if sz == 0 {
		r.skip_data() or {}
		return ''
	}
	mut data := []u8{len: int(sz)}
	mut total_read := i64(0)
	for total_read < sz {
		chunk := r.read_data(mut data[total_read..])!
		if chunk <= 0 {
			break
		}
		total_read += chunk
	}
	return data.bytestr()
}

// finalize_pkg computes derived fields and inserts the package into the DB.
fn finalize_pkg(mut sdb SyncDB, mut pkg &Package) {
	if pkg.name == '' {
		return
	}
	pkg.name_hash = compute_name_hash(pkg.name)
	pkg.origin = .sync_db
	sdb.pkgcache[pkg.name] = pkg
}

// ---------------------------------------------------------------------------
// split_name_version — best-effort parse from "{name}-{version}" directory name
// ---------------------------------------------------------------------------

// split_name_version extracts the package name and version from a directory
// name like "glibc-2.35-1" → ("glibc", "2.35-1").
//
// The heuristic finds the first hyphen (left-to-right) that is followed by a
// digit; that is the boundary between the package name (which may itself
// contain hyphens) and the version string.
fn split_name_version(s string) (string, string) {
	for i := 0; i < s.len; i++ {
		if s[i] == `-` && i + 1 < s.len && s[i + 1].is_digit() {
			return s[..i], s[i + 1..]
		}
	}
	return s, ''
}

// ---------------------------------------------------------------------------
// %KEY% desc file parser
// ---------------------------------------------------------------------------

// parse_desc parses a %KEY% format desc file and populates the Package.
fn parse_desc(mut pkg &Package, data string) {
	lines := data.split('\n')
	mut i := 0
	for i < lines.len {
		line := lines[i].trim_space()
		if line == '' || !line.starts_with('%') {
			i++
			continue
		}
		key := line.trim('%')
		i++

		// Collect values until next %KEY% or end.
		// Trailing whitespace is stripped per line (matching pacman's
		// fgets + rtrim convention) but leading whitespace is preserved
		// for continuation lines (e.g. wrapped PGP signatures).
		mut values := []string{}
		for i < lines.len {
			raw := lines[i]
			trimmed := raw.trim_right(' \t\r\n')
			if trimmed == '' || trimmed.starts_with('%') {
				break
			}
			values << trimmed
			i++
		}

		match key {
			'NAME' {
				if values.len > 0 {
					pkg.name = values[0]
				}
			}
			'VERSION' {
				if values.len > 0 {
					pkg.version = values[0]
				}
			}
			'DESC' {
				if values.len > 0 {
					pkg.desc = values[0]
				}
			}
			'URL' {
				if values.len > 0 {
					pkg.url = values[0]
				}
			}
			'ARCH' {
				if values.len > 0 {
					pkg.arch = values[0]
				}
			}
			'PACKAGER' {
				if values.len > 0 {
					pkg.packager = values[0]
				}
			}
			'BASE' {
				if values.len > 0 {
					pkg.base = values[0]
				}
			}
			'SHA256SUM' {
				if values.len > 0 {
					pkg.sha256sum = values[0]
				}
			}
			'PGPSIG' {
				if values.len > 0 {
					// PGP signatures can span multiple lines (wrapped base64).
					pkg.base64_sig = values.join('\n')
				}
			}
			'FILENAME' {
				if values.len > 0 {
					pkg.filename = values[0]
				}
			}
			'CSIZE' {
				if values.len > 0 {
					pkg.download_size = values[0].i64()
				}
			}
			'ISIZE' {
				if values.len > 0 {
					pkg.isize = values[0].i64()
				}
			}
			'BUILDDATE' {
				if values.len > 0 {
					pkg.build_date = values[0].i64()
				}
			}
			'INSTALLDATE' {
				if values.len > 0 {
					pkg.install_date = values[0].i64()
				}
			}
			'LICENSE' {
				pkg.licenses << values
			}
			'GROUPS' {
				pkg.groups << values
			}
			'REPLACES' {
				for v in values {
					if dep := Dependency.from_string(v) {
						pkg.replaces << dep
					}
				}
			}
			'CONFLICTS' {
				for v in values {
					if dep := Dependency.from_string(v) {
						pkg.conflicts << dep
					}
				}
			}
			'PROVIDES' {
				for v in values {
					if dep := Dependency.from_string(v) {
						pkg.provides << dep
					}
				}
			}
			'DEPENDS' {
				for v in values {
					if dep := Dependency.from_string(v) {
						pkg.depends << dep
					}
				}
			}
			'OPTDEPENDS' {
				for v in values {
					// Strip "name: description" format — from_string
					// does not handle the ':' separator (only version
					// operators), so "python: for scripting" would
					// be stored with name="python: for scripting",
					// breaking --all-optional lookups.
					dep_name := v.split(':')[0].trim_space()
					if dep := Dependency.from_string(dep_name) {
						pkg.optdepends << dep
					}
				}
			}
			'MAKEDEPENDS' {
				for v in values {
					if dep := Dependency.from_string(v) {
						pkg.makedepends << dep
					}
				}
			}
			'CHECKDEPENDS' {
				for v in values {
					if dep := Dependency.from_string(v) {
						pkg.checkdepends << dep
					}
				}
			}
			'XDATA' {
				for v in values {
					if v.contains('=') {
						parts := v.split_n('=', 2)
						pkg.xdata << XData{
							name:  parts[0]
							value: parts[1]
						}
					}
				}
			}
			else {}
		}
	}
}

// ---------------------------------------------------------------------------
// depends file parser
// ---------------------------------------------------------------------------

// parse_depends parses a depends file (one dependency per line) and populates
// pkg.depends.
fn parse_depends(mut pkg &Package, data string) {
	for raw_line in data.split('\n') {
		dep_line := raw_line.trim_space()
		if dep_line == '' {
			continue
		}
		if dep := Dependency.from_string(dep_line) {
			pkg.depends << dep
		}
	}
}

// ---------------------------------------------------------------------------
// files file parser
// ---------------------------------------------------------------------------

// parse_files parses a files manifest (one path per line) and populates
// pkg.files.
fn parse_files(mut pkg &Package, data string) {
	for raw_line in data.split('\n') {
		file_line := raw_line.trim_space()
		if file_line == '' {
			continue
		}
		pkg.files.files << FileInfo{
			name: file_line
		}
	}
}

// ---------------------------------------------------------------------------
// Lookup helpers
// ---------------------------------------------------------------------------

// get_pkg returns a pointer to the Package with the given name, or none.
pub fn get_pkg(sdb &SyncDB, name string) ?&Package {
	return sdb.pkgcache[name] or { none }
}

// get_pkgcache returns a slice of all packages in the database.
pub fn get_pkgcache(sdb &SyncDB) []&Package {
	return sdb.pkgcache.values()
}
