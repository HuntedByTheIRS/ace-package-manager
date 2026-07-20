// Module: download — sandbox for privilege-dropped downloads.
//
// Provides sandbox support for downloading packages as a non-root
// user, mirroring the pacman/lib/libalpm/sandbox.c implementation.
//
// When configured, the download engine drops privileges to the
// DownloadUser before making HTTP requests, limiting the blast
// radius of a compromised mirror or malicious package.
//
// Reference:
//   pacman/lib/libalpm/sandbox.c       — _alpm_use_sandbox, alpm_sandbox_setup_child
//   pacman/lib/libalpm/sandbox_fs.c    — Landlock filesystem restrictions
//   pacman/lib/libalpm/sandbox_syscalls.c — seccomp syscall filtering
//   pacman/lib/libalpm/handle.h        — handle->sandboxuser, disable_sandbox* fields
module download

import lib
import os
import util

// ---------------------------------------------------------------
// SandboxConfig describes the sandbox settings for a download
// operation.  It is derived from the util.Handle at download time.
// ---------------------------------------------------------------
pub struct SandboxConfig {
pub:
	// DownloadUser is the UNIX user name to drop privileges to.
	// When empty, no privilege dropping occurs.
	download_user string
	// DisableSandbox completely skips sandboxing regardless of
	// other settings.
	disable_sandbox bool
	// DisableSandboxFilesystem skips Landlock-style filesystem
	// restrictions (but still drops privileges).
	disable_sandbox_fs bool
	// DisableSandboxSyscalls skips seccomp-style syscall
	// filtering (but still drops privileges).
	disable_sandbox_sys bool
}

// ---------------------------------------------------------------
// sandbox_config_from_handle extracts sandbox settings from a
// util.Handle.  This is the standard way to create a SandboxConfig.
// ---------------------------------------------------------------
pub fn sandbox_config_from_handle(handle &util.Handle) SandboxConfig {
	return SandboxConfig{
		download_user:     handle.download_user
		disable_sandbox:   handle.disable_sandbox
		disable_sandbox_fs: handle.disable_sandbox_fs
		disable_sandbox_sys: handle.disable_sandbox_sys
	}
}

// ---------------------------------------------------------------
// use_sandbox returns true when sandboxing should be active for
// the given config.
//
// The pacman logic (sandbox.c:_alpm_use_sandbox) is:
//   use_sandbox = (uid == 0)                           // running as root
//              && (sandboxuser != NULL)                  // a user is configured
//              && (!disable_sandbox_filesystem || !disable_sandbox_syscalls)
//                                                        // at least one restriction is active
//
// We extend this slightly: if the handle explicitly disables
// sandbox, never use it.  Likewise if no download_user is set,
// there is nothing to do.
// ---------------------------------------------------------------
pub fn use_sandbox(cfg SandboxConfig) bool {
	if cfg.disable_sandbox {
		return false
	}

	if cfg.download_user == '' {
		return false
	}

	// Sandboxing requires root to drop privileges.
	if os.getuid() != 0 {
		return false
	}

	// Must have at least one restriction enabled to be useful.
	if cfg.disable_sandbox_fs && cfg.disable_sandbox_sys {
		return false
	}

	return true
}

// ---------------------------------------------------------------
// drop_privileges attempts to drop root privileges to the
// configured DownloadUser.
//
// This mirrors the core of alpm_sandbox_setup_child() but
// does not implement Landlock/seccomp (those are kernel-level
// and require C helpers — they will be added in a future phase).
//
// Delegates the actual setuid/setgid calls to lib.drop_root_privileges
// to maintain C-interop isolation (C FFI only in lib/).
//
// Callers must check use_sandbox() first and only call this
// when running as root.
// ---------------------------------------------------------------
pub fn drop_privileges(cfg SandboxConfig) ! {
	if cfg.download_user == '' {
		return error('drop_privileges: no DownloadUser configured')
	}

	// Resolve the user name to a UID/GID by parsing /etc/passwd.
	pw := lookup_user(cfg.download_user) or {
		return error('drop_privileges: user "${cfg.download_user}" not found: ${err.msg()}')
	}

	// Delegate to the lib wrapper (which has the C FFI).
	lib.drop_root_privileges(pw.uid, pw.gid) or {
		return error('drop_privileges: ${err.msg()}')
	}
}

// ---------------------------------------------------------------
// PasswdEntry represents a single line from /etc/passwd.
// ---------------------------------------------------------------
struct PasswdEntry {
	username string
	uid      int
	gid      int
	home     string
	shell    string
}

// lookup_user resolves a username to a PasswdEntry by parsing
// /etc/passwd.  This avoids a C FFI dependency for getpwnam.
fn lookup_user(username string) !PasswdEntry {
	content := os.read_lines('/etc/passwd') or {
		return error('cannot read /etc/passwd: ${err.msg()}')
	}

	for line in content {
		fields := line.split(':')
		if fields.len < 7 {
			continue
		}
		if fields[0] == username {
			uid_val := fields[2].int()
			gid_val := fields[3].int()
			// Defend against malformed /etc/passwd with non-numeric UID/GID:
			// .int() returns 0 on failure, which silently maps to root.
			if uid_val == 0 && fields[2] != '0' {
				return error('invalid UID in /etc/passwd for ${username}: "${fields[2]}"')
			}
			if gid_val == 0 && fields[3] != '0' {
				return error('invalid GID in /etc/passwd for ${username}: "${fields[3]}"')
			}
			return PasswdEntry{
				username: fields[0]
				uid:      uid_val
				gid:      gid_val
				home:     fields[5]
				shell:    fields[6]
			}
		}
	}

	return error('user "${username}" not found in /etc/passwd')
}

// ---------------------------------------------------------------
// sanitize_download_path verifies that the download destination
// is within the allowed sandbox path (when filesystem sandboxing
// is active).  This is a pure-V analog of the Landlock path
// restriction in sandbox_fs.c.
// ---------------------------------------------------------------
pub fn sanitize_download_path(dest_path string, allowed_prefixes []string) ! {
	if allowed_prefixes.len == 0 {
		return // no restrictions
	}

	for prefix in allowed_prefixes {
		if dest_path.starts_with(prefix) {
			return
		}
	}

	return error('download path "${dest_path}" is outside allowed sandbox directories')
}
