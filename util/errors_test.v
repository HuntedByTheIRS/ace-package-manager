module util

// ---------- strerror ----------

fn test_strerror_returns_known_messages() {
	assert strerror(.ok) == 'no error'
	assert strerror(.memory) == 'out of memory!'
	assert strerror(.system) == 'unexpected system error'
	assert strerror(.badperms) == 'permission denied'
	assert strerror(.not_a_file) == 'could not find or read file'
	assert strerror(.not_a_dir) == 'could not find or read directory'
	assert strerror(.wrong_args) == 'wrong or NULL argument passed'
	assert strerror(.disk_space) == 'not enough free disk space'
	assert strerror(.handle_null) == 'library not initialized'
	assert strerror(.handle_not_null) == 'library already initialized'
	assert strerror(.handle_lock) == 'unable to lock database'
}

fn test_strerror_database_codes() {
	assert strerror(.db_open) == 'could not open database'
	assert strerror(.db_create) == 'could not create database'
	assert strerror(.db_null) == 'database not initialized'
	assert strerror(.db_not_null) == 'database already registered'
	assert strerror(.db_not_found) == 'could not find database'
	assert strerror(.db_invalid) == 'invalid or corrupted database'
	assert strerror(.db_invalid_sig) == 'invalid or corrupted database (PGP signature)'
	assert strerror(.db_version) == 'database is incorrect version'
	assert strerror(.db_write) == 'could not update database'
	assert strerror(.db_remove) == 'could not remove database entry'
}

fn test_strerror_server_codes() {
	assert strerror(.server_bad_url) == 'invalid url for server'
	assert strerror(.server_none) == 'no servers configured for repository'
}

fn test_strerror_transaction_codes() {
	assert strerror(.trans_not_null) == 'transaction already initialized'
	assert strerror(.trans_null) == 'transaction not initialized'
	assert strerror(.trans_dup_target) == 'duplicate target'
	assert strerror(.trans_dup_filename) == 'duplicate filename'
	assert strerror(.trans_not_initialized) == 'transaction not initialized'
	assert strerror(.trans_not_prepared) == 'transaction not prepared'
	assert strerror(.trans_abort) == 'transaction aborted'
	assert strerror(.trans_type) == 'operation not compatible with the transaction type'
	assert strerror(.trans_not_locked) == 'transaction commit attempt when database is not locked'
	assert strerror(.trans_hook_failed) == 'failed to run transaction hooks'
}

fn test_strerror_package_codes() {
	assert strerror(.pkg_not_found) == 'could not find or read package'
	assert strerror(.pkg_ignored) == 'operation cancelled due to ignorepkg'
	assert strerror(.pkg_invalid) == 'invalid or corrupted package'
	assert strerror(.pkg_invalid_checksum) == 'invalid or corrupted package (checksum)'
	assert strerror(.pkg_invalid_sig) == 'invalid or corrupted package (PGP signature)'
	assert strerror(.pkg_missing_sig) == 'package missing required signature'
	assert strerror(.pkg_open) == 'cannot open package file'
	assert strerror(.pkg_cant_remove) == 'cannot remove all files for package'
	assert strerror(.pkg_invalid_name) == 'package filename is not valid'
	assert strerror(.pkg_invalid_arch) == 'package architecture is not valid'
}

fn test_strerror_signature_codes() {
	assert strerror(.sig_missing) == 'missing PGP signature'
	assert strerror(.sig_invalid) == 'invalid PGP signature'
}

fn test_strerror_dependency_codes() {
	assert strerror(.unsatisfied_deps) == 'could not satisfy dependencies'
	assert strerror(.conflicting_deps) == 'conflicting dependencies'
	assert strerror(.file_conflicts) == 'conflicting files'
}

fn test_strerror_misc_codes() {
	assert strerror(.retrieve_prepare) == 'failed to initialize download'
	assert strerror(.retrieve) == 'failed to retrieve some files'
	assert strerror(.invalid_regex) == 'invalid regular expression'
	assert strerror(.libarchive) == 'libarchive error'
	assert strerror(.libcurl) == 'download library error'
	assert strerror(.gpgme) == 'gpgme error'
	assert strerror(.external_download) == 'error invoking external downloader'
	assert strerror(.missing_capability_signatures) == 'compiled without signature support'
}

// ---------- AceError.wrap ----------

fn test_ace_error_wrap_preserves_code_and_extends_message() {
	base := AceError{
		code:    .retrieve
		message: 'connection refused'
	}
	wrapped := base.wrap('while downloading X')

	assert wrapped.code == .retrieve
	assert wrapped.message == 'while downloading X: connection refused'
}

fn test_ace_error_wrap_chaining() {
	base := AceError{
		code:    .pkg_not_found
		message: strerror(.pkg_not_found)
	}
	wrapped := base.wrap('while reading package cache')
	double_wrapped := wrapped.wrap('sync prepare')

	assert double_wrapped.code == .pkg_not_found
	assert double_wrapped.message == 'sync prepare: while reading package cache: could not find or read package'
}

// ---------- AceError.from ----------

fn test_ace_error_from_preserves_generic_error() {
	gen_err := error('something failed')
	ace := AceError.from(gen_err)

	assert ace.message == 'something failed'
	assert ace.code == .ok // generic IError has code 0 (.ok)
}

// ---------- AceError as IError ----------

fn test_ace_error_is_usable_in_fallible_functions() {
	fn_fail() or {
		assert err.msg() == 'could not find or read package'
		assert err.code() == int(ErrorCode.pkg_not_found)
		return
	}
	// Should not reach here
	assert false
}

fn fn_fail() !int {
	return AceError{
		code:    .pkg_not_found
		message: strerror(.pkg_not_found)
	}
}

fn fn_ok() !int {
	return 42
}

fn test_ace_error_success_path() {
	val := fn_ok() or { assert false; return }
	_ := val
	assert val == 42
}

// ---------- exit_code_from_error ----------

fn test_exit_code_ok() {
	err := AceError{code: .ok, message: ''}
	assert exit_code_from_error(err) == 0
}

fn test_exit_code_generic_error() {
	for code in [ErrorCode.memory, .system, .badperms, .not_a_file, .handle_null, .db_open,
		.db_not_found, .server_bad_url, .trans_abort, .pkg_not_found, .pkg_invalid,
		.sig_missing, .retrieve, .libarchive] {
		err := AceError{code: code, message: ''}
		assert exit_code_from_error(err) == 1
	}
}

fn test_exit_code_dependency_conflict() {
	err_unsat := AceError{code: .unsatisfied_deps, message: ''}
	assert exit_code_from_error(err_unsat) == 127

	err_conf := AceError{code: .conflicting_deps, message: ''}
	assert exit_code_from_error(err_conf) == 127

	err_file := AceError{code: .file_conflicts, message: ''}
	assert exit_code_from_error(err_file) == 127
}

// ---------- ErrorCode values match alpm_errno_t ----------

fn test_error_code_values_match_alpm() {
	assert int(ErrorCode.ok) == 0
	assert int(ErrorCode.memory) == 1
	assert int(ErrorCode.system) == 2
	assert int(ErrorCode.badperms) == 3
	assert int(ErrorCode.not_a_file) == 4
	assert int(ErrorCode.not_a_dir) == 5
	assert int(ErrorCode.wrong_args) == 6
	assert int(ErrorCode.disk_space) == 7
	assert int(ErrorCode.handle_null) == 8
	assert int(ErrorCode.handle_not_null) == 9
	assert int(ErrorCode.handle_lock) == 10
	assert int(ErrorCode.db_open) == 11
	assert int(ErrorCode.db_create) == 12
	assert int(ErrorCode.db_not_null) == 14
	assert int(ErrorCode.db_not_found) == 15
}
