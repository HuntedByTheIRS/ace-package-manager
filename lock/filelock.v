// Module: lock — file-level locking for the ace package manager.
//
// LockFile provides exclusive, process-safe locking using O_CREAT|O_EXCL
// semantics, matching pacman's approach.  The lock is a sentinel file at
// {dbpath}/db.lck containing the PID of the owning process.  Stale locks
// (dead owner) are detected and removed automatically.
module lock

import os

// ---------- C declarations for atomic file creation ----------

fn C.open(path &char, flags int, mode int) int
fn C.write(fd int, buf &char, count int) int
fn C.close(fd int) int

// ---------- LockFile ----------

// LockFile is an exclusive file lock.
// @[heap] prevents V's value semantics from copying the struct, which
// would let multiple owners attempt to release the same lock.
@[heap]
pub struct LockFile {
mut:
	locked bool   // true after a successful acquire
	dbpath string // database path passed to acquire()
}

// acquire creates the lock file at {dbpath}/db.lck atomically.
// If the file already exists and the PID it contains belongs to a
// dead process, the stale lock is removed and acquisition is retried.
// Returns an error if the database is genuinely locked by a live process.
pub fn (mut lf LockFile) acquire(dbpath string) ! {
	if lf.locked {
		return error('lock: already locked by this LockFile instance')
	}

	lockpath := os.join_path(dbpath, 'db.lck')

	// Ensure the parent directory exists.
	if !os.exists(dbpath) {
		os.mkdir_all(dbpath)!
	}

	// Atomic create-or-fail via O_CREAT | O_EXCL.
	mut fd := C.open(lockpath.str, C.O_CREAT | C.O_EXCL | C.O_RDWR, 0o644)

	if fd == -1 {
		// The file already exists — check for a stale lock.
		if os.exists(lockpath) {
			stale := is_stale(lockpath)
			if stale {
				os.rm(lockpath)!
				// Retry once.
				fd = C.open(lockpath.str, C.O_CREAT | C.O_EXCL | C.O_RDWR, 0o644)
				if fd == -1 {
					return error('lock: failed to acquire lock after removing stale lock')
				}
			} else {
				// Read the PID for the error message.
				content := os.read_file(lockpath) or { '' }
				pid := content.trim_space().int()
				if pid > 0 {
					return error('lock: database is locked by process ${pid}')
				}
				return error('lock: database is locked (corrupt lock file)')
			}
		} else {
			// O_EXCL failed even though the file does not exist —
			// this should not happen on a normal filesystem.
			return error('lock: failed to acquire lock (O_EXCL failed unexpectedly)')
		}
	}

	// Write our PID into the lock file.
	pid_str := '${os.getpid()}\n'
	C.write(fd, pid_str.str, pid_str.len)
	C.close(fd)

	lf.locked = true
	lf.dbpath = dbpath
}

// release removes the lock file.  Safe to call multiple times.
pub fn (mut lf LockFile) release() {
	if !lf.locked {
		return
	}
	lockpath := os.join_path(lf.dbpath, 'db.lck')
	os.rm(lockpath) or {}
	lf.locked = false
	lf.dbpath = ''
}

// is_locked reports whether the database at dbpath is currently locked
// by a live process.
pub fn is_locked(dbpath string) bool {
	lockpath := os.join_path(dbpath, 'db.lck')
	if !os.exists(lockpath) {
		return false
	}
	content := os.read_file(lockpath) or { return false }
	pid := content.trim_space().int()
	if pid <= 0 {
		return false
	}
	return pid_is_alive(pid)
}

// ---------- internal helpers ----------

// is_stale returns true when the lock file exists but the PID inside it
// does not correspond to a running process.
fn is_stale(lockpath string) bool {
	content := os.read_file(lockpath) or { return false }
	pid := content.trim_space().int()
	if pid <= 0 {
		// Corrupt file — treat as stale so the caller cleans it up.
		return true
	}
	return !pid_is_alive(pid)
}

// pid_is_alive checks whether a process with the given PID is running by
// probing /proc/{pid}/ (Linux).
fn pid_is_alive(pid int) bool {
	proc_path := '/proc/${pid}'
	return os.exists(proc_path) && os.is_dir(proc_path)
}
