// Disk space checking for the ace package manager.
//
// check_diskspace verifies that every filesystem involved in a transaction
// has enough free space to accommodate the install/upgrade while accounting
// for space freed by removals.  It discovers mount points from
// /proc/self/mountinfo, groups file operations by mount point, uses
// os.disk_usage (statvfs) to query available space, and checks for
// read-only filesystems.
//
// Reference: pacman/lib/libalpm/diskspace.c
module trans

import db
import os
import util

// ---------------------------------------------------------------------------
// MountEntry — a single parsed entry from /proc/self/mountinfo
// ---------------------------------------------------------------------------

// MountEntry represents one mount point parsed from /proc/self/mountinfo.
// It carries the mount path, the comma-separated options (rw, ro, noatime,
// etc.), and the filesystem type.
struct MountEntry {
	path    string
	options []string
	fstype  string
}

// ---------------------------------------------------------------------------
// mount_info — parse /proc/self/mountinfo
// ---------------------------------------------------------------------------

// mount_info reads /proc/self/mountinfo and returns a list of MountEntry
// values.  When the file cannot be read (non-Linux or restricted container)
// an empty list is returned so callers degrade gracefully.
//
// /proc/self/mountinfo format (space-separated fields):
//   id parent maj:min root mountpoint options ... - fstype source superopts
//
// The relevant fields are:
//   [4]  mount point
//   [5]  mount options (comma-separated)
//   [sep+1] filesystem type (after the '-' separator)
fn mount_info() []MountEntry {
	content := os.read_file('/proc/self/mountinfo') or { return []MountEntry{} }
	mut entries := []MountEntry{}
	for line in content.split('\n') {
		if line == '' {
			continue
		}
		parts := line.split(' ')
		if parts.len < 10 {
			continue
		}

		// Locate the '-' separator that divides the optional fields
		// from the type/source/superopts triplet.
		mut sep := -1
		for i, p in parts {
			if p == '-' {
				sep = i
				break
			}
		}
		if sep == -1 {
			continue
		}

		mountpoint := parts[4]
		options := parts[5].split(',')
		fstype := parts[sep + 1]

		entries << MountEntry{
			path:    mountpoint
			options: options
			fstype:  fstype
		}
	}
	return entries
}

// ---------------------------------------------------------------------------
// find_mount — longest-prefix mount-point lookup
// ---------------------------------------------------------------------------

// find_mount returns the MountEntry whose path is the longest prefix of
// the given absolute `path`.  When no mount point matches (e.g. the mount
// list is empty), it returns a synthetic root mount entry.
//
// Example: given mounts for "/" and "/home", path "/home/user/file" matches
// "/home" because it has a longer prefix than "/".
fn find_mount(path string, mounts []MountEntry) MountEntry {
	mut best := MountEntry{
		path:    '/'
		options: []string{}
		fstype:  ''
	}
	mut best_len := 0
	for m in mounts {
		// We need a prefix match at a path boundary so that a mount at
		// "/foo" does not claim a path like "/foobar/file".
		if !path.starts_with(m.path) {
			continue
		}
		if m.path.len < best_len {
			continue
		}
		// Verify the boundary: either the lengths are equal (exact match),
		// the path has a slash right after the mount point, or the mount
		// point already ends with a slash.
		if path.len > m.path.len && path[m.path.len] != `/` && !m.path.ends_with('/') {
			continue
		}
		best = m
		best_len = m.path.len
	}
	return best
}

// ---------------------------------------------------------------------------
// is_readonly
// ---------------------------------------------------------------------------

// is_readonly returns true when the mount entry's options contain "ro".
fn (m &MountEntry) is_readonly() bool {
	for opt in m.options {
		if opt == 'ro' {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// check_diskspace — main entry point
// ---------------------------------------------------------------------------

// check_diskspace verifies that every filesystem involved in the transaction
// has sufficient free space to accommodate the install / upgrade of `targets`
// after accounting for space freed by `remove`.
//
// When the Handle's checkspace flag is false the function returns immediately
// without performing any checks.
//
// Parameters:
//   handle  — shared configuration handle (root, cachedirs, dbpath, etc.)
//   targets — packages being installed or upgraded
//   remove  — packages being removed
//
// Returns an error when:
//   - a filesystem needed for writing is read-only
//   - a filesystem has insufficient free space
//   - disk usage cannot be queried
//
// Reference: pacman check_diskspace() at diskspace.c.
pub fn check_diskspace(handle &util.Handle, targets []&db.Package, remove []&db.Package) ! {
	if !handle.checkspace {
		return
	}

	mounts := mount_info()
	if mounts.len == 0 {
		return
	}

	// needed and freed track bytes per mount point path.
	mut needed := map[string]i64{}
	mut freed := map[string]i64{}

	// -----------------------------------------------------------------------
	// 1. Register every path the transaction will touch so we know which
	//    mount points must be checked.  At this stage no bytes are added;
	//    we simply ensure each relevant mount point appears in the maps.
	// -----------------------------------------------------------------------
	register_path(handle.root, mut needed, mounts)
	register_path(handle.resolved_dbpath(), mut needed, mounts)
	register_path(handle.logfile, mut needed, mounts)
	register_path(handle.resolved_gpgdir(), mut needed, mounts)
	for cd in handle.resolved_cachedirs() {
		register_path(cd, mut needed, mounts)
	}
	for hd in handle.resolved_hookedirs() {
		register_path(hd, mut needed, mounts)
	}

	// -----------------------------------------------------------------------
	// 2. Account for packages being installed / upgraded.
	//    - isize goes to the mount point containing root (installed files).
	//    - download_size goes to the mount point of each cache directory.
	// -----------------------------------------------------------------------
	for t in targets {
		// Installed-file footprint lands on root's mount.
		root_mp := find_mount(handle.root, mounts)
		needed[root_mp.path] += t.isize

		// Download footprint lands on each cache directory's mount.
		for cd in handle.resolved_cachedirs() {
			cache_mp := find_mount(cd, mounts)
			needed[cache_mp.path] += t.download_size
		}
	}

	// -----------------------------------------------------------------------
	// 3. Account for space freed by removals.
	//    Removed packages free isize bytes on root's mount.
	// -----------------------------------------------------------------------
	for r in remove {
		root_mp := find_mount(handle.root, mounts)
		freed[root_mp.path] += r.isize
	}

	// -----------------------------------------------------------------------
	// 4. Verify each mount point.
	// -----------------------------------------------------------------------
	for mp_path, need in needed {
		mp := find_mount(mp_path, mounts)

		// Read-only detection.
		if mp.is_readonly() && need > 0 {
			return error('cannot write files to read-only filesystem at ${mp.path}')
		}

		usage := os.disk_usage(mp.path) or {
			return error('cannot read disk usage for ${mp.path}: ${err}')
		}

		free_amt := freed[mp_path] or { 0 }
		available := i64(usage.available) + free_amt

		if need > available {
			return error('not enough free disk space on ${mp.path}: ' +
				'need ${need} bytes, ${available} bytes available')
		}
	}
}

// ---------------------------------------------------------------------------
// register_path — ensure a mount point is tracked
// ---------------------------------------------------------------------------

// register_path ensures the mount point containing `path` has a zero entry in
// the needed map, so it is checked even when no package bytes land on it.
fn register_path(path string, mut needed map[string]i64, mounts []MountEntry) {
	if path == '' {
		return
	}
	mp := find_mount(path, mounts)
	if mp.path !in needed {
		needed[mp.path] = 0
	}
}
