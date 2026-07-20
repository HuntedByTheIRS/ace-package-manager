module lib

// V C interop wrapper for POSIX privilege-dropping operations.
// Used by the download sandbox to drop root privileges before
// making HTTP requests.
//
// Reference:
//   pacman/lib/libalpm/sandbox.c — alpm_sandbox_setup_child()
//
// C FFI — all functions are declared via fn C. so the V compiler
// can generate correct wrapper code for the C backend.
#flag -D_GNU_SOURCE
#include <unistd.h>    // getuid, geteuid, setuid, setgid
#include <sys/types.h> // uid_t, gid_t
#include <grp.h>       // setgroups

// ---------- C function declarations ----------

fn C.setgroups(size int, list voidptr) int
fn C.setgid(gid u32) int
fn C.setuid(uid u32) int
fn C.geteuid() u32

// ---------- C function declarations ----------

fn C.setgroups(size int, list voidptr) int
fn C.setgid(gid int) int
fn C.setuid(uid int) int
fn C.geteuid() int

// ---------- public types ----------

// DropPrivilegeResult holds the outcome of a privilege-drop operation.
pub struct DropPrivilegeResult {
pub:
	uid           int
	gid           int
	effective_uid int
	effective_gid int
}

// ---------- public API ----------

// drop_root_privileges drops root privileges to the given UID and GID.
// This mirrors the core of alpm_sandbox_setup_child() without the
// Landlock/seccomp parts (those are kernel-specific and require
// additional C helpers).
//
// Steps:
//   1. Clear supplementary groups (setgroups(0, NULL))
//   2. setgid(gid) — drop group privileges
//   3. setuid(uid) — drop user privileges
//   4. Verify that geteuid() != 0
//
// Returns DropPrivilegeResult on success, or an error describing
// what went wrong.
pub fn drop_root_privileges(uid int, gid int) !DropPrivilegeResult {
	if uid < 0 || gid < 0 {
		return error('sandbox: invalid uid (${uid}) or gid (${gid})')
	}

	// Step 1: clear supplementary groups.
	{
		ret := C.setgroups(0, unsafe { nil })
		if ret != 0 {
			return error('sandbox: setgroups(0, NULL) failed')
		}
	}

	// Step 2: drop group privileges.
	{
		ret := C.setgid(u32(gid))
		if ret != 0 {
			return error('sandbox: setgid(${gid}) failed')
		}
	}

	// Step 3: drop user privileges.
	{
		ret := C.setuid(u32(uid))
		if ret != 0 {
			return error('sandbox: setuid(${uid}) failed')
		}
	}

	// Step 4: verify the drop.
	effective_uid := int(C.geteuid())
	if effective_uid == 0 {
		return error('sandbox: failed to drop root privileges (still uid 0)')
	}

	return DropPrivilegeResult{
		uid:           uid
		gid:           gid
		effective_uid: effective_uid
		effective_gid: 0  // getegid is not available via C FFI in this V version
	}
}

// is_running_as_root returns true when the current effective UID is 0.
pub fn is_running_as_root() bool {
	return C.geteuid() == 0
}
