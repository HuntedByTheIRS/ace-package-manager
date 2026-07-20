// Module: db — local database reader and writer for the ace package manager.
//
// The local database resides at {dbpath}/local/ and is a plain-text directory
// tree containing one subdirectory per installed package (name-version).
// Each package directory holds a `desc` file (key-value metadata in %KEY%
// format) and a `files` file (file listings and backup markers).
//
// Reference: pacman/lib/libalpm/be_local.c
module db

import os

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

// ALPM_LOCAL_DB_VERSION is the expected version of the local database format.
const alpm_local_db_version = '9'

// package_validation_from_int converts an int to PackageValidation without unsafe.
fn package_validation_from_int(val int) PackageValidation {
	return unsafe { PackageValidation(val) }
}

// INFRQ bitmask constants — matches pacman's INFRQ_DESC / INFRQ_FILES.
pub const infrq_desc = 2
pub const infrq_files = 4

// ---------------------------------------------------------------------------
// LocalDB
// ---------------------------------------------------------------------------

// LocalDB is an in-memory representation of a local package database.
pub struct LocalDB {
pub mut:
	pkgcache map[string]&Package // name → &Package (O(1) lookups)
	dbpath   string              // full path to the local/ directory
}

// ---------------------------------------------------------------------------
// init
// ---------------------------------------------------------------------------

// init opens a local database at the given root path. It reads and validates
// the ALPM_DB_VERSION file at {dbpath}/local/ALPM_DB_VERSION.
pub fn init(dbpath string) !LocalDB {
	local_dir := os.join_path(dbpath, 'local')
	if !os.is_dir(local_dir) {
		return error('database directory "${local_dir}" does not exist')
	}

	version_file := os.join_path(local_dir, 'ALPM_DB_VERSION')
	if !os.exists(version_file) {
		return error('missing ALPM_DB_VERSION in "${local_dir}"')
	}

	version_lines := os.read_lines(version_file) or {
		return error('cannot read ALPM_DB_VERSION: ${err}')
	}

	if version_lines.len == 0 || version_lines[0].trim_space().len == 0 {
		return error('ALPM_DB_VERSION is empty')
	}

	version := version_lines[0].trim_space()
	if version != alpm_local_db_version {
		return error('database is incorrect version (expected ${alpm_local_db_version}, got ${version})')
	}

	return LocalDB{
		pkgcache: map[string]&Package{}
		dbpath:   local_dir
	}
}

// ---------------------------------------------------------------------------
// populate
// ---------------------------------------------------------------------------

// populate scans {dbpath}/local/ for package subdirectories (name-version),
// reads their desc and files entries, and populates the pkgcache map.
pub fn (mut ldb LocalDB) populate() ! {
	entries := os.ls(ldb.dbpath) or {
		return error('cannot list database directory: ${err}')
	}

	for entry in entries {
		if entry == '.' || entry == '..' || entry == 'ALPM_DB_VERSION' {
			continue
		}

		pkg_dir := os.join_path(ldb.dbpath, entry)
		if !os.is_dir(pkg_dir) {
			continue
		}

		pkg := read_package(pkg_dir, entry) or {
			continue
		}

		if pkg.name in ldb.pkgcache {
			continue
		}

		ldb.pkgcache[pkg.name] = pkg
	}
}

// ---------------------------------------------------------------------------
// get_pkg / get_pkgcache
// ---------------------------------------------------------------------------

// get_pkg looks up a package by name in the local database.
// Returns `none` if the package is not found.
pub fn (ldb &LocalDB) get_pkg(name string) ?&Package {
	if pkg := ldb.pkgcache[name] {
		return pkg
	}
	return none
}

// get_pkgcache returns all packages currently loaded in the local database.
pub fn (ldb &LocalDB) get_pkgcache() []&Package {
	mut pkgs := []&Package{}
	for _, pkg in ldb.pkgcache {
		pkgs << pkg
	}
	return pkgs
}

// ---------------------------------------------------------------------------
// write_pkg / remove_pkg
// ---------------------------------------------------------------------------

// write_pkg writes a package's metadata to the local database at
// {dbpath}/local/{name}-{version}/desc and/or files, depending on infolevel.
//
// infolevel bitmask:
//   bit 1 (value 2)  — write desc file   (INFRQ_DESC)
//   bit 2 (value 4)  — write files file  (INFRQ_FILES)
pub fn write_pkg(dbpath string, pkg &Package, infolevel int) ! {
	pkg_dir_name := '${pkg.name}-${pkg.version}'
	pkg_dir := os.join_path(dbpath, 'local', pkg_dir_name)

	// Ensure the package directory exists.
	os.mkdir_all(pkg_dir) or {
		return error('cannot create package directory "${pkg_dir}": ${err}')
	}

	// DESC
	if infolevel & infrq_desc != 0 {
		desc_path := os.join_path(pkg_dir, 'desc')
		write_desc_file(desc_path, pkg) or {
			return error('cannot write desc file: ${err}')
		}
	}

	// FILES
	if infolevel & infrq_files != 0 {
		files_path := os.join_path(pkg_dir, 'files')
		write_files_file(files_path, pkg) or {
			return error('cannot write files file: ${err}')
		}
	}
}

// remove_pkg removes a package's directory from the local database at
// {dbpath}/local/{name}-{version}/. Errors if the directory does not exist
// or cannot be fully removed.
pub fn remove_pkg(dbpath string, pkgname string, version string) ! {
	pkg_dir_name := '${pkgname}-${version}'
	pkg_dir := os.join_path(dbpath, 'local', pkg_dir_name)

	if !os.is_dir(pkg_dir) {
		return error('package directory not found: ${pkg_dir}')
	}

	// Remove all files in the package directory (desc, files, install, etc.)
	entries := os.ls(pkg_dir) or {
		return error('cannot list package directory: ${err}')
	}

	for entry in entries {
		if entry == '.' || entry == '..' {
			continue
		}
		file_path := os.join_path(pkg_dir, entry)
		os.rm(file_path) or {
			return error('cannot remove file "${file_path}": ${err}')
		}
	}

	// Remove the directory itself.
	os.rmdir(pkg_dir) or {
		return error('cannot remove package directory "${pkg_dir}": ${err}')
	}
}

// ============================================================================
// Internal helpers — reading
// ============================================================================

// read_package reads desc and files for a single package from its directory
// and returns a fully-populated &Package.
fn read_package(pkg_dir string, dir_name string) !&Package {
	// The directory name is "name-version".  Since package names may contain
	// hyphens we split from the right: the last hyphen separates name from
	// version (pacman's _alpm_splitname convention).
	hyphen_pos := dir_name.last_index('-') or {
		return error('invalid package directory name: "${dir_name}" (no hyphen)')
	}

	name := dir_name[..hyphen_pos]
	version := dir_name[hyphen_pos + 1..]

	if name.len == 0 || version.len == 0 {
		return error('invalid package directory name: "${dir_name}"')
	}

	mut pkg := &Package{
		name:      name
		version:   version
		name_hash: compute_name_hash(name)
		origin:    .local_db
		reason:    .unknown
	}

	// Read desc file and directly populate pkg fields via unsafe
	desc_path := os.join_path(pkg_dir, 'desc')
	if os.exists(desc_path) {
		read_desc_into(mut pkg, desc_path) or { /* best-effort */ }
	}

	// Read files file and directly populate pkg fields via unsafe
	files_path := os.join_path(pkg_dir, 'files')
	if os.exists(files_path) {
		read_files_into(mut pkg, files_path) or { /* best-effort */ }
	}

	return pkg
}

// read_desc_into parses a `desc` file in %KEY% format and sets the fields
// on `pkg`.  Uses unsafe{} blocks to bypass V's field immutability checks
// since the Package struct uses pub: (immutable) access.
fn read_desc_into(mut pkg Package, path string) ! {
	lines := os.read_lines(path) or {
		return error('cannot read desc file: ${err}')
	}

	mut i := 0
	for i < lines.len {
		line := lines[i].trim_space()
		i++

		if line.len == 0 {
			continue
		}
		if line.len < 3 || line[0] != `%` || line[line.len - 1] != `%` {
			continue
		}

		key := line[1..line.len - 1]

		match key {
			'NAME' {
				if i < lines.len {
					pkg.name = lines[i].trim_space()
					pkg.name_hash = compute_name_hash(pkg.name)
					i++
				}
			}
			'VERSION' {
				if i < lines.len {
					pkg.version = lines[i].trim_space()
					i++
				}
			}
			'BASE' {
				if i < lines.len {
					pkg.base = lines[i].trim_space()
					i++
				}
			}
			'DESC' {
				if i < lines.len {
					pkg.desc = lines[i].trim_space()
					i++
				}
			}
			'URL' {
				if i < lines.len {
					pkg.url = lines[i].trim_space()
					i++
				}
			}
			'ARCH' {
				if i < lines.len {
					pkg.arch = lines[i].trim_space()
					i++
				}
			}
			'PACKAGER' {
				if i < lines.len {
					pkg.packager = lines[i].trim_space()
					i++
				}
			}
			'BUILDDATE' {
				if i < lines.len {
					pkg.build_date = lines[i].trim_space().i64()
					i++
				}
			}
			'INSTALLDATE' {
				if i < lines.len {
					pkg.install_date = lines[i].trim_space().i64()
					i++
				}
			}
			'SIZE' {
				if i < lines.len {
					pkg.isize = lines[i].trim_space().i64()
					i++
				}
			}
			'REASON' {
				if i < lines.len {
					rs := lines[i].trim_space()
					i++
					pkg.reason = match rs {
						'0' { .explicit }
						'1' { .depend }
						else { .unknown }
					}
				}
			}
			'GROUPS' {
				mut groups := []string{}
				for i < lines.len {
					val := lines[i].trim_space()
					i++
					if val.len == 0 { break }
					groups << val
				}
				pkg.groups = groups
			}
			'LICENSE' {
				mut lic := []string{}
				for i < lines.len {
					val := lines[i].trim_space()
					i++
					if val.len == 0 { break }
					lic << val
				}
				pkg.licenses = lic
			}
			'DEPENDS' {
				mut deps := []Dependency{}
				for i < lines.len {
					val := lines[i].trim_space()
					i++
					if val.len == 0 { break }
					if dep := Dependency.from_string(val) { deps << dep }
				}
				pkg.depends = deps
			}
			'OPTDEPENDS' {
				mut deps := []Dependency{}
				for i < lines.len {
					val := lines[i].trim_space()
					i++
					if val.len == 0 { break }
					if dep := Dependency.from_string(val) { deps << dep }
				}
				pkg.optdepends = deps
			}
			'MAKEDEPENDS' {
				mut deps := []Dependency{}
				for i < lines.len {
					val := lines[i].trim_space()
					i++
					if val.len == 0 { break }
					if dep := Dependency.from_string(val) { deps << dep }
				}
				pkg.makedepends = deps
			}
			'CHECKDEPENDS' {
				mut deps := []Dependency{}
				for i < lines.len {
					val := lines[i].trim_space()
					i++
					if val.len == 0 { break }
					if dep := Dependency.from_string(val) { deps << dep }
				}
				pkg.checkdepends = deps
			}
			'CONFLICTS' {
				mut deps := []Dependency{}
				for i < lines.len {
					val := lines[i].trim_space()
					i++
					if val.len == 0 { break }
					if dep := Dependency.from_string(val) { deps << dep }
				}
				pkg.conflicts = deps
			}
			'PROVIDES' {
				mut deps := []Dependency{}
				for i < lines.len {
					val := lines[i].trim_space()
					i++
					if val.len == 0 { break }
					if dep := Dependency.from_string(val) { deps << dep }
				}
				pkg.provides = deps
			}
			'REPLACES' {
				mut deps := []Dependency{}
				for i < lines.len {
					val := lines[i].trim_space()
					i++
					if val.len == 0 { break }
					if dep := Dependency.from_string(val) { deps << dep }
				}
				pkg.replaces = deps
			}
			'VALIDATION' {
				mut val_bits := 0
				for i < lines.len {
					val := lines[i].trim_space()
					i++
					if val.len == 0 { break }
					val_bits |= match val {
						'none' { 1 }
						'md5' { 2 }
						'sha256' { 4 }
						'pgp' { 8 }
						else { 0 }
					}
				}
				pkg.validation = package_validation_from_int(val_bits)
			}
			'XDATA' {
				mut xdata := []XData{}
				for i < lines.len {
					val := lines[i].trim_space()
					i++
					if val.len == 0 { break }
					if eq_pos := val.index('=') {
						xdata << XData{name: val[..eq_pos], value: val[eq_pos + 1..]}
					}
				}
				pkg.xdata = xdata
			}
			else {
				for i < lines.len {
					val := lines[i].trim_space()
					i++
					if val.len == 0 { break }
				}
			}
		}
	}
}

// read_files_into parses a `files` file with %FILES% and %BACKUP% sections
// and sets the fields on `pkg`.
fn read_files_into(mut pkg Package, path string) ! {
	lines := os.read_lines(path) or {
		return error('cannot read files file: ${err}')
	}

	mut in_files := false
	mut in_backup := false
	mut file_infos := []FileInfo{}
	mut backups := []BackupFile{}

	for line in lines {
		trimmed := line.trim_space()

		if trimmed == '%FILES%' {
			in_files = true
			in_backup = false
			continue
		}
		if trimmed == '%BACKUP%' {
			in_files = false
			in_backup = true
			continue
		}
		if trimmed.len == 0 {
			in_files = false
			in_backup = false
			continue
		}

		if in_files {
			file_infos << FileInfo{ name: trimmed }
		} else if in_backup {
			if tab_pos := trimmed.index('\t') {
				backups << BackupFile{name: trimmed[..tab_pos], hash: trimmed[tab_pos + 1..]}
			} else if space_pos := trimmed.last_index(' ') {
				backups << BackupFile{name: trimmed[..space_pos], hash: trimmed[space_pos + 1..]}
			} else {
				backups << BackupFile{name: trimmed, hash: ''}
			}
		}
	}

	pkg.files = FileList{ files: file_infos }
	pkg.backup = backups
}

// ============================================================================
// Internal helpers — writing
// ============================================================================

// write_desc_file writes a `desc` file in %KEY% format.
fn write_desc_file(path string, pkg &Package) ! {
	mut content := ''

	// Always write NAME and VERSION.
	content += '%NAME%\n${pkg.name}\n\n'
	content += '%VERSION%\n${pkg.version}\n\n'

	if pkg.base.len > 0 {
		content += '%BASE%\n${pkg.base}\n\n'
	}
	if pkg.desc.len > 0 {
		content += '%DESC%\n${pkg.desc}\n\n'
	}
	if pkg.url.len > 0 {
		content += '%URL%\n${pkg.url}\n\n'
	}
	if pkg.arch.len > 0 {
		content += '%ARCH%\n${pkg.arch}\n\n'
	}
	if pkg.packager.len > 0 {
		content += '%PACKAGER%\n${pkg.packager}\n\n'
	}

	// Dates and sizes — write only when non-zero.
	if pkg.build_date > 0 {
		content += '%BUILDDATE%\n${pkg.build_date}\n\n'
	}
	if pkg.install_date > 0 {
		content += '%INSTALLDATE%\n${pkg.install_date}\n\n'
	}
	if pkg.isize > 0 {
		content += '%SIZE%\n${pkg.isize}\n\n'
	}

	// Always write REASON.
	reason_str := match pkg.reason {
		.explicit { '0' }
		.depend { '1' }
		.unknown { '-1' }
	}
	content += '%REASON%\n${reason_str}\n\n'

	// Groups
	if pkg.groups.len > 0 {
		content += '%GROUPS%\n'
		for g in pkg.groups {
			content += '${g}\n'
		}
		content += '\n'
	}

	// Licenses
	if pkg.licenses.len > 0 {
		content += '%LICENSE%\n'
		for l in pkg.licenses {
			content += '${l}\n'
		}
		content += '\n'
	}

	// Validation
	if int(pkg.validation) > 0 {
		content += '%VALIDATION%\n'
		if int(pkg.validation) & int(PackageValidation.none) != 0 {
			content += 'none\n'
		}
		if int(pkg.validation) & int(PackageValidation.sha256sum) != 0 {
			content += 'sha256\n'
		}
		if int(pkg.validation) & int(PackageValidation.signature) != 0 {
			content += 'pgp\n'
		}
		content += '\n'
	}

	// Dependency lists.
	content += write_dep_section('%REPLACES%', pkg.replaces)
	content += write_dep_section('%DEPENDS%', pkg.depends)
	content += write_dep_section('%OPTDEPENDS%', pkg.optdepends)
	content += write_dep_section('%MAKEDEPENDS%', pkg.makedepends)
	content += write_dep_section('%CHECKDEPENDS%', pkg.checkdepends)
	content += write_dep_section('%CONFLICTS%', pkg.conflicts)
	content += write_dep_section('%PROVIDES%', pkg.provides)

	// XData
	if pkg.xdata.len > 0 {
		content += '%XDATA%\n'
		for xd in pkg.xdata {
			content += '${xd.name}=${xd.value}\n'
		}
		content += '\n'
	}

	os.write_file(path, content) or {
		return error('cannot write desc file "${path}": ${err}')
	}
}

// write_dep_section returns a dependency section header and all its
// entries as a string, followed by a trailing blank line, or an empty
// string if the dependency list is empty.
fn write_dep_section(header string, deps []Dependency) string {
	if deps.len == 0 {
		return ''
	}
	mut content := '${header}\n'
	for dep in deps {
		content += '${dep.to_string()}\n'
	}
	content += '\n'
	return content
}

// write_files_file writes a `files` file with %FILES% and %BACKUP% sections.
fn write_files_file(path string, pkg &Package) ! {
	mut content := ''

	// %FILES% section
	if pkg.files.files.len > 0 {
		content += '%FILES%\n'
		for f in pkg.files.files {
			content += '${f.name}\n'
		}
		content += '\n'
	}

	// %BACKUP% section
	if pkg.backup.len > 0 {
		content += '%BACKUP%\n'
		for b in pkg.backup {
			content += '${b.name}\t${b.hash}\n'
		}
		content += '\n'
	}

	os.write_file(path, content) or {
		return error('cannot write files file "${path}": ${err}')
	}
}
