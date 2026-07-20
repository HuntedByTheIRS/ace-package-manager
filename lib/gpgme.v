module lib

import os

// V C interop wrapper for gpgme (GnuPG Made Easy).
//
// This module provides safe, memory-managed wrappers around the GPGME C
// library.  It exposes a pure-V API — callers never touch C pointers or
// unsafe code.
//
// Usage:
//   lib.gpgme_init('/etc/pacman.d/gnupg')!
//   result := lib.gpgme_verify_path('/var/cache/pacman/pkg/foo.pkg.tar.zst')!
//   println(result.fingerprint)
//
// The C helper (gpgme_helper.c) provides type‑safe cast wrappers for APIs
// where voidptr → gpgme_data_t* isn't valid C.
#flag -lgpgme
#flag /home/specter/Projects/ace/lib/gpgme_helper.c
#include <gpgme.h>

// ---------------------------------------------------------------------------
// Protocol constants
// ---------------------------------------------------------------------------

pub const gpgme_protocol_openpgp = 0 // GPGME_PROTOCOL_OpenPGP (= 0)

// ---------------------------------------------------------------------------
// Signature-summary bitmask constants
// Mirror gpgme_sigsum_t from <gpgme.h>.
// ---------------------------------------------------------------------------

pub const sigsum_valid = 0
pub const sigsum_green = 1
pub const sigsum_red = 2
pub const sigsum_key_revoked = 4
pub const sigsum_key_expired = 8
pub const sigsum_sig_expired = 16
pub const sigsum_key_missing = 32
pub const sigsum_crl_missing = 64
pub const sigsum_crl_too_old = 128
pub const sigsum_bad_policy = 256
pub const sigsum_sys_error = 512

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

// SigResult holds the parsed outcome of a single GPG signature verification.
pub struct SigResult {
pub:
	fingerprint string // signer's key fingerprint (hex)
	status      string // human‑readable verification status
	validity    string // key validity (unknown / never / marginal / full / ultimate)
	summary     int    // bitmask summary (GPGME_SIGSUM_* values)
}

// ---------------------------------------------------------------------------
// C function declarations
// ---------------------------------------------------------------------------

// Library-level init
fn C.gpgme_check_version(version charptr) charptr

// Context management
fn C.gpgme_new(ctx &voidptr) int
fn C.gpgme_release(ctx voidptr)
fn C.gpgme_set_protocol(ctx voidptr, proto int) int

// Result inspection
fn C.gpgme_op_verify_result(ctx voidptr) voidptr
fn C.gpgme_strerror(err int) charptr

// Data object management
fn C.gpgme_data_release(data voidptr)

// Provided by gpgme_helper.c (type‑safe cast wrappers)
@[c_extern]
fn C.gpgme_data_new_from_mem_wrap(data &voidptr, buffer charptr, size usize, copy int) int

@[c_extern]
fn C.gpgme_op_verify_wrap(ctx voidptr, sig_data voidptr, signed_text voidptr, plaintext voidptr) int

@[c_extern]
fn C.gpgme_extract_sig(result voidptr, fpr_out charptr, fpr_max int,
	status_out voidptr, validity_out voidptr, summary_out voidptr) int

@[c_extern]
fn C.gpgme_init_wrap(gpgdir charptr, errbuf &u8, errbuf_max int) int

// ---------------------------------------------------------------------------
// Public API — initialisation
// ---------------------------------------------------------------------------

// gpgme_init performs one‑time GPGME library initialisation.
//
// It calls gpgme_check_version() (idempotent — safe to call many times),
// sets the locale for GPGME, verifies the OpenPGP engine is available,
// and points GPGME at the given keyring directory (`gpgdir`).
//
// Pass an empty string to use GPGME's default keyring path.
pub fn gpgme_init(gpgdir string) ! {
	mut errbuf := [256]u8{}
	cerr := unsafe { C.gpgme_init_wrap(gpgdir.str, &errbuf[0], 256) }
	if cerr != 0 {
		err_msg := unsafe { charptr(&errbuf[0]).vstring() }
		return error('gpgme: init failed: ' + err_msg)
	}
}

// ---------------------------------------------------------------------------
// Public API — signature verification (raw bytes)
// ---------------------------------------------------------------------------

// gpgme_verify verifies a detached GPG signature against the original data.
//
// `data` is the content of the signed file; `sig` is the content of the
// `.sig` file.  Returns a SigResult with the signer's fingerprint,
// human‑readable status, key validity, and a summary bitmask.
//
// The library must be initialised first via gpgme_init() (will auto‑init
// with default keyring if not already done).
pub fn gpgme_verify(data []u8, sig []u8) !SigResult {
	// Auto‑initialise with default keyring if caller hasn't called gpgme_init().
	gpgme_init('') or { return err }

	// Step 1: create a GPGME context.
	mut ctx := unsafe { nil }
	{
		cerr := C.gpgme_new(&ctx)
		if cerr != 0 {
			err_msg := unsafe { C.gpgme_strerror(cerr).vstring() }
			return error('gpgme: failed to create context: ' + err_msg)
		}
	}
	defer {
		C.gpgme_release(ctx)
	}

	// Step 2: set protocol to OpenPGP.
	C.gpgme_set_protocol(ctx, gpgme_protocol_openpgp)

	// Step 3: wrap the signature bytes in a gpgme_data_t (via C wrapper).
	mut sig_data := unsafe { nil }
	{
		cerr := C.gpgme_data_new_from_mem_wrap(&sig_data, charptr(sig.data), usize(sig.len), 1)
		if cerr != 0 {
			return error('gpgme: failed to create signature data object')
		}
	}
	defer {
		C.gpgme_data_release(sig_data)
	}

	// Step 4: wrap the original message bytes in a gpgme_data_t.
	mut msg_data := unsafe { nil }
	{
		cerr := C.gpgme_data_new_from_mem_wrap(&msg_data, charptr(data.data), usize(data.len), 1)
		if cerr != 0 {
			return error('gpgme: failed to create message data object')
		}
	}
	defer {
		C.gpgme_data_release(msg_data)
	}

	// Step 5: run the verification.
	{
		cerr := C.gpgme_op_verify_wrap(ctx, sig_data, msg_data, unsafe { nil })
		if cerr != 0 {
			err_msg := unsafe { C.gpgme_strerror(cerr).vstring() }
			return error('gpgme: verification failed: ' + err_msg)
		}
	}

	// Step 6: extract signature info via the C helper.
	result := C.gpgme_op_verify_result(ctx)
	if result == unsafe { nil } {
		return error('gpgme: no verification result returned (null)')
	}

	mut fpr_buf := [256]u8{}
	mut status_val := 0
	mut validity_val := 0
	mut summary_val := 0

	ret := C.gpgme_extract_sig(result, charptr(&fpr_buf[0]), 256, voidptr(&status_val),
		voidptr(&validity_val), voidptr(&summary_val))

	if ret == -1 {
		return error('gpgme: no signatures found in result (status=${status_val} validity=${validity_val})')
	}

	fpr := unsafe { charptr(&fpr_buf[0]).vstring() }
	status_str := status_code_to_string(status_val)
	validity_str := validity_code_to_string(validity_val)

	return SigResult{
		fingerprint: fpr
		status:      status_str
		validity:    validity_str
		summary:     summary_val
	}
}

// ---------------------------------------------------------------------------
// Public API — signature verification (file‑based)
// ---------------------------------------------------------------------------

// gpgme_verify_path reads a file and its detached `.sig` from disk and
// verifies the signature.  The signature file is expected at `path + '.sig'`.
//
// The library must be initialised first via gpgme_init() (will auto‑init
// with default keyring if not already done).
pub fn gpgme_verify_path(path string) !SigResult {
	// Auto‑init so callers don't need to remember.
	gpgme_init('') or { return err }

	// Read the data file.
	data := os.read_bytes(path) or {
		return error('gpgme: cannot read file for verification: ${err}')
	}

	// Read the detached signature.
	sig_path := path + '.sig'
	sig := os.read_bytes(sig_path) or {
		return error('gpgme: no signature file at "${sig_path}": ${err}')
	}

	return gpgme_verify(data, sig)
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn status_code_to_string(code int) string {
	return match code {
		0 { 'success' }
		8 { 'no data' }
		13 { 'bad signature class' }
		63 { 'bad signature' }
		69 { 'no public key' }
		77 { 'key revoked' }
		78 { 'signature expired' }
		79 { 'key expired' }
		else { 'error code ' + code.str() }
	}
}

fn validity_code_to_string(code int) string {
	return match code {
		0 { 'unknown' }
		1 { 'never' }
		2 { 'marginal' }
		3 { 'full' }
		4 { 'ultimate' }
		else { 'unknown (' + code.str() + ')' }
	}
}
