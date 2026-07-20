module log

import os
import time

// LogLevel mirrors alpm_loglevel_t from libalpm/alpm.h.
pub enum LogLevel {
	error_val = 1
	warning   = 2
	debug     = 4
	function  = 8
}

// String returns the uppercase level label used in log output.
pub fn (lvl LogLevel) str() string {
	return match lvl {
		.error_val { 'ERROR' }
		.warning { 'WARNING' }
		.debug { 'DEBUG' }
		.function { 'FUNCTION' }
	}
}

// Logger writes timestamped log messages to a file or stderr.
//
// Usage:
// ```v
// mut l := log.Logger{}
// l.init('/var/log/ace.log', log.LogLevel.warning) or { ... }
// l.log(.error, 'something broke')
// l.logf(.warning, 'disk usage at ${pct}%%')
// ```
pub struct Logger {
mut:
	path  string   // log file path (empty = stderr)
	level LogLevel // minimum level bitmask
}

// ---------- construction ----------

// init sets the log file path and minimum log level.
// If `path` is empty, output goes to stderr.
// The file is tested for writability at init time.
pub fn (mut l Logger) init(path string, level LogLevel) ! {
	if path != '' {
		// Verify the path is writable by opening for append.
		mut f := os.open_file(path, 'a+', 0o644) or {
			return error('failed to open log file "${path}": ${err.msg()}')
		}
		f.close()
	}
	l.path = path
	l.level = level
}

// ---------- logging primitives ----------

// log writes a single timestamped message if `level` passes the filter.
// Format: [YYYY-MM-DDTHH:MM:SS] [LEVEL] message
//
// The log level is a bitmask mirroring pacman's ALPM_LOG_* flags:
//   error=1, warning=2, debug=4, function=8
// Errors are always shown; other levels require a matching bit in the mask.
pub fn (mut l Logger) log(level LogLevel, msg string) {
	if level != .error_val && int(level) & int(l.level) == 0 {
		return
	}
	line := build_line(level, msg)
	l.write_line(line)
}

// logf is a formatted variant of log.
// The `msg` may contain V-style `${}` interpolation; pass the fully-formed
// string or use `'... ${val} ...'` before calling.
// Extra `args` are joined with spaces and appended.
pub fn (mut l Logger) logf(level LogLevel, msg string, args ...string) {
	full := if args.len > 0 { msg + ' ' + args.join(' ') } else { msg }
	l.log(level, full)
}

// ---------- internal helpers ----------

fn build_line(level LogLevel, msg string) string {
	now := time.now()
	ts := now.custom_format('YYYY-MM-DDTHH:mm:ss')
	return '[${ts}] [${level.str()}] ${msg}\n'
}

fn (mut l Logger) write_line(line string) {
	if l.path == '' {
		mut stderr := os.stderr()
		stderr.write_string(line) or {}
		return
	}
	// Open, write, close — ensures every line is flushed immediately.
	mut f := os.open_file(l.path, 'a+', 0o644) or { return }
	f.write_string(line) or {}
	f.close()
}
