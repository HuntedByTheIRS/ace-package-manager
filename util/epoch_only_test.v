// Edge-case tests: epoch-only version strings and parse_evr behavior.
//
// Covers:
//   - Epoch-only (e.g. "2:0" where epoch dominates)
//   - Epoch + version + release
//   - Zero epoch (equivalent to no epoch)
//   - Missing epoch (standard version)
//   - Very large epoch values
//   - Epoch with pre-release tilde
module util

// ---------------------------------------------------------------------------
// parse_evr — [epoch:]version[-release] parsing
// ---------------------------------------------------------------------------

fn test_parse_evr_standard() {
	epoch, version, release := parse_evr('1.0-1')
	assert epoch == '0'
	assert version == '1.0'
	assert release == '1'
}

fn test_parse_evr_epoch_version_release() {
	epoch, version, release := parse_evr('2:1.0-1')
	assert epoch == '2'
	assert version == '1.0'
	assert release == '1'
}

fn test_parse_evr_epoch_only_looks_like() {
	// "2:0" — version is "0", no release
	epoch, version, release := parse_evr('2:0')
	assert epoch == '2'
	assert version == '0'
	assert release == ''
}

fn test_parse_evr_zero_epoch() {
	// 0:1.0-1 — epoch 0 is equivalent to no epoch
	epoch, version, release := parse_evr('0:1.0-1')
	assert epoch == '0'
	assert version == '1.0'
	assert release == '1'
}

fn test_parse_evr_epoch_only_no_release() {
	epoch, version, release := parse_evr('5:2.0')
	assert epoch == '5'
	assert version == '2.0'
	assert release == ''
}

fn test_parse_evr_large_epoch() {
	epoch, version, release := parse_evr('999999:1.0-1')
	assert epoch == '999999'
	assert version == '1.0'
	assert release == '1'
}

fn test_parse_evr_no_version() {
	epoch, version, release := parse_evr('')
	assert epoch == '0'
	assert version == ''
	assert release == ''
}

fn test_parse_evr_tilde_version() {
	epoch, version, release := parse_evr('2:1.0~rc1-1')
	assert epoch == '2'
	assert version == '1.0~rc1'
	assert release == '1'
}

fn test_parse_evr_complex_pkgver() {
	// Example: pkgver=2:1.2.3+r45+gabcdef1-2
	epoch, version, release := parse_evr('2:1.2.3+r45+gabcdef1-2')
	assert epoch == '2'
	assert version == '1.2.3+r45+gabcdef1'
	assert release == '2'
}

// ---------------------------------------------------------------------------
// vercmp with epochs
// ---------------------------------------------------------------------------

fn test_vercmp_epoch_wins() {
	// Epoch dominates everything — 2:1.0 > 1:9.9.9
	assert vercmp('2:1.0', '1:9.9.9') == 1
	assert vercmp('1:9.9.9', '2:1.0') == -1
}

fn test_vercmp_epoch_equal() {
	// Same epoch, compare version
	assert vercmp('2:1.0-1', '2:2.0-1') == -1
	assert vercmp('2:2.0-1', '2:1.0-1') == 1
}

fn test_vercmp_zero_epoch_equals_no_epoch() {
	// 0:1.0 == 1.0
	assert vercmp('0:1.0', '1.0') == 0
}

fn test_vercmp_epoch_dominates_lower_version() {
	// 2:0 < 1:9.9.9? NO — 2 > 1 in epoch
	assert vercmp('2:0', '1:9.9.9') == 1
}

fn test_vercmp_epoch_only_vs_same() {
	assert vercmp('2:0', '2:0') == 0
}

fn test_vercmp_epoch_large_numbers() {
	assert vercmp('999999:1.0', '999998:999.0') == 1
}

fn test_vercmp_epoch_tilde() {
	// tilde in version with epoch
	assert vercmp('2:1.0~rc1', '2:1.0') == -1
	assert vercmp('2:1.0', '2:1.0~rc1') == 1
}
