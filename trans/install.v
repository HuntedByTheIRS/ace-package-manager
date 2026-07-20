module trans

import db
import os
import util
import vibarchive.archive as va

// InstallFlags controls the behaviour of package installation.
// Values correspond to pacman's ALPM_TRANS_FLAG_* for add operations.
@[flag]
pub enum InstallFlags {
	asdeps
	asexplicit
	needed
	noscriplet
	dbonly
	downloadonly
	force
}

// install_package extracts the package archive to the filesystem and then
// writes the package metadata to the local database.
// pkg.filename must hold the path to the .pkg.tar.* file.
//
// Reference: pacman/lib/libalpm/add.c — _alpm_add_commit / extract_single_file
pub fn install_package(handle &util.Handle, mut pkg db.Package, old_pkg ?&db.Package) ! {
	archive_path := pkg.filename
	if handle.debug_level > 0 {
		eprintln('[DEBUG] install_package: ${pkg.name}-${pkg.version} (${archive_path})')
	}
	if !os.exists(archive_path) {
		return util.AceError{code: .pkg_open, message: 'package file not found: ' + archive_path}
	}

	// Extract package files to the filesystem under handle.root.
	// Also populates pkg.files.files from the archive so the file list is
	// available for -R (remove), -Ql (list), and -Qk (check).
	// Clear any pre-existing file list from sync DB metadata first.
	pkg.files = db.FileList{}
	extract_package_files(handle, archive_path, mut pkg) or {
		return util.AceError{code: .pkg_open, message: 'extraction failed: ' + err.msg()}
	}

	// Write metadata to local database
	db.write_pkg(handle.resolved_dbpath(), pkg, 2 | 4) or {
		return util.AceError{code: .db_write, message: 'cannot write package: ' + err.msg()}
	}
}

// extract_package_files extracts the contents of a .pkg.tar.* archive
// to the filesystem under handle.root.  Metadata entries (path prefixed
// with '.') are skipped — they belong to the package DB, not the filesystem.
//
// Also populates pkg.files.files with the archive's file manifest so that
// later operations (-R, -Ql, -Qk) have the complete file list even when
// the sync database did not include file metadata.
//
// Handles directories, regular files, and symlinks.  File permissions
// and symlink targets are preserved from the archive metadata.
fn extract_package_files(handle &util.Handle, archive_path string, mut pkg db.Package) ! {
	if handle.debug_level > 0 {
		eprintln('[DEBUG] extract_package_files: opening ${archive_path}')
	}
	mut r := va.new_reader()
	r.open(archive_path)!
	defer {
		r.free()
	}

	// First pass: count non-metadata entries for progress display.
	mut total_entries := 0
	for {
		e := r.next_header() or { break }
		if !e.pathname().starts_with('.') {
			total_entries++
		}
		r.skip_data() or {}
	}
	r.free()

	if handle.debug_level > 0 {
		eprintln('[DEBUG]   total entries to extract: ${total_entries}')
	}

	// Second pass: extract.
	r = va.new_reader()
	r.open(archive_path)!

	mut extracted := 0
	mut last_pct := 0
	bar_width := 40

	for {
		entry := r.next_header() or { break }
		entry_name := entry.pathname()

		// Skip metadata entries: .PKGINFO, .INSTALL, .CHANGELOG,
		// .BUILDINFO, .MTREE, and anything else starting with '.'
		if entry_name.starts_with('.') {
			r.skip_data() or {}
			continue
		}

		// Build the on-disk path: handle.root + entry_path
		dest_path := os.join_path(handle.root, entry_name)
		if handle.debug_level > 1 { eprintln('[DEBUG]   extract: ${entry_name}') }

		// Record the file in the package manifest for -R/-Ql/-Qk later.
		pkg.files.files << db.FileInfo{
			name: entry_name
			size: entry.size()
			mode: entry.mode()
		}

		if entry.is_dir() {
			os.mkdir_all(dest_path) or {
				r.skip_data() or {}
				return error('cannot create directory ${dest_path}: ${err}')
			}
			os.chmod(dest_path, int(entry.mode())) or {}
			r.skip_data() or {}
		} else if entry.is_symlink() {
			// Ensure parent directory exists.
			parent_dir := dest_path.all_before_last('/')
			if parent_dir != '' && !os.exists(parent_dir) {
				os.mkdir_all(parent_dir) or {
					r.skip_data() or {}
					return error('cannot create parent dir ${parent_dir}: ${err}')
				}
			}

			target := entry.symlink()
			// Remove any existing node at this path before creating the symlink.
			if os.exists(dest_path) || os.is_link(dest_path) {
				os.rm(dest_path) or {}
			}
			os.symlink(target, dest_path) or {
				r.skip_data() or {}
				return error('cannot create symlink ${dest_path} -> ${target}: ${err}')
			}
			r.skip_data() or {}
		} else if entry.is_file() {
			// Ensure parent directory exists.
			parent_dir := dest_path.all_before_last('/')
			if parent_dir != '' && !os.exists(parent_dir) {
				os.mkdir_all(parent_dir) or {
					r.skip_data() or {}
					return error('cannot create parent dir ${parent_dir}: ${err}')
				}
			}

			// Read the file payload from the archive.
			entry_size := entry.size()
			mut data := []u8{}
			if entry_size > 0 {
				data = []u8{cap: int(entry_size)}
				mut buf := []u8{len: 8192}
				for {
					n := r.read_data(mut buf) or { break }
					if n <= 0 {
						break
					}
					data << buf[..n]
				}
			}
			r.skip_data() or {}

			// Remove existing file at destination if overwriting.
			if os.exists(dest_path) && !os.is_dir(dest_path) {
				os.rm(dest_path) or {}
			}

			os.write_file(dest_path, data.bytestr()) or {
				return error('cannot write file ${dest_path}: ${err}')
			}
			os.chmod(dest_path, int(entry.mode())) or {}
		} else {
			// Hardlinks or unknown entry types — skip.
			r.skip_data() or {}
		}

		// Progress bar display.
		extracted++
		if total_entries > 0 {
			pct := extracted * 100 / total_entries
			if pct > last_pct {
				last_pct = pct
				filled := bar_width * extracted / total_entries
				mut bar := ''
				for _ in 0 .. filled {
					bar += '#'
				}
				for _ in filled .. bar_width {
					bar += ' '
				}
				print('\r  [${bar}] ${pct:3}% (${extracted}/${total_entries})')
			}
		}
	}

	if total_entries > 0 {
		println('\r  [${'#'.repeat(bar_width)}] 100% (${extracted}/${total_entries})')
	}
}

// compute_upgrade_targets validates package file targets.
pub fn compute_upgrade_targets(targets []string) ![]string {
	if targets.len == 0 { return error('no targets specified for upgrade') }
	mut files := []string{}
	for target in targets {
		if target.starts_with('http://') || target.starts_with('https://') { files << target }
		else if os.exists(target) {
			if os.is_dir(target) {
				entries := os.ls(target) or { return error('cannot list directory: ' + err.msg()) }
				for entry in entries {
					if entry.contains('.pkg.tar') { files << os.join_path(target, entry) }
				}
				if files.len == 0 { return error('no package files found in ' + target) }
			} else { files << target }
		} else { return error('target not found: ' + target) }
	}
	if files.len == 0 { return error('no valid package files specified') }
	return files
}
