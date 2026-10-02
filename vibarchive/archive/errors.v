module archive

// check_result maps a libarchive status code to a V error.
// ARCHIVE_OK (0) and ARCHIVE_EOF (1) pass; ARCHIVE_RETRY (-10), ARCHIVE_WARN (-20),
// ARCHIVE_FAILED (-25), and ARCHIVE_FATAL (-30) produce an error with the archive's
// error string.
pub fn check_result(a &C.struct_archive, code i32) ! {
	if unsafe { a == nil } {
		return error('libarchive: nil archive pointer')
	}
	if code == archive_ok || code == archive_eof {
		return
	}
	msg := err_string(a)
	return error('libarchive (${code}): ${msg}')
}

// check_data_result maps a libarchive data-return function's result to a V result.
// Returns the byte count (>=0) on success, or an error (<0) mapping the negative code.
// Handles archive_read_data() and archive_write_data() which return:
//   - positive value: bytes read/written
//   - 0: end of data (EOF for read, or zero-length write)
//   - negative: error code (ARCHIVE_RETRY, ARCHIVE_WARN, ARCHIVE_FATAL)
pub fn check_data_result(a &C.struct_archive, n i64) !i64 {
	if unsafe { a == nil } {
		return error('libarchive: nil archive pointer')
	}
	if n >= 0 {
		return n
	}
	msg := err_string(a)
	return error('libarchive (${n}): ${msg}')
}

// err_string safely gets the error string from a libarchive archive pointer,
// handling NULL return from archive_error_string.
fn err_string(a &C.struct_archive) string {
	s := C.archive_error_string(a)
	if unsafe { s == nil } {
		return 'unknown error'
	}
	return unsafe { cstring_to_vstring(s) }
}

// is_fatal returns true if the code is ARCHIVE_FATAL (no more operations possible).
pub fn is_fatal(code i32) bool {
	return code == archive_fatal
}

// is_warning returns true if the code indicates a warning or retry condition.
pub fn is_warning(code i32) bool {
	return code == archive_warn || code == archive_retry
}
