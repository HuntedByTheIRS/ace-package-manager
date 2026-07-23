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
	noscriptlet
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

	// Pre-allocate generous file-list capacity to avoid repeated
	// reallocation during extraction.  Most packages have < 10k files.
	pkg.files = db.FileList{files: []db.FileInfo{cap: 10000}}

	mut extracted := 0
	// Reusable read buffer — allocated once, zeroed on first use.
	// Avoids ~1000+ small allocations per package for the old per-file
	// buf := []u8{len: 8192} inside the loop.
	mut read_buf := []u8{len: 8192}

	// Single-pass extraction — no separate counting pass.
	// The first pass in the old code decompressed every entry just to
	// count them, effectively doubling the decompression I/O for every
	// package install.  We display a file-count progress instead of a
	// percentage, which costs nothing.
	for {
		entry := r.next_header() or { break }
		entry_name := entry.pathname()

		// Metadata entries: .PKGINFO, .INSTALL, .BUILDINFO, .MTREE are
		// skipped.  .CHANGELOG is preserved in the local database so
		// that `ace -Qc` can display it later (libalpm does the same).
		if entry_name.starts_with('.') {
			if entry_name == '.CHANGELOG' {
				mut data := []u8{}
				mut cbuf := []u8{len: 8192}
				for {
					n := r.read_data(mut cbuf) or { break }
					if n <= 0 {
						break
					}
					data << cbuf[..n]
				}
				pkg_dir := os.join_path(handle.resolved_dbpath(), 'local', '${pkg.name}-${pkg.version}')
				os.mkdir_all(pkg_dir) or { continue }
				os.write_file(os.join_path(pkg_dir, 'changelog'), data.bytestr()) or {}
				continue
			}
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

			// Remove existing file at destination if overwriting.
			if os.exists(dest_path) && !os.is_dir(dest_path) {
				os.rm(dest_path) or {}
			}

			// Stream file payload directly to disk — no intermediate
			// in-memory buffer for the entire file.  Previously the
			// entire entry was read into a []u8 then written via
			// os.write_file, which doubled memory for large files
			// (e.g. 80 MiB libLLVM.so).
			mut out := os.open_file(dest_path, 'wb', 0o644) or {
				r.skip_data() or {}
				return error('cannot open ${dest_path}: ${err}')
			}
			for {
				n := r.read_data(mut read_buf) or { break }
				if n <= 0 {
					break
				}
				out.write(read_buf[..n]) or {
					out.close()
					r.skip_data() or {}
					return error('write to ${dest_path} failed: ${err}')
				}
			}
			out.close()
			r.skip_data() or {}
			os.chmod(dest_path, int(entry.mode())) or {}
		} else {
			// Hardlinks or unknown entry types — skip.
			r.skip_data() or {}
		}

		// File-count progress display (no percentage since we don't pre-count).
		extracted++
		if extracted % 100 == 1 {
			print('\r  ' + color_progress('extracting: ${extracted} files...'))
		}
	}

	if extracted > 0 {
		println('\r  ' + color_progress('extracted ${extracted} files'))
	}
}

// use_color reports whether terminal color output is enabled.
// Delegates to util (trans cannot import cli — circular).
fn use_color() bool {
	return util.color_enabled()
}

// color_progress wraps a progress message in the theme's progress orange.
fn color_progress(s string) string {
	if use_color() {
		return '\033[38;5;208m' + s + '\033[0m'
	}
	return s
}

// color_warn formats a warning message (matches cli's warn() style).
fn color_warn(s string) string {
	if use_color() {
		return '\033[1m\033[38;5;220mwarning:\033[0m ${s}'
	}
	return 'warning: ${s}'
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
