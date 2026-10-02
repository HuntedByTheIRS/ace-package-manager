module archive

// ArchiveEntry wraps a libarchive archive_entry C struct.
// Owns the underlying C pointer and frees it on free().
@[heap]
pub struct ArchiveEntry {
pub:
	inner &C.struct_archive_entry
}

// new_entry creates a new empty ArchiveEntry.
pub fn new_entry() &ArchiveEntry {
	ptr := C.archive_entry_new()
	return &ArchiveEntry{inner: ptr}
}

// pathname returns the entry's pathname as an owned V string.
pub fn (e &ArchiveEntry) pathname() string {
	if unsafe { e.inner == nil } {
		return ''
	}
	return unsafe { cstring_to_vstring(C.archive_entry_pathname(e.inner)) }
}

// size returns the entry's size in bytes.
pub fn (e &ArchiveEntry) size() i64 {
	if unsafe { e.inner == nil } {
		return 0
	}
	return C.archive_entry_size(e.inner)
}

// filetype returns the entry's file type (AE_IFREG, AE_IFDIR, AE_IFLNK, etc.).
pub fn (e &ArchiveEntry) filetype() u32 {
	if unsafe { e.inner == nil } {
		return 0
	}
	return C.archive_entry_filetype(e.inner)
}

// mode returns the entry's full mode (filetype + permissions).
pub fn (e &ArchiveEntry) mode() u32 {
	if unsafe { e.inner == nil } {
		return 0
	}
	return C.archive_entry_mode(e.inner)
}

// perm returns the entry's permission bits.
pub fn (e &ArchiveEntry) perm() u32 {
	if unsafe { e.inner == nil } {
		return 0
	}
	return C.archive_entry_perm(e.inner)
}

// uid returns the entry's owner user ID.
pub fn (e &ArchiveEntry) uid() i64 {
	if unsafe { e.inner == nil } {
		return 0
	}
	return C.archive_entry_uid(e.inner)
}

// gid returns the entry's owner group ID.
pub fn (e &ArchiveEntry) gid() i64 {
	if unsafe { e.inner == nil } {
		return 0
	}
	return C.archive_entry_gid(e.inner)
}

// uname returns the entry's owner user name.
pub fn (e &ArchiveEntry) uname() string {
	if unsafe { e.inner == nil } {
		return ''
	}
	return unsafe { cstring_to_vstring(C.archive_entry_uname(e.inner)) }
}

// gname returns the entry's owner group name.
pub fn (e &ArchiveEntry) gname() string {
	if unsafe { e.inner == nil } {
		return ''
	}
	return unsafe { cstring_to_vstring(C.archive_entry_gname(e.inner)) }
}

// mtime returns the entry's modification time as Unix timestamp.
pub fn (e &ArchiveEntry) mtime() i64 {
	if unsafe { e.inner == nil } {
		return 0
	}
	return C.archive_entry_mtime(e.inner)
}

// is_dir returns true if the entry is a directory.
pub fn (e &ArchiveEntry) is_dir() bool {
	t := e.filetype()
	return t == u32(ae_ifdir)
}

// is_file returns true if the entry is a regular file.
pub fn (e &ArchiveEntry) is_file() bool {
	t := e.filetype()
	return t == u32(ae_ifreg)
}

// is_symlink returns true if the entry is a symbolic link.
pub fn (e &ArchiveEntry) is_symlink() bool {
	t := e.filetype()
	return t == u32(ae_iflnk)
}

// symlink returns the symlink target path, or empty string if not a symlink.
pub fn (e &ArchiveEntry) symlink() string {
	if unsafe { e.inner == nil } {
		return ''
	}
	return unsafe { cstring_to_vstring(C.archive_entry_symlink(e.inner)) }
}

// hardlink returns the hardlink target path, or empty string if not a hardlink.
pub fn (e &ArchiveEntry) hardlink() string {
	if unsafe { e.inner == nil } {
		return ''
	}
	return unsafe { cstring_to_vstring(C.archive_entry_hardlink(e.inner)) }
}

// strmode returns a string representation of the entry's mode (e.g. "-rwxr-xr-x").
pub fn (e &ArchiveEntry) strmode() string {
	if unsafe { e.inner == nil } {
		return ''
	}
	return unsafe { cstring_to_vstring(C.archive_entry_strmode(e.inner)) }
}

// free releases the underlying C archive_entry.
pub fn (e &ArchiveEntry) free() {
	if unsafe { e.inner != nil } {
		C.archive_entry_free(e.inner)
		// Note: V doesn't allow setting inner to nil after free due to &T being non-nil
	}
}
