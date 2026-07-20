// Module: commit — package integrity validation.
//
// Provides SHA256 checksum verification, PGP signature validation,
// and corrupted-package detection, mirroring the flow in
// pacman/lib/libalpm/be_package.c:_alpm_pkg_validate_internal().
module commit

import lib
import os
import util

// SigValidationResult describes the outcome of PGP signature validation.
pub struct SigValidationResult {
pub:
	success bool
	// Human-readable status (empty on success, error description on failure).
	err_msg string
	// Fingerprint of the signing key (empty when no sig available).
	fingerprint string
}

// ---------------------------------------------------------------
// validate_package runs checksum + signature validation on a
// package file.  Returns an empty string on success, or an error
// message describing the violation.
//
// The algorithm mirrors pacman's _alpm_pkg_validate_internal:
//
//   1. SHA256 checksum (if an expected hash is available)
//   2. PGP signature verification (if siglevel requires it)
// ---------------------------------------------------------------
pub fn validate_package(handle &util.Handle, pkgfile string, pkg &util.Package, siglevel int) !string {
	// --- verify the file exists and is readable -----------------------------
	if !os.exists(pkgfile) {
		return error('package file not found: ${pkgfile}')
	}

	stat := os.stat(pkgfile) or {
		return error('cannot stat package file "${pkgfile}": ${err.msg()}')
	}

	if stat.size == 0 {
		return error('package file is empty: ${pkgfile}')
	}

	// --- SHA256 checksum validation -----------------------------------------
	// Compute the checksum and compare.  In the real pipeline the expected
	// hash would come from the sync DB; here we accept anything if the
	// Package struct doesn't carry it yet (Phase 4 will flesh this out).
	//
	// Even without a stored expected hash we compute it so the pipeline
	// exercises the full code path.  In production this is always set.
	computed := util.sha256sum(pkgfile) or {
		return error('failed to compute SHA256 for "${pkgfile}": ${err.msg()}')
	}

	// If the Package carries an expected hash, verify it.
	if pkg.sha256sum != '' {
		if computed != pkg.sha256sum {
			return error('SHA256 checksum mismatch for "${pkgfile}": ' +
				'expected ${pkg.sha256sum}, computed ${computed}')
		}
	}

	// --- PGP signature validation (if required) -----------------------------
	// SigLevel bit values: optional=1, required=2, trusted_only=4, marginal_ok=8, unknown_ok=16
	if siglevel & (1 | 2) != 0 {
		sig_result := verify_package_signature(handle, pkgfile, pkg, siglevel) or {
			return err
		}
		if !sig_result.success {
			return error(sig_result.err_msg)
		}
	}

	return ''
}

// ---------------------------------------------------------------
// verify_package_signature validates the detached PGP signature
// (.sig file or embedded base64 sig) for a package file.
//
// The .sig file is expected at pkgfile + '.sig' on disk, having
// been downloaded alongside the package by the download engine.
// ---------------------------------------------------------------
pub fn verify_package_signature(handle &util.Handle, pkgfile string, pkg &util.Package, siglevel int) !SigValidationResult {
	// If siglevel is Never (0), skip all signature checks.
	if siglevel == 0 {
		return SigValidationResult{
			success: true
		}
	}

	sig_path := pkgfile + '.sig'
	has_sig := os.exists(sig_path)

	// If signatures are required but missing, fail.
	if !has_sig && (siglevel & 2 != 0) { // required=2
		return SigValidationResult{
			success: false
			err_msg: 'missing required PGP signature for "${pkgfile}"'
		}
	}

	// If no signature found and it is optional, skip validation.
	if !has_sig {
		return SigValidationResult{
			success: true
		}
	}

	// --- read the .sig file -------------------------------------------------
	sig_bytes := os.read_bytes(sig_path) or {
		return SigValidationResult{
			success: false
			err_msg: 'failed to read signature file "${sig_path}": ${err.msg()}'
		}
	}

	if sig_bytes.len == 0 {
		return SigValidationResult{
			success: false
			err_msg: 'signature file "${sig_path}" is empty'
		}
	}

	// --- read the package data to verify against ----------------------------
	pkg_data := os.read_bytes(pkgfile) or {
		return SigValidationResult{
			success: false
			err_msg: 'failed to read package file "${pkgfile}" for signature verification: ${err.msg()}'
		}
	}

	// --- perform GPG verification via lib wrapper ---------------------------
	result := lib.gpgme_verify(pkg_data, sig_bytes) or {
		// gpgme error could mean missing key or corrupt sig
		return SigValidationResult{
			success: false
			err_msg: 'PGP signature verification failed: ${err.msg()}'
		}
	}

	// --- interpret the result -----------------------------------------------
	// Map the GPG status to success/failure based on siglevel trust settings.
	mut failure_reason := ''

	// status code 0 = GPGME_SIG_STAT_GOOD (no error)
	if result.status != 'success' {
		failure_reason = 'signature status is "${result.status}"'
	} else {
		// Check key validity against trust requirements.
		mut can_trust := false
		match result.validity {
			'full' {
				can_trust = true
			}
			'ultimate' {
				can_trust = true
			}
			'marginal' {
				// Marginal trust acceptable only if MarginalOk is set (value 8).
				can_trust = (siglevel & 8 != 0)
				if !can_trust {
					failure_reason = 'key has only marginal trust, but MarginalOk is not set'
				}
			}
			'unknown' {
				// Unknown trust acceptable only if UnknownOk is set (value 16).
				can_trust = (siglevel & 16 != 0)
				if !can_trust {
					failure_reason = 'key has unknown trust, but UnknownOk is not set'
				}
			}
			else {
				failure_reason = 'key validity is "${result.validity}" (not trusted)'
			}
		}

		if failure_reason == '' && !can_trust {
			// TrustedOnly mode (value 4) requires full/ultimate trust.
			if siglevel & 4 != 0 {
				failure_reason = 'key is not fully trusted (validity: ${result.validity})'
			}
		}
	}

	if failure_reason != '' {
		return SigValidationResult{
			success:     false
			err_msg:     'PGP signature check failed for "${pkgfile}": ${failure_reason}'
			fingerprint: result.fingerprint
		}
	}

	return SigValidationResult{
		success:     true
		fingerprint: result.fingerprint
	}
}

// ---------------------------------------------------------------
// is_corrupted_pkg checks if a package is corrupted based on
// validation outcome + error code.  This maps to the pacman
// ALPM_QUESTION_CORRUPTED_PKG flow.
// ---------------------------------------------------------------
pub fn is_corrupted_pkg(err_msg string) bool {
	return err_msg.contains('checksum mismatch') ||
		err_msg.contains('corrupted') ||
		err_msg.contains('PGP signature') ||
		err_msg.contains('signature verification failed') ||
		err_msg.contains('empty')
}

// ---------------------------------------------------------------
// remove_corrupted_pkg deletes the corrupted package file from
// the cache so it won't be reused in a future transaction.
// ---------------------------------------------------------------
pub fn remove_corrupted_pkg(pkg_name string, cachedirs []string) ! {
	for dir in cachedirs {
		entries := os.ls(dir) or { continue }
		for entry in entries {
			if entry.starts_with(pkg_name) && (entry.ends_with('.pkg.tar.zst') ||
				entry.ends_with('.pkg.tar.xz') ||
				entry.ends_with('.pkg.tar') ||
				entry.ends_with('.sig'))
			{
				full := os.join_path(dir, entry)
				os.rm(full) or { /* best effort */ }
			}
		}
	}
}
