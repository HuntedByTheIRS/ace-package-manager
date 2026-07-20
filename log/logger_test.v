module log

import os

fn cleanup(path string) {
	os.rm(path) or {}
}

fn test_log_to_file_contains_level_and_message() {
	tmp := os.join_path(os.temp_dir(), 'ace_log_test_${os.getpid()}.log')
	defer { cleanup(tmp) }

	mut l := Logger{}
	l.init(tmp, .error_val) or { assert false, 'init failed: ${err}' }
	l.log(.error_val, 'test error message')

	// Read back and verify
	content := os.read_file(tmp) or { assert false, 'read failed: ${err}'; return }
	assert content.contains('[ERROR]')
	assert content.contains('test error message')
}

fn test_log_warning_to_file() {
	tmp := os.join_path(os.temp_dir(), 'ace_log_warn_${os.getpid()}.log')
	defer { cleanup(tmp) }

	mut l := Logger{}
	l.init(tmp, .warning) or { assert false, 'init failed: ${err}' }
	l.log(.warning, 'warning message')

	content := os.read_file(tmp) or { assert false, 'read failed: ${err}'; return }
	assert content.contains('[WARNING]')
	assert content.contains('warning message')
}

fn test_log_to_file_has_timestamp() {
	tmp := os.join_path(os.temp_dir(), 'ace_log_ts_${os.getpid()}.log')
	defer { cleanup(tmp) }

	mut l := Logger{}
	l.init(tmp, .error_val) or { assert false, 'init failed: ${err}' }
	l.log(.error_val, 'ts check')

	content := os.read_file(tmp) or { assert false, 'read failed: ${err}'; return }
	// Timestamp format includes comma-separated date components per V 0.5.2
	assert content.len > 20
	// Line starts with one or two `[` (outer wrapper + format-produced brackets)
	assert content[0] == `[`
}

fn test_logf_formatted() {
	tmp := os.join_path(os.temp_dir(), 'ace_log_fmt_${os.getpid()}.log')
	defer { cleanup(tmp) }

	mut l := Logger{}
	l.init(tmp, .warning) or { assert false, 'init failed: ${err}' }
	l.logf(.warning, 'pkg failed:', 'network error', 'code 7')

	content := os.read_file(tmp) or { assert false, 'read failed: ${err}'; return }
	assert content.contains('pkg failed: network error code 7')
}

fn test_log_level_filtering_blocks_debug_when_warning() {
	tmp := os.join_path(os.temp_dir(), 'ace_log_filter_${os.getpid()}.log')
	defer { cleanup(tmp) }

	mut l := Logger{}
	// Only WARNING bit set → ERROR passes, but DEBUG should not
	l.init(tmp, .warning) or { assert false, 'init failed: ${err}' }

	l.log(.warning, 'this is a warning') // should appear
	l.log(.debug, 'this is debug')        // should NOT appear (bit not in mask)
	l.log(.error_val, 'this is an error') // should always appear (errors pass through)

	content := os.read_file(tmp) or { assert false, 'read failed: ${err}'; return }
	assert content.contains('[WARNING]')
	assert content.contains('[ERROR]')
	// Debug message should be filtered out
	assert !content.contains('this is debug')
}

fn test_log_init_empty_path_falls_back() {
	mut l := Logger{}
	// Empty path should not error — falls back to stderr
	l.init('', .error_val) or { assert false, 'init with empty path should not fail: ${err}' }
	// No crash when logging with no file (goes to stderr)
	l.log(.error_val, 'stderr test')
}

fn test_log_level_str() {
	assert LogLevel.error_val.str() == 'ERROR'
	assert LogLevel.warning.str() == 'WARNING'
	assert LogLevel.debug.str() == 'DEBUG'
	assert LogLevel.function.str() == 'FUNCTION'
}
