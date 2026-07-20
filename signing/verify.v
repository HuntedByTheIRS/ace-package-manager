module signing

import lib
import config
import util

// ---------------------------------------------------------------------------
// Policy helpers
// ---------------------------------------------------------------------------

// sig_policy_is extracts a single SigLevel flag from the bitmask.
fn sig_policy_is(level config.SigLevel, flag config.SigLevel) bool {
	return int(level) & int(flag) != 0
}

// sig_must_be_present returns true when the policy requires a signature to
// exist.  This is true when SigLevel includes Required, OR when it includes
// neither Required nor Optional (pacman's default — Required without
// DatabaseOptional means package sigs are mandatory).
fn sig_must_be_present(level config.SigLevel) bool {
	has_required := sig_policy_is(level, .required)
	has_optional := sig_policy_is(level, .optional)
	return has_required || (!has_required && !has_optional)
}

// ---------------------------------------------------------------------------
// verify_signature
// ---------------------------------------------------------------------------

// verify_signature checks the PGP detached signature for a file at `path`.
//
// The signature file is expected at `path + ".sig"`.
//
// SigLevel controls the verification behaviour:
//
//   Never         — skip verification entirely (always succeeds).
//   Required      — a valid signature MUST be present.
//   Optional      — a missing signature is acceptable but an invalid one is not.
//   TrustedOnly   — only full / ultimate key trust is accepted.
//   MarginalOk    — marginal key trust is also accepted.
//   UnknownOk     — unknown key trust is also accepted.
//
// On success the function returns without error.  On failure it returns
// an util.AceError with an appropriate ErrorCode (.sig_missing,
// .pkg_invalid_sig, or .gpgme).
pub fn verify_signature(handle &util.Handle, path string, siglevel config.SigLevel) ! {
	// ---- Never → skip ----
	if siglevel == .never || int(siglevel) == 0 {
		return
	}

	// ---- Extract policy flags ----
	must_present := sig_must_be_present(siglevel)
	optional := sig_policy_is(siglevel, .optional)
	trusted_only := sig_policy_is(siglevel, .trusted_only)
	marginal_ok := sig_policy_is(siglevel, .marginal_ok)
	unknown_ok := sig_policy_is(siglevel, .unknown_ok)

	// ---- Initialise GPGME ----
	gpgdir := handle.resolved_gpgdir()
	lib.gpgme_init(gpgdir) or {
		return util.AceError{
			code:    .gpgme
			message: 'failed to initialise GPGME: ${err.msg()}'
		}
	}

	// ---- Attempt verification ----
	result := lib.gpgme_verify_path(path) or {
		err_msg := err.msg()
		// "no signature file" → expected when the .sig is absent
		if err_msg.contains('no signature file') || err_msg.contains('no signatures') {
			if !must_present || optional {
				return
			}
			return util.AceError{
				code:    .sig_missing
				message: '${path}: missing required PGP signature'
			}
		}
		return util.AceError{
			code:    .pkg_invalid_sig
			message: '${path}: ${err_msg}'
		}
	}

	// No fingerprints returned → no signatures found.
	if result.fingerprint == '' {
		if optional {
			return
		}
		return util.AceError{
			code:    .sig_missing
			message: '${path}: no PGP signatures found'
		}
	}

	// ---- Check signature status ----
	//
	// The status string comes from status_code_to_string() in lib/gpgme.v
	// mapping gpg_err_code_t values:
	//   0  = GPG_ERR_NO_ERROR    → "success"
	//  79  = GPG_ERR_KEY_EXPIRED → "key expired"
	//  69  = GPG_ERR_NO_PUBKEY   → "no public key"
	//  63  = GPG_ERR_BAD_SIGNATURE → "bad signature"
	//  78  = GPG_ERR_SIG_EXPIRED → "signature expired"
	//  77  = GPG_ERR_KEY_REVOKED → "key revoked"
	match result.status {
		'success' {
			// Signature is cryptographically valid — proceed to trust check.
		}
		'key expired' {
			// The signature itself is valid, but the signing key has expired.
			// We still check trust and summary below, since this is
			// analogous to ALPM_SIGSTATUS_KEY_EXPIRED in the C reference.
		}
		else {
			return util.AceError{
				code:    .pkg_invalid_sig
				message: '${path}: PGP signature is "${result.status}" (key ${result.fingerprint})'
			}
		}
	}

	// ---- Check summary bitmask (gpgme_sigsum_t) ----
	if result.summary & lib.sigsum_red != 0 {
		return util.AceError{
			code:    .pkg_invalid_sig
			message: '${path}: PGP signature from "${result.fingerprint}" is BAD (red)'
		}
	}
	if result.summary & lib.sigsum_key_missing != 0 {
		return util.AceError{
			code:    .pkg_invalid_sig
			message: '${path}: public key "${result.fingerprint}" is missing from keyring'
		}
	}

	// ---- Check key validity against policy ----
	//
	// Validity comes from validity_code_to_string():
	//   3 = GPGME_VALIDITY_FULL     → "full"
	//   4 = GPGME_VALIDITY_ULTIMATE → "ultimate"
	//   2 = GPGME_VALIDITY_MARGINAL → "marginal"
	//   0 = GPGME_VALIDITY_UNKNOWN  → "unknown"
	//   1 = GPGME_VALIDITY_NEVER    → "never"
	if trusted_only && result.validity != 'full' && result.validity != 'ultimate' {
		return util.AceError{
			code:    .pkg_invalid_sig
			message: '${path}: signature from "${result.fingerprint}" has ${result.validity} trust (full required)'
		}
	}

	if !marginal_ok && result.validity == 'marginal' {
		return util.AceError{
			code:    .pkg_invalid_sig
			message: '${path}: signature from "${result.fingerprint}" is marginal trust'
		}
	}

	if !unknown_ok && (result.validity == 'unknown' || result.validity == 'never') {
		return util.AceError{
			code:    .pkg_invalid_sig
			message: '${path}: signature from "${result.fingerprint}" has ${result.validity} trust'
		}
	}

	// All checks passed — signature is valid and meets the policy requirements.
}
