// Package archive types — data structures for reading .pkg.tar.* metadata.
//
// These types mirror a subset of the ace `db` module but are kept
// self-contained to avoid importing the (currently in-progress) db module.
module archive

// ---------------------------------------------------------------------------
// Dependency types
// ---------------------------------------------------------------------------

// DepMod matches libalpm's alpm_depmod_t.
pub enum DepMod {
	any = 1
	eq  = 2
	ge  = 3
	le  = 4
	gt  = 5
	lt  = 6
}

// Dependency represents a package dependency with an optional version
// constraint (e.g. "glibc>=2.35" means mod=ge, name="glibc", version="2.35").
pub struct Dependency {
pub mut:
	name      string
	version   string
	desc      string
	modifier  DepMod
	name_hash u64
}

// from_string parses a dependency specifier in the form "name[op]version"
// where op is one of >=, <=, =, >, <, or absent (any version).
pub fn (d &Dependency) from_string(s string) ?Dependency {
	if s.len == 0 {
		return none
	}

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
	version2 := if op_start == -1 { '' } else { s[op_start + op_len..] }

	if name.len == 0 {
		return none
	}

	return Dependency{
		name:      name
		version:   version2
		modifier:  dep_mod
		name_hash: compute_name_hash(name)
	}
}

// to_string returns the canonical string form (e.g. "glibc>=2.35").
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

// compute_name_hash computes the sdbm hash of a string, matching
// libalpm's _alpm_hash_sdbm.
pub fn compute_name_hash(s string) u64 {
	mut hash := u64(0)
	for c in s {
		hash = u64(c) + (hash << 6) + (hash << 16) - hash
	}
	return hash
}

// ---------------------------------------------------------------------------
// File and backup types
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

// BackupFile associates a file path with its last-known hash (from .MTREE).
pub struct BackupFile {
pub:
	name string
	hash string
}

// ---------------------------------------------------------------------------
// Package metadata enums
// ---------------------------------------------------------------------------

// PackageOrigin indicates where a package was loaded from.
pub enum PackageOrigin {
	file     = 1
	local_db = 2
	sync_db  = 3
}

// ---------------------------------------------------------------------------
// Package
// ---------------------------------------------------------------------------

// Package holds all metadata read from a .pkg.tar.* archive.
//
// Fields are pub mut so that the archive reader (same module) can populate
// them during parsing.
pub struct Package {
pub mut:
	name        string
	name_hash   u64
	version     string
	base        string
	desc        string
	url         string
	packager    string
	arch        string
	build_date  i64
	isize       i64
	licenses    []string
	replaces    []Dependency
	groups      []string
	backup      []BackupFile
	depends     []Dependency
	optdepends  []Dependency
	makedepends []Dependency
	checkdepends []Dependency
	conflicts   []Dependency
	provides    []Dependency
	files       FileList
	origin      PackageOrigin
	scriptlet   bool
}
