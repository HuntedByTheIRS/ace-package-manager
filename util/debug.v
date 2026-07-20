// Debug helpers — routed through handle.debug_level for conditional output.
module util

// debugln prints msg to stderr when debug_level >= min_level.
pub fn debugln(handle &Handle, min_level int, msg string) {
	if handle.debug_level >= min_level {
		eprintln('[DEBUG] ${msg}')
	}
}

// debugf prints formatted msg to stderr when debug_level >= min_level.
pub fn debugf(handle &Handle, min_level int, format string, args ...string) {
	if handle.debug_level >= min_level {
		mut s := format
		for i, a in args {
			s = s.replace('{${i}}', a)
		}
		eprintln('[DEBUG] ${s}')
	}
}
