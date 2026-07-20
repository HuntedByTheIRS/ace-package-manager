module util

struct VercmpCase {
	a        string
	b        string
	expected int
}

fn test_vercmp() {
	tests := [
		// ---- basic equality / inequality ----
		VercmpCase{'1.0', '1.0', 0},
		VercmpCase{'2.0', '1.0', 1},
		VercmpCase{'1.0', '2.0', -1},
		// ---- same length, no pkgrel ----
		VercmpCase{'1.5.0', '1.5.0', 0},
		VercmpCase{'1.5.1', '1.5.0', 1},
		// ---- mixed length ----
		VercmpCase{'1.5.1', '1.5', 1},
		// ---- with pkgrel, simple ----
		VercmpCase{'1.5.0-1', '1.5.0-1', 0},
		VercmpCase{'1.5.0-1', '1.5.0-2', -1},
		VercmpCase{'1.5.0-1', '1.5.1-1', -1},
		VercmpCase{'1.5.0-2', '1.5.1-1', -1},
		// ---- with pkgrel, mixed lengths ----
		VercmpCase{'1.5-1', '1.5.1-1', -1},
		VercmpCase{'1.5-2', '1.5.1-1', -1},
		VercmpCase{'1.5-2', '1.5.1-2', -1},
		// ---- mixed pkgrel inclusion (one has -pkgrel, other doesn't) ----
		VercmpCase{'1.5', '1.5-1', 0},
		VercmpCase{'1.5-1', '1.5', 0},
		VercmpCase{'1.1-1', '1.1', 0},
		VercmpCase{'1.0-1', '1.1', -1},
		VercmpCase{'1.1-1', '1.0', 1},
		// ---- alphanumeric / pre-release ----
		VercmpCase{'1.5b-1', '1.5-1', -1},
		VercmpCase{'1.5b', '1.5', -1},
		VercmpCase{'1.5b-1', '1.5', -1},
		VercmpCase{'1.5b', '1.5.1', -1},
		// ---- from the pacman manpage ----
		VercmpCase{'1.0a', '1.0alpha', -1},
		VercmpCase{'1.0alpha', '1.0b', -1},
		VercmpCase{'1.0b', '1.0beta', -1},
		VercmpCase{'1.0beta', '1.0rc', -1},
		VercmpCase{'1.0rc', '1.0', -1},
		// ---- alpha-dotted versions ----
		VercmpCase{'1.5.a', '1.5', 1},
		VercmpCase{'1.5.b', '1.5.a', 1},
		VercmpCase{'1.5.1', '1.5.b', 1},
		// ---- alpha dots and dashes ----
		VercmpCase{'1.5.b-1', '1.5.b', 0},
		VercmpCase{'1.5-1', '1.5.b', -1},
		// ---- differing separators ----
		VercmpCase{'2.0', '2_0', 0},
		VercmpCase{'2.0_a', '2_0.a', 0},
		VercmpCase{'2.0a', '2.0.a', -1},
		VercmpCase{'2___a', '2_a', 1},
		// ---- epoch comparisons ----
		VercmpCase{'1:1.0', '2:0.9', -1},
		VercmpCase{'2:1.0', '1:2.0', 1},
		VercmpCase{'0:1.0', '0:1.0', 0},
		VercmpCase{'0:1.0', '0:1.1', -1},
		VercmpCase{'1:1.0', '0:1.0', 1},
		VercmpCase{'1:1.0', '0:1.1', 1},
		VercmpCase{'1:1.0', '2:1.1', -1},
		// ---- epoch + pkgrel ----
		VercmpCase{'1:1.0', '0:1.0-1', 1},
		VercmpCase{'1:1.0-1', '0:1.1-1', 1},
		// ---- epoch on one side only ----
		VercmpCase{'0:1.0', '1.0', 0},
		VercmpCase{'0:1.0', '1.1', -1},
		VercmpCase{'0:1.1', '1.0', 1},
		VercmpCase{'1:1.0', '1.0', 1},
		VercmpCase{'1:1.0', '1.1', 1},
		VercmpCase{'1:1.1', '1.1', 1},
		// ---- leading zeros (RPM strips leading zeros, so 01 == 1) ----
		VercmpCase{'1.01', '1.1', 0},
		VercmpCase{'1.1', '1.01', 0},
		VercmpCase{'1.00', '1.0', 0},
		VercmpCase{'1.010', '1.01', 1},
		// ---- tilde (pre-release) ----
		VercmpCase{'1.0~rc1', '1.0', -1},
		VercmpCase{'1.0', '1.0~rc1', 1},
		VercmpCase{'1.0~rc1', '1.0~rc2', -1},
		VercmpCase{'1.0~rc2', '1.0~rc1', 1},
		VercmpCase{'1.0~rc1', '1.0~rc1', 0},
		// ---- comma-separated versions (from pacman test) ----
		VercmpCase{'5.1.0-3', '5.1.1-1', -1},
		// ---- empty / edge strings ----
		VercmpCase{'', '', 0},
		VercmpCase{'', '1.0', -1},
		VercmpCase{'1.0', '', 1},
		// ---- epoch-only edge cases ----
		VercmpCase{':1.0', '1.0', 0},
		VercmpCase{'0:1.0', ':1.0', 0},
		// ---- numeric segments overflow protection (long numbers) ----
		VercmpCase{'12345678901234567890', '12345678901234567890', 0},
		VercmpCase{'12345678901234567890', '12345678901234567891', -1},
		VercmpCase{'12345678901234567891', '12345678901234567890', 1},
		// ---- mixed alpha across segments ----
		VercmpCase{'1.0.1', '1.0.a', 1},
		VercmpCase{'1.0.a', '1.0.1', -1},
		// ---- multiple numeric segments ----
		VercmpCase{'1.2.3.4.5', '1.2.3.4.5', 0},
		VercmpCase{'1.2.3.4.5', '1.2.3.4.6', -1},
		VercmpCase{'1.2.3.4.6', '1.2.3.4.5', 1},
		// ---- complex real-world examples ----
		VercmpCase{'2.35-1', '2.35-1', 0},
		VercmpCase{'2.35-1', '2.35-2', -1},
		VercmpCase{'2.35-2', '2.35-10', -1}, // numeric segment, not lexicographic
		VercmpCase{'2.35-10', '2.35-2', 1},
		VercmpCase{'3.0.1-1', '3.0.0-1', 1},
		VercmpCase{'3.0.0-1', '3.0.1-1', -1},
		// ---- underscore vs dot separator ----
		VercmpCase{'1.0_1', '1.0.1', 0},
		VercmpCase{'1_0_1', '1.0.1', 0},
		// ---- plus sign as separator ----
		VercmpCase{'1.0+git20210101', '1.0+git20210101', 0},
		VercmpCase{'1.0+git20210101', '1.0+git20210102', -1},
		VercmpCase{'1.0+git20210102', '1.0+git20210101', 1},
	]

	for t in tests {
		got := vercmp(t.a, t.b)
		assert got == t.expected, 'vercmp(${t.a}, ${t.b}) = ${got}, expected ${t.expected}'
	}
}

fn test_vercmp_symmetric() {
	// Verify symmetry: vercmp(a,b) == -vercmp(b,a) for all non-equal pairs
	pairs := [
		['2.0', '1.0'],
		['1.5.1', '1.5'],
		['1.5.0-1', '1.5.0-2'],
		['1.0~rc1', '1.0'],
		['1:1.0', '0:1.0'],
		['1.01', '1.1'],
		['1.0a', '1.0alpha'],
		['2.0a', '2.0.a'],
		['2___a', '2_a'],
	]
	for pair in pairs {
		a, b := pair[0], pair[1]
		forward := vercmp(a, b)
		reverse := vercmp(b, a)
		assert forward == -reverse, 'symmetry broken: vercmp(${a}, ${b}) = ${forward}, vercmp(${b}, ${a}) = ${reverse}'
	}
}

fn test_vercmp_identity() {
	// Every version compared to itself must be 0
	versions := [
		'',
		'1.0',
		'1.0-1',
		'2:1.0',
		'1:1.0-1',
		'1.0~rc1',
		'1.01',
		'5.1.0-3',
		'12345678901234567890',
		'1.0+git20210101',
	]
	for v in versions {
		assert vercmp(v, v) == 0, 'identity broken: vercmp(${v}, ${v}) = ${vercmp(v, v)}'
	}
}
