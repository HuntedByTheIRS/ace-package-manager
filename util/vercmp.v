module util

// parse_evr splits an [epoch:]version[-release] string into its components.
fn parse_evr(s string) (string, string, string) {
	mut epoch := '0'
	mut version := s
	mut release := ''

	if s.len == 0 {
		return epoch, version, release
	}

	// Walk digits at the start to find a potential epoch terminator.
	mut i := 0
	for i < s.len && s[i].is_digit() {
		i++
	}

	if i < s.len && s[i] == `:` {
		epoch = if i > 0 { s[..i] } else { '0' }
		version = s[i + 1..]
	}

	// Find the last '-' as the release separator.
	if dash_pos := version.last_index('-') {
		release = version[dash_pos + 1..]
		version = version[..dash_pos]
	}

	return epoch, version, release
}

// rpmvercmp compares two version strings segment-by-segment, matching
// pacman's rpmvercmp algorithm from lib/libalpm/version.c.
fn rpmvercmp(a string, b string) int {
	if a == b {
		return 0
	}

	mut i := 0
	mut j := 0

	for i < a.len && j < b.len {
		// Tilde handling: '~' is a pre-release marker. A version with '~'
		// always sorts lower than one without at the same position.
		if (i < a.len && a[i] == `~`) || (j < b.len && b[j] == `~`) {
			if i >= a.len || a[i] != `~` {
				return 1 // a does not have ~ here, b does → a is newer
			}
			if j >= b.len || b[j] != `~` {
				return -1 // a has ~ here, b does not → a is older
			}
			// Both have '~': skip past and continue.
			i++
			j++
			continue
		}

		// Save positions before skipping separators, so we can detect
		// separator-length differences.
		prev_i := i
		prev_j := j

		// Skip non-alphanumeric separators ('.', '-', '_', etc.).
		for i < a.len && !a[i].is_alnum() {
			i++
		}
		for j < b.len && !b[j].is_alnum() {
			j++
		}

		// If either string is exhausted, break out for the final showdown.
		if i >= a.len || j >= b.len {
			break
		}

		// Check if the number of separator characters differed.
		if (i - prev_i) != (j - prev_j) {
			return if (i - prev_i) < (j - prev_j) { -1 } else { 1 }
		}

		// Record start of the current alphanumeric segment.
		seg_i := i
		seg_j := j

		isnum := a[i].is_digit()

		// Walk to the end of the current segment (all-digit or all-letter).
		if isnum {
			for i < a.len && a[i].is_digit() {
				i++
			}
			for j < b.len && b[j].is_digit() {
				j++
			}
		} else {
			for i < a.len && a[i].is_letter() {
				i++
			}
			for j < b.len && b[j].is_letter() {
				j++
			}
		}

		// The first segment should never be empty (defensive).
		if seg_i == i {
			return -1
		}

		// If the second segment is empty, the segment types differ
		// (one numeric, one alpha). Numeric always wins.
		if seg_j == j {
			return if isnum { 1 } else { -1 }
		}

		// Compare the two segments.
		seg_a := a[seg_i..i]
		seg_b := b[seg_j..j]

		if isnum {
			// Strip leading zeros for numeric comparison.
			a_trim := seg_a.trim_left('0')
			b_trim := seg_b.trim_left('0')
			if a_trim.len > b_trim.len {
				return 1
			}
			if b_trim.len > a_trim.len {
				return -1
			}
			// Same length after stripping; compare the trimmed strings
			// (which are pure digit strings, so lexicographic == numeric).
			if a_trim < b_trim {
				return -1
			}
			if a_trim > b_trim {
				return 1
			}
		} else {
			// Alpha segment: compare directly.
			if seg_a < seg_b {
				return -1
			}
			if seg_a > seg_b {
				return 1
			}
		}
	}

	// Both strings exhausted at the same position → equal.
	if i >= a.len && j >= b.len {
		return 0
	}

	// Tilde pre-release marker may appear right when the other string
	// has been exhausted (the loop guard prevented entry).
	if i < a.len && a[i] == `~` {
		return -1
	}
	if j < b.len && b[j] == `~` {
		return 1
	}

	// Final showdown: determine which remaining suffix is newer.
	//   - If a is exhausted and b's next char is NOT alpha → a is older
	//   - If a has remaining alpha content → a is older
	//   - Otherwise → a is newer
	if (i >= a.len && (j < b.len && !b[j].is_letter())) || (i < a.len && a[i].is_letter()) {
		return -1
	}

	return 1
}

// vercmp compares two Arch Linux package version strings and returns:
//   -1 if a < b
//    0 if a == b
//    1 if a > b
//
// The comparison follows pacman's alpm_pkg_vercmp() algorithm:
// parse [epoch:]version[-release], compare epoch, then version, then
// release (only when both strings carry a release component).
pub fn vercmp(a string, b string) int {
	// Handle empty strings.
	if a == '' && b == '' {
		return 0
	}
	if a == '' {
		return -1
	}
	if b == '' {
		return 1
	}

	// Quick equality shortcut.
	if a == b {
		return 0
	}

	// Parse into [epoch:]version[-release] components.
	epoch1, ver1, rel1 := parse_evr(a)
	epoch2, ver2, rel2 := parse_evr(b)

	// Compare epoch.
	mut ret := rpmvercmp(epoch1, epoch2)
	if ret != 0 {
		return ret
	}

	// Compare version.
	ret = rpmvercmp(ver1, ver2)
	if ret != 0 {
		return ret
	}

	// Compare release only when both carry one.
	if rel1 != '' && rel2 != '' {
		return rpmvercmp(rel1, rel2)
	}

	return 0
}
