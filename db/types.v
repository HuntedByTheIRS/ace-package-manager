// Package and dependency data types for the ace package manager.
//
// Reference: pacman/lib/libalpm/alpm.h:105-195, alpm.h:534-698, package.h:90-146
module db

// ---------------------------------------------------------------------------
// Dependency types
// ---------------------------------------------------------------------------

// DepMod matches alpm_depmod_t from libalpm.
pub enum DepMod {
	any = 1
	eq = 2
	ge = 3
	le = 4
	gt = 5
	lt = 6
}

// Dependency represents a package dependency with an optional version
// constraint (e.g. "glibc>=2.35" means mod=ge, name="glibc", version="2.35").
pub struct Dependency {
pub:
	name      string
	version   string
	desc      string
	modifier  DepMod
	name_hash u64
}

// from_string parses a dependency specifier in the form "name[op]version"
// where op is one of >=, <=, =, >, <, or absent (any version).
// Examples: "glibc", "glibc>=2.35", "python<3.12", "libfoo=1.0"
pub fn Dependency.from_string(s string) ?Dependency {
	if s.len == 0 {
		return none
	}

	// Locate the comparison operator (scan for > < =).
	// Check two-character operators (>=, <=) before single-character ones.
	mut op_start := -1
	mut op_len := 0
	mut dep_mod := DepMod.any

	for i, c in s {
		if c == `>` {
			if i + 1 < s.len && s[i + 1] == `=` {
				dep_mod = .ge
				op_start = i
				op_len = 2
			} else {
				dep_mod = .gt
				op_start = i
				op_len = 1
			}
			break
		}
		if c == `<` {
			if i + 1 < s.len && s[i + 1] == `=` {
				dep_mod = .le
				op_start = i
				op_len = 2
			} else {
				dep_mod = .lt
				op_start = i
				op_len = 1
			}
			break
		}
		if c == `=` {
			dep_mod = .eq
			op_start = i
			op_len = 1
			break
		}
	}

	name := if op_start == -1 { s } else { s[..op_start] }
	version := if op_start == -1 { '' } else { s[op_start + op_len..] }

	if name.len == 0 {
		return none
	}

	return Dependency{
		name:      name
		version:   version
		modifier:  dep_mod
		name_hash: compute_name_hash(name)
	}
}

// to_string returns the canonical string form of the dependency specifier
// (e.g. "glibc>=2.35", "python", "libfoo=1.0").
pub fn (d &Dependency) to_string() string {
	op := match d.modifier {
		.any { '' }
		.eq { '=' }
		.ge { '>=' }
		.le { '<=' }
		.gt { '>' }
		.lt { '<' }
	}
	if op == '' || d.version == '' {
		return d.name
	}
	return '${d.name}${op}${d.version}'
}

// ---------------------------------------------------------------------------
// Conflict, DepMissing
// ---------------------------------------------------------------------------

// Conflict represents a dependency conflict between two packages.
pub struct Conflict {
pub:
	package1 string
	package2 string
	reason   &Dependency
}

// DepMissing represents an unsatisfied dependency.
pub struct DepMissing {
pub:
	target      string
	depend      &Dependency
	causing_pkg string
}

// ---------------------------------------------------------------------------
// File conflict types
// ---------------------------------------------------------------------------

// FileConflictType distinguishes conflicts caused by a target-package file
// vs. a file already on the filesystem.
pub enum FileConflictType {
	target
	filesystem
}

// FileConflict describes a file conflict between packages.
pub struct FileConflict {
pub:
	target        string
	file          string
	ctarget       string
	conflict_type FileConflictType
}

// ---------------------------------------------------------------------------
// File info
// ---------------------------------------------------------------------------

// FileInfo holds metadata for a single file in a package.
pub struct FileInfo {
pub:
	name string
	size i64
	mode u32
}

// FileList holds the complete file listing for a package.
pub struct FileList {
pub mut:
	files []FileInfo
}

// BackupFile associates a file path with its last-known hash (mtree).
pub struct BackupFile {
pub mut:
	name string
	hash string
}

// ---------------------------------------------------------------------------
// Group
// ---------------------------------------------------------------------------

// Group represents a package group.
pub struct Group {
pub:
	name     string
	packages []string
}

// ---------------------------------------------------------------------------
// Package metadata enums
// ---------------------------------------------------------------------------

// PackageReason indicates why a package was installed.
pub enum PackageReason {
	explicit = 0
	depend   = 1
	unknown  = -1
}

// PackageOrigin indicates where a package was loaded from.
pub enum PackageOrigin {
	file    = 1
	local_db = 2
	sync_db  = 3
}

// PackageValidation is a bitmask of validation methods that have been
// applied to a package.  Use int() to convert and perform bitwise checks:
//
// ```v
// if int(pkg.validation) & int(PackageValidation.signature) != 0 { ... }
// ```
//
// Values match libalpm's alpm_pkgvalidation_t.
pub enum PackageValidation {
	unknown   = 0
	none      = 1
	md5sum    = 2
	sha256sum = 4
	signature = 8
}

// ---------------------------------------------------------------------------
// Extension data
// ---------------------------------------------------------------------------

// XData holds a single name=value extension data pair (used for
// arbitrary metadata attached to packages by the repository).
pub struct XData {
pub:
	name  string
	value string
}

// ---------------------------------------------------------------------------
// Package
// ---------------------------------------------------------------------------

// Package holds all metadata for a single package (local, sync, or file).
@[heap]
pub struct Package {
pub mut:
	name          string
	name_hash     u64
	version       string
	filename      string
	base          string
	desc          string
	url           string
	packager      string
	sha256sum     string
	base64_sig    string
	arch          string
	build_date    i64
	install_date  i64
	size          i64
	isize         i64
	download_size i64
	licenses      []string
	replaces      []Dependency
	groups        []string
	backup        []BackupFile
	depends       []Dependency
	optdepends    []Dependency
	checkdepends  []Dependency
	makedepends   []Dependency
	conflicts     []Dependency
	provides      []Dependency
	files         FileList
	origin        PackageOrigin
	reason        PackageReason
	validation    PackageValidation
	scriptlet     bool
	xdata         []XData
}

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

// Database represents a package database (local or sync).
pub struct Database {
pub mut:
	pkgcache map[string]&Package
	grpcache map[string]Group
	name     string
	servers  []string
}

// ---------------------------------------------------------------------------
// Hash helper
// ---------------------------------------------------------------------------

// compute_name_hash computes the sdbm hash of a string, matching
// libalpm's _alpm_hash_sdbm. Used for dependency name lookups.
pub fn compute_name_hash(s string) u64 {
	mut hash := u64(0)
	for c in s {
		hash = u64(c) + (hash << 6) + (hash << 16) - hash
	}
	return hash
}

// build_grpcache populates a Database's grpcache from its pkgcache.
// Each package's groups slice is scanned and the grpcache map is
// populated with Group entries listing all packages in each group.
// Uses a per-package seen-groups set to avoid both duplicate entries
// from malformed metadata AND the O(n²) linear scan of the old code.
pub fn build_grpcache(mut database Database) {
	database.grpcache = map[string]Group{}
	for _, pkg in database.pkgcache {
		mut seen_groups := map[string]bool{}
		for gname in pkg.groups {
			if gname in seen_groups {
				continue // duplicate group entry in package metadata
			}
			seen_groups[gname] = true
			if g := database.grpcache[gname] {
				mut new_pkgs := g.packages.clone()
				new_pkgs << pkg.name
				database.grpcache[gname] = Group{
					name:     g.name
					packages: new_pkgs
				}
			} else {
				database.grpcache[gname] = Group{
					name:     gname
					packages: [pkg.name]
				}
			}
		}
	}
}
