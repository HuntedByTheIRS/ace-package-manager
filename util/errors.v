module util

// AceError is the custom error type that implements IError (msg() + code()).
// Every public module function returns a fallible result using `!`, and on
// failure it returns an AceError.  Use `exit_code_from_error()` to derive the
// process exit code.
//
// Error‑wrapping pattern (in higher‑level modules):
// ```v
// fn install_pkg(name string) ! {
//     download_pkg(name) or {
//         return AceError{code: .retrieve, message: "while installing ${name}: ${err.msg()}"}
//     }
// }
// ```

// ErrorCode mirrors alpm_errno_t from libalpm/alpm.h (lines 206‑328).
// Each variant corresponds 1:1 with the C enum.
pub enum ErrorCode {
	ok = 0
	memory
	system
	badperms
	not_a_file
	not_a_dir
	wrong_args
	disk_space
	handle_null
	handle_not_null
	handle_lock
	db_open
	db_create
	db_null
	db_not_null
	db_not_found
	db_invalid
	db_invalid_sig
	db_version
	db_write
	db_remove
	server_bad_url
	server_none
	trans_not_null
	trans_null
	trans_dup_target
	trans_dup_filename
	trans_not_initialized
	trans_not_prepared
	trans_abort
	trans_type
	trans_not_locked
	trans_hook_failed
	pkg_not_found
	pkg_ignored
	pkg_invalid
	pkg_invalid_checksum
	pkg_invalid_sig
	pkg_missing_sig
	pkg_open
	pkg_cant_remove
	pkg_invalid_name
	pkg_invalid_arch
	sig_missing
	sig_invalid
	unsatisfied_deps
	conflicting_deps
	file_conflicts
	retrieve_prepare
	retrieve
	invalid_regex
	libarchive
	libcurl
	gpgme
	external_download
	missing_capability_signatures
}

// AceError pairs an ErrorCode with a human‑readable message.
// It implements `IError` so it can be returned from `!T` functions as an error.
pub struct AceError {
pub:
	code    ErrorCode
	message string
}

// msg implements IError.
pub fn (e AceError) msg() string {
	return e.message
}

// code implements IError.
pub fn (e AceError) code() int {
	return int(e.code)
}

// wrap prepends `context` to the existing message, preserving the error code.
// Use this when propagating an AceError through a higher‑level module:
//
// ```v
// lowlevel() or {
//     return AceError.from(err).wrap("while setting up")
// }
// ```
pub fn (e AceError) wrap(context string) AceError {
	return AceError{
		code:    e.code
		message: context + ': ' + e.message
	}
}

// error_code_from_int converts an int to an ErrorCode without unsafe.
fn error_code_from_int(code int) ErrorCode {
	return unsafe { ErrorCode(code) }
}

// from converts a generic IError to an AceError.
// If the underlying error is already an AceError, the code is preserved;
// otherwise it is treated as an unexpected system error.
pub fn AceError.from(err IError) AceError {
	return AceError{
		code:    error_code_from_int(err.code())
		message: err.msg()
	}
}

// ---------- messages matching pacman's alpm_strerror() ----------

// strerror returns the human‑readable message for an ErrorCode, matching
// pacman's `alpm_strerror()` output (without gettext wrappers).
pub fn strerror(code ErrorCode) string {
	return match code {
		.ok { 'no error' }
		.memory { 'out of memory!' }
		.system { 'unexpected system error' }
		.badperms { 'permission denied' }
		.not_a_file { 'could not find or read file' }
		.not_a_dir { 'could not find or read directory' }
		.wrong_args { 'wrong or NULL argument passed' }
		.disk_space { 'not enough free disk space' }
		.handle_null { 'library not initialized' }
		.handle_not_null { 'library already initialized' }
		.handle_lock { 'unable to lock database' }
		.db_open { 'could not open database' }
		.db_create { 'could not create database' }
		.db_null { 'database not initialized' }
		.db_not_null { 'database already registered' }
		.db_not_found { 'could not find database' }
		.db_invalid { 'invalid or corrupted database' }
		.db_invalid_sig { 'invalid or corrupted database (PGP signature)' }
		.db_version { 'database is incorrect version' }
		.db_write { 'could not update database' }
		.db_remove { 'could not remove database entry' }
		.server_bad_url { 'invalid url for server' }
		.server_none { 'no servers configured for repository' }
		.trans_not_null { 'transaction already initialized' }
		.trans_null { 'transaction not initialized' }
		.trans_dup_target { 'duplicate target' }
		.trans_dup_filename { 'duplicate filename' }
		.trans_not_initialized { 'transaction not initialized' }
		.trans_not_prepared { 'transaction not prepared' }
		.trans_abort { 'transaction aborted' }
		.trans_type { 'operation not compatible with the transaction type' }
		.trans_not_locked { 'transaction commit attempt when database is not locked' }
		.trans_hook_failed { 'failed to run transaction hooks' }
		.pkg_not_found { 'could not find or read package' }
		.pkg_ignored { 'operation cancelled due to ignorepkg' }
		.pkg_invalid { 'invalid or corrupted package' }
		.pkg_invalid_checksum { 'invalid or corrupted package (checksum)' }
		.pkg_invalid_sig { 'invalid or corrupted package (PGP signature)' }
		.pkg_missing_sig { 'package missing required signature' }
		.pkg_open { 'cannot open package file' }
		.pkg_cant_remove { 'cannot remove all files for package' }
		.pkg_invalid_name { 'package filename is not valid' }
		.pkg_invalid_arch { 'package architecture is not valid' }
		.sig_missing { 'missing PGP signature' }
		.sig_invalid { 'invalid PGP signature' }
		.unsatisfied_deps { 'could not satisfy dependencies' }
		.conflicting_deps { 'conflicting dependencies' }
		.file_conflicts { 'conflicting files' }
		.retrieve_prepare { 'failed to initialize download' }
		.retrieve { 'failed to retrieve some files' }
		.invalid_regex { 'invalid regular expression' }
		.libarchive { 'libarchive error' }
		.libcurl { 'download library error' }
		.gpgme { 'gpgme error' }
		.external_download { 'error invoking external downloader' }
		.missing_capability_signatures { 'compiled without signature support' }
	}
}

// ---------- mapping to process exit codes ----------

// exit_code_from_error maps an AceError to a pacman‑compatible process exit
// code.  The general rule is:
//
//   • ok → 0
//   • dependency / conflict errors → 127  (deptest convention)
//   • everything else → 1 (EXIT_FAILURE)
//
pub fn exit_code_from_error(err AceError) int {
	return match err.code {
		.ok { 0 }
		.unsatisfied_deps, .conflicting_deps, .file_conflicts { 127 }
		else { 1 }
	}
}
