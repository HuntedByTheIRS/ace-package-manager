// Package conflict detection for the ace package manager.
//
// Implements the conflict-checking and auto-resolution logic that mirrors
// pacman/lib/libalpm/conflict.c.
//
// Three functions form the API:
//   check_inner_conflicts — conflicts within the target list itself
//   check_outer_conflicts — conflicts between targets and installed packages
//   resolve_conflicts    — auto-resolve conflicts via replaces
module trans

import db
import os
import util

// ---------------------------------------------------------------------------
// ConflictResolution
// ---------------------------------------------------------------------------

// ConflictResolution records the outcome of attempting to resolve a package
// conflict.  When remove_pkg is non-empty the conflict can be auto-resolved by
// removing that package (the installed side that is being replaced).  When
// remove_pkg is empty the conflict could not be auto-resolved.
pub struct ConflictResolution {
pub:
	package1   string
	package2   string
	reason     &db.Dependency
	remove_pkg string
}

// ---------------------------------------------------------------------------
// Helpers — O(1) hash-based name lookups
// ---------------------------------------------------------------------------

// provided_hashes returns a set of name_hash values for everything a package
// provides: its own name plus every entry in its provides list.
//
// This enables O(1) conflict matching: instead of comparing strings we probe
// the set with the name_hash of each conflict dependency.
fn provided_hashes(pkg &db.Package) map[u64]bool {
	mut result := map[u64]bool{}
	result[pkg.name_hash] = true
	for dep in pkg.provides {
		result[dep.name_hash] = true
	}
	return result
}

// ---------------------------------------------------------------------------
// check_inner_conflicts
// ---------------------------------------------------------------------------

// check_inner_conflicts detects conflicts between packages that are all in
// the transaction target list.
//
// For every unordered pair (A, B) with A != B:
//  1. If any of A's conflicts entries names B (or anything B provides) → conflict.
//  2. If any of B's conflicts entries names A (or anything A provides) → conflict.
//  3. If A and B both provide the same virtual package name → provider conflict.
pub fn check_inner_conflicts(targets []&db.Package) []db.Conflict {
	mut conflicts := []db.Conflict{}

	// Pre-build provided-hash sets for every target.
	mut provsets := []map[u64]bool{len: targets.len}
	for i, pkg in targets {
		provsets[i] = provided_hashes(pkg)
	}

	for i in 0 .. targets.len {
		for j in i + 1 .. targets.len {
			a := targets[i]

			// A's conflicts vs B's provides
			for ci in 0 .. a.conflicts.len {
				dep := a.conflicts[ci]
				if dep.name_hash in provsets[j] {
					conflicts << db.Conflict{
						package1: a.name
						package2: targets[j].name
						reason: &db.Dependency{
							name:      dep.name
							name_hash: dep.name_hash
							version:   dep.version
							modifier:  dep.modifier
							desc:      dep.desc
						}
					}
				}
			}

			// B's conflicts vs A's provides
			b := targets[j]
			for cj in 0 .. b.conflicts.len {
				dep := b.conflicts[cj]
				if dep.name_hash in provsets[i] {
					conflicts << db.Conflict{
						package1: b.name
						package2: a.name
						reason: &db.Dependency{
							name:      dep.name
							name_hash: dep.name_hash
							version:   dep.version
							modifier:  dep.modifier
							desc:      dep.desc
						}
					}
				}
			}

			// Provider conflicts — both provide the same virtual name.
			for pa in a.provides {
				for pb in b.provides {
					if pa.name_hash == pb.name_hash {
						conflicts << db.Conflict{
							package1: a.name
							package2: b.name
							reason: &db.Dependency{
								name:      pa.name
								name_hash: pa.name_hash
								version:   pa.version
								modifier:  pa.modifier
								desc:      pa.desc
							}
						}
					}
				}
			}
		}
	}

	return conflicts
}

// ---------------------------------------------------------------------------
// check_outer_conflicts
// ---------------------------------------------------------------------------

// check_outer_conflicts detects conflicts between transaction targets and
// packages that are already installed in the local database.
//
// For every target T and every installed package I:
//  1. If T's conflicts list names I (or anything I provides) → conflict
//     (T conflicts with installed I).
//  2. If I's conflicts list names T (or anything T provides) → conflict
//     (installed I conflicts with target T).
//
// Packages whose name exactly matches a target name are skipped (they are
// being upgraded / replaced, not conflicting).
pub fn check_outer_conflicts(targets []&db.Package, localdb &db.Database) []db.Conflict {
	mut conflicts := []db.Conflict{}

	for t in targets {
		t_prov := provided_hashes(t)

		for installed_name, installed in localdb.pkgcache {
			// Skip if the installed package has the same name as the target
			// — that is an upgrade / reinstall, not a conflict.
			if installed_name == t.name {
				continue
			}

			i_prov := provided_hashes(installed)

			// Target's conflicts vs installed package's provides
			for ci in 0 .. t.conflicts.len {
				dep := t.conflicts[ci]
				if dep.name_hash in i_prov {
					conflicts << db.Conflict{
						package1: t.name
						package2: installed.name
						reason: &db.Dependency{
							name:      dep.name
							name_hash: dep.name_hash
							version:   dep.version
							modifier:  dep.modifier
							desc:      dep.desc
						}
					}
				}
			}

			// Installed package's conflicts vs target's provides
			for ci in 0 .. installed.conflicts.len {
				dep := installed.conflicts[ci]
				if dep.name_hash in t_prov {
					conflicts << db.Conflict{
						package1: installed.name
						package2: t.name
						reason: &db.Dependency{
							name:      dep.name
							name_hash: dep.name_hash
							version:   dep.version
							modifier:  dep.modifier
							desc:      dep.desc
						}
					}
				}
			}
		}
	}

	return conflicts
}

// ---------------------------------------------------------------------------
// resolve_conflicts
// ---------------------------------------------------------------------------

// resolve_conflicts attempts to auto-resolve every conflict in the list.
//
// A conflict is auto-resolvable when one of the two packages involved has the
// other's name in its replaces list.  In that case the replaced package can
// be removed and the conflict disappears.
//
// Returns none if any conflict is NOT auto-resolvable (the caller should
// treat these as hard errors).  When every conflict is resolved the return
// value lists the resolutions.
//
// Provider-based conflicts (two targets providing the same virtual package)
// are auto-resolvable only if one of them carries an explicit replaces entry
// for the other; otherwise they are surfaced as errors (→ none).
pub fn resolve_conflicts(conflicts []db.Conflict, targets []&db.Package, localdb &db.Database) ?[]ConflictResolution {
	// Build name → &Package lookup for O(1) access to replaces lists.
	mut tmap := map[string]&db.Package{}
	for t in targets {
		tmap[t.name] = t
	}

	mut resolutions := []ConflictResolution{}

	for c in conflicts {
		mut found := false

		// Check if package1 (as a target) replaces package2.
		if pkg := tmap[c.package1] {
			for r in pkg.replaces {
				if r.name_hash == db.compute_name_hash(c.package2) {
					resolutions << ConflictResolution{
						package1:   c.package1
						package2:   c.package2
						reason:     c.reason
						remove_pkg: c.package2
					}
					found = true
					break
				}
			}
		}

		// If not yet resolved, check if package2 (as a target) replaces
		// package1.
		if !found {
			if pkg := tmap[c.package2] {
				for r in pkg.replaces {
					if r.name_hash == db.compute_name_hash(c.package1) {
						resolutions << ConflictResolution{
							package1:   c.package2
							package2:   c.package1
							reason:     c.reason
							remove_pkg: c.package1
						}
						found = true
						break
					}
				}
			}
		}

		// For outer conflicts: also check installed (non-target) packages
		// for replaces entries that could resolve the conflict.
		if !found {
			for _, installed in localdb.pkgcache {
				for r in installed.replaces {
					if r.name_hash == db.compute_name_hash(c.package1) || r.name_hash == db.compute_name_hash(c.package2) {
						// The installed package replaces one of the conflicting parties.
						// Resolve by keeping the target with the higher priority.
						resolutions << ConflictResolution{
							package1:   c.package1
							package2:   c.package2
							reason:     c.reason
							remove_pkg: c.package2
						}
						found = true
						break
					}
				}
				if found { break }
			}
		}

		if !found {
			// Neither package replaces the other — cannot auto-resolve.
			return none
		}
	}

	return resolutions
}

// ============================================================================
// File conflict detection
// Reference: pacman/lib/libalpm/conflict.c:462-686, filelist.c
// ============================================================================

// ---------------------------------------------------------------------------
// File-list helpers (sorted merge, O(n+m))
// ---------------------------------------------------------------------------

// pathcmp compares two file paths for sorted-merge operations, treating a
// trailing '/' as optional.  "foo" and "foo/" compare equal so that directory
// entries in one list match the corresponding non-directory entry in another.
fn pathcmp(a string, b string) int {
	mut i := 0
	for i < a.len && i < b.len && a[i] == b[i] {
		i++
	}
	// If one string has ended while the other has a trailing '/', skip it.
	if i >= a.len && i < b.len && b[i] == `/` {
		i++
	} else if i >= b.len && i < a.len && a[i] == `/` {
		i++
	}
	if i >= a.len && i >= b.len {
		return 0
	}
	if i >= a.len {
		return -1
	}
	if i >= b.len {
		return 1
	}
	return int(a[i]) - int(b[i])
}

// filelist_intersection returns file paths present in both sorted arrays,
// using an O(n+m) two-pointer merge.  Pairs where both sides are directories
// (end with '/') are excluded — pure directory overlaps are not conflicts.
//
// Both inputs MUST be sorted in ascending byte-lexicographic order.
fn filelist_intersection(files_a []string, files_b []string) []string {
	mut result := []string{}
	mut ctr_a := 0
	mut ctr_b := 0
	for ctr_a < files_a.len && ctr_b < files_b.len {
		str_a := files_a[ctr_a]
		str_b := files_b[ctr_b]
		cmp := pathcmp(str_a, str_b)
		if cmp < 0 {
			ctr_a++
		} else if cmp > 0 {
			ctr_b++
		} else {
			// Same path — only flag as conflict if at least one side is
			// NOT a directory (pure dir-dir overlaps are harmless).
			if !str_a.ends_with('/') || !str_b.ends_with('/') {
				result << str_a
			}
			ctr_a++
			ctr_b++
		}
	}
	return result
}

// filelist_difference returns file paths present in `files_a` but NOT in
// `files_b`, using an O(n+m) two-pointer merge.
//
// Both inputs MUST be sorted in ascending byte-lexicographic order.
fn filelist_difference(files_a []string, files_b []string) []string {
	mut result := []string{}
	mut ctr_a := 0
	mut ctr_b := 0
	for ctr_a < files_a.len && ctr_b < files_b.len {
		str_a := files_a[ctr_a]
		str_b := files_b[ctr_b]
		cmp := pathcmp(str_a, str_b)
		if cmp < 0 {
			result << str_a
			ctr_a++
		} else if cmp > 0 {
			ctr_b++
		} else {
			ctr_a++
			ctr_b++
		}
	}
	// Drain any remaining entries from A.
	for ctr_a < files_a.len {
		result << files_a[ctr_a]
		ctr_a++
	}
	return result
}

// filelist_contains checks whether `name` exists in the sorted `files` array
// using binary search (O(log n)).
fn filelist_contains(files []string, name string) bool {
	mut low := 0
	mut high := files.len - 1
	for low <= high {
		mid := low + (high - low) / 2
		mid_name := files[mid]
		if mid_name == name {
			return true
		}
		if mid_name < name {
			low = mid + 1
		} else {
			high = mid - 1
		}
	}
	return false
}

// can_overwrite_file checks whether a file matches any pattern in the
// handle's overwrite_files list.  Supports negation via `!` prefix — the
// last-matching pattern wins (positive or negative).  Both the bare relative
// path and the root-anchored path are tested against each pattern.
//
// Reference: _alpm_can_overwrite_file / _alpm_fnmatch_patterns from
// pacman/lib/libalpm/conflict.c:385-389.
fn can_overwrite_file(handle &util.Handle, file string, rooted_path string) bool {
	patterns := handle.overwrite_files
	if patterns.len == 0 {
		return false
	}
	// Walk the list backwards so that later (command-line) patterns override
	// earlier (config-file) patterns, matching pacman's behaviour.
	for idx := patterns.len - 1; idx >= 0; idx-- {
		pattern := patterns[idx]
		mut inverted := false
		mut pat := pattern
		if pat.starts_with('!') {
			inverted = true
			pat = pat[1..]
		} else if pat.starts_with('\\') && pat.len > 1 && pat[1] == `!` {
			pat = pat[1..]
		}
		// Check both the bare relative path and the root-anchored path.
		if fnmatch(pat, file) || fnmatch(pat, rooted_path) {
			return !inverted
		}
	}
	return false
}

// sorted_file_names extracts file names from a FileList and returns them
// sorted in ascending byte-lexicographic order (strcmp order).
fn sorted_file_names(fl &db.FileList) []string {
	mut names := []string{len: fl.files.len}
	for i in 0 .. fl.files.len {
		names[i] = fl.files[i].name
	}
	names.sort()
	return names
}

// ---------------------------------------------------------------------------
// check_file_conflicts
// Reference: pacman/lib/libalpm/conflict.c:462-686  (_alpm_db_find_fileconflicts)
// ---------------------------------------------------------------------------

// check_file_conflicts detects file conflicts that would arise from a
// transaction:
//
//   CHECK 1 — target vs target: files that are present in two (or more)
//             packages in the target list simultaneously.
//
//   CHECK 2 — target vs filesystem: files that a target package wants to
//             install but that already exist on the filesystem (and will not
//             be overwritten per the user's --overwrite patterns).
//
// Overwrite globs: when a file matches an entry in the handle's
// overwrite_files list and both sides are regular files (not directory vs
// file), the conflict is suppressed — the file will simply be overwritten.
//
// Directory conflicts: when one side has a regular file and the other has a
// directory at the same path, a conflict is always raised regardless of
// overwrite patterns.
//
// Returns the list of file conflicts, or none on internal error.
pub fn check_file_conflicts(handle &util.Handle, targets []&db.Package, localdb &db.Database) ?[]db.FileConflict {
	if targets.len == 0 {
		return []db.FileConflict{}
	}

	root := handle.root
	mut conflicts := []db.FileConflict{}

	// Pre-extract and sort the file list for each target so that we only
	// sort once (shared by CHECK 1 and CHECK 2).
	mut sorted_files := [][]string{len: targets.len}
	for i, t in targets {
		sorted_files[i] = sorted_file_names(&t.files)
	}

	// ---- CHECK 1: target vs target --------------------------------------
	for i in 0 .. targets.len {
		files_i := sorted_files[i]
		if files_i.len == 0 {
			continue
		}
		for j in i + 1 .. targets.len {
			files_j := sorted_files[j]
			if files_j.len == 0 {
				continue
			}

			common := filelist_intersection(files_i, files_j)
			for fname in common {
				path := os.join_path(root, fname)

				// Skip when the user asked to overwrite this file AND it
				// exists as a regular file (not a directory) in the other
				// package.  This matches pacman: the `alpm_filelist_contains`
				// call checks exact-byte presence which fails for trailing
				// slash, so dir-vs-file conflicts are never skipped.
				if can_overwrite_file(handle, fname, path) && filelist_contains(files_j,
					fname) {
					continue
				}

				conflicts << db.FileConflict{
					target:        targets[i].name
					file:          path
					ctarget:       targets[j].name
					conflict_type: .target
				}
			}
		}
	}

	// ---- CHECK 2: target vs filesystem -----------------------------------
	for i, t in targets {
		files_t := sorted_files[i]
		if files_t.len == 0 {
			continue
		}

		// When an older version of the package is already installed, only
		// check files that are NEW in this version (not present in the old
		// file list).  Otherwise check every file of the package.
		mut newfiles := []string{}
		if installed := localdb.pkgcache[t.name] {
			newfiles = filelist_difference(files_t, sorted_file_names(&installed.files))
		} else {
			newfiles = files_t.clone()
		}

		for fname in newfiles {
			// Strip trailing slash for filesystem checks — stat() on a path with
			// trailing slash expects a directory and fails with ENOTDIR for regular files.
			pkg_is_dir := fname.ends_with('/')
			fs_name := if pkg_is_dir { fname.trim_right('/') } else { fname }
			path := os.join_path(root, fs_name)

			// Skip if nothing exists at that path on the filesystem.
			if !os.exists(path) {
				continue
			}

			is_dir_on_fs := os.is_dir(path)

			if pkg_is_dir && is_dir_on_fs {
				// Both sides are directories — not a conflict.
				continue
			}

			// Check overwrite globs.  For directory-in-package vs file-on-fs
			// (or vice versa) the overwrite is never allowed — pacman does
			// not allow --overwrite to replace a directory with a file.
			if !(pkg_is_dir != is_dir_on_fs)
				&& can_overwrite_file(handle, fname, path) {
				continue
			}

			// Determine the conflict type and the "other" package name.
			mut ctarget := ''
			mut ctype := db.FileConflictType.filesystem
			for k, other in targets {
				if k == i {
					continue
				}
				if filelist_contains(sorted_files[k], fname) {
					// The file is claimed by another target package too.
					ctarget = other.name
					ctype = .target
					break
				}
			}

			conflicts << db.FileConflict{
				target:        t.name
				file:          path
				ctarget:       ctarget
				conflict_type: ctype
			}
		}
	}

	return conflicts
}
