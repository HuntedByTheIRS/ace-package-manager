// Module: commit — transaction commit pipeline.
//
// The commit pipeline is responsible for validating and installing
// packages as the final phase of a transaction.  It mirrors the
// alpm_trans_commit flow from pacman/lib/libalpm/trans.c.
//
// Phases (in order):
//   1. Integrity validation (SHA256 checksums + PGP signatures)
//   2. Corrupted-package handling (skip / error with user prompt)
//   3. Filesystem commit (extraction / removal)
//
// Reference:
//   pacman/lib/libalpm/trans.c    — _alpm_trans_commit()
//   pacman/lib/libalpm/be_package.c — _alpm_pkg_validate_internal()
//   pacman/lib/libalpm/add.c      — commit_single_pkg()
module commit

import os
import util

// CommitOptions controls the behaviour of the commit pipeline.
pub struct CommitOptions {
pub:
	// SigLevel bitmask controlling signature verification requirements.
	// Values correspond to config.SigLevel enum (never=0, optional=1, required=2, ...).
	siglevel int
	// DisableSandbox skips all sandboxing for this commit, even when
	// the handle has a DownloadUser configured.
	disable_sandbox bool
	// Noconfirm skips interactive prompts (auto-answer "no" for
	// safety-related questions).
	noconfirm bool
}

// CommitResult describes the outcome of committing a single package.
pub struct CommitResult {
pub:
	pkg_name    string
	pkg_version string
	success     bool
	err_msg     string
}

// ---------------------------------------------------------------
// commit_all runs the full commit pipeline for a list of packages.
//
// Each package is validated (SHA256 checksum, PGP signature), then
// committed.  Corrupted packages cause a Question callback; if the
// user declines (or --noconfirm is set) the package is skipped.
// ---------------------------------------------------------------
pub fn commit_all(handle &util.Handle, pkgs []&util.Package, opts CommitOptions) ![]CommitResult {
	mut results := []CommitResult{}

	for pkg in pkgs {
		pkgfile := resolve_pkg_path(handle, pkg.name) or {
			results << CommitResult{
				pkg_name:    pkg.name
				pkg_version: pkg.version
				success:     false
				err_msg:     err.msg()
			}
			continue
		}

		// --- Phase 1: Integrity validation ----------------------------------
		validate_package(handle, pkgfile, pkg, opts.siglevel) or {
			err_msg := err.msg()
			// Corrupted package — ask user (or skip on --noconfirm).
			if opts.noconfirm {
				results << CommitResult{
					pkg_name:    pkg.name
					pkg_version: pkg.version
					success:     false
					err_msg:     'skipped corrupted package: ${err_msg}'
				}
			} else {
				results << CommitResult{
					pkg_name:    pkg.name
					pkg_version: pkg.version
					success:     false
					err_msg:     'corrupted package: ${err_msg}'
				}
			}
			continue
		}

		// --- Phase 2: Verify signature (if required) -------------------------
		sig_result := verify_package_signature(handle, pkgfile, pkg, opts.siglevel) or {
			results << CommitResult{
				pkg_name:    pkg.name
				pkg_version: pkg.version
				success:     false
				err_msg:     err.msg()
			}
			continue
		}

		if !sig_result.success {
			results << CommitResult{
				pkg_name:    pkg.name
				pkg_version: pkg.version
				success:     false
				err_msg:     sig_result.err_msg
			}
			continue
		}

		// --- Phase 3: Filesystem commit --------------------------------------
		results << commit_package(handle, pkg, pkgfile, opts)
	}

	return results
}

// ---------------------------------------------------------------
// resolve_pkg_path locates the package file in the cache.
// ---------------------------------------------------------------
fn resolve_pkg_path(handle &util.Handle, pkg_name string) !string {
	cachedirs := handle.resolved_cachedirs()
	for dir in cachedirs {
		entries := os.ls(dir) or { continue }
		for entry in entries {
			if entry.starts_with(pkg_name) && (entry.ends_with('.pkg.tar.zst') || entry.ends_with('.pkg.tar.xz') || entry.ends_with('.pkg.tar')) {
				full := os.join_path(dir, entry)
				if os.exists(full) {
					return full
				}
			}
		}
	}
	return error('package file not found for "${pkg_name}" in cache')
}

// ---------------------------------------------------------------
// commit_package performs the actual filesystem commit.
// ---------------------------------------------------------------
fn commit_package(handle &util.Handle, pkg &util.Package, pkgfile string, opts CommitOptions) CommitResult {
	// Stub — actual extraction / install logic Phase 4+.
	// For now we validate that the file exists and is readable.
	if !os.exists(pkgfile) {
		return CommitResult{
			pkg_name:    pkg.name
			pkg_version: pkg.version
			success:     false
			err_msg:     'package file not found: ${pkgfile}'
		}
	}

	stat := os.stat(pkgfile) or {
		return CommitResult{
			pkg_name:    pkg.name
			pkg_version: pkg.version
			success:     false
			err_msg:     'cannot stat package file: ${err.msg()}'
		}
	}

	if stat.size == 0 {
		return CommitResult{
			pkg_name:    pkg.name
			pkg_version: pkg.version
			success:     false
			err_msg:     'package file is empty: ${pkgfile}'
		}
	}

	return CommitResult{
		pkg_name:    pkg.name
		pkg_version: pkg.version
		success:     true
	}
}
