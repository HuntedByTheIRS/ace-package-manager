module util

// ---------------------------------------------------------------------------
// split_pkgname tests
// ---------------------------------------------------------------------------

fn test_split_pkgname_standard() {
	split := split_pkgname('glibc-2.35-1-x86_64') or {
		assert false, 'expected success'
		return
	}
	assert split.name == 'glibc'
	assert split.version == '2.35'
	assert split.release == '1'
	assert split.arch == 'x86_64'
}

fn test_split_pkgname_hyphenated_name() {
	split := split_pkgname('gtk-update-icon-cache-3.24-1-x86_64') or {
		assert false, 'expected success'
		return
	}
	assert split.name == 'gtk-update-icon-cache'
	assert split.version == '3.24'
	assert split.release == '1'
	assert split.arch == 'x86_64'
}

fn test_split_pkgname_multi_digit_release() {
	split := split_pkgname('linux-6.1.12-3-x86_64') or {
		assert false, 'expected success'
		return
	}
	assert split.name == 'linux'
	assert split.version == '6.1.12'
	assert split.release == '3'
	assert split.arch == 'x86_64'
}

fn test_split_pkgname_epoch_prefix() {
	// Epoch is retained inside the version field (PkgNameSplit has no
	// separate epoch field — same convention as pacman's full ver string).
	split := split_pkgname('glibc-2:2.35-1-x86_64') or {
		assert false, 'expected success'
		return
	}
	assert split.name == 'glibc'
	assert split.version == '2:2.35'
	assert split.release == '1'
	assert split.arch == 'x86_64'
}

fn test_split_pkgname_no_arch() {
	split := split_pkgname('glibc-2.35-1') or {
		assert false, 'expected success'
		return
	}
	assert split.name == 'glibc'
	assert split.version == '2.35'
	assert split.release == '1'
	assert split.arch == ''
}

fn test_split_pkgname_no_release() {
	split := split_pkgname('glibc-2.35-x86_64') or {
		assert false, 'expected success'
		return
	}
	assert split.name == 'glibc'
	assert split.version == '2.35'
	assert split.release == ''
	assert split.arch == 'x86_64'
}

fn test_split_pkgname_no_release_no_arch() {
	split := split_pkgname('glibc-2.35') or {
		assert false, 'expected success'
		return
	}
	assert split.name == 'glibc'
	assert split.version == '2.35'
	assert split.release == ''
	assert split.arch == ''
}

fn test_split_pkgname_name_with_digits() {
	split := split_pkgname('2ping-2.0-1-any') or {
		assert false, 'expected success'
		return
	}
	assert split.name == '2ping'
	assert split.version == '2.0'
	assert split.release == '1'
	assert split.arch == 'any'
}

fn test_split_pkgname_empty_input() {
	if _ := split_pkgname('') {
		assert false, 'expected failure for empty input'
	}
}

fn test_split_pkgname_no_hyphen() {
	if _ := split_pkgname('justaname') {
		assert false, 'expected failure for name without hyphen'
	}
}

fn test_split_pkgname_only_hyphen() {
	if _ := split_pkgname('-') {
		assert false, 'expected failure for bare hyphen'
	}
}

fn test_split_pkgname_version_with_underscore() {
	split := split_pkgname('package-1.0_rc1-1-x86_64') or {
		assert false, 'expected success'
		return
	}
	assert split.name == 'package'
	assert split.version == '1.0_rc1'
	assert split.release == '1'
	assert split.arch == 'x86_64'
}

fn test_split_pkgname_version_with_plus() {
	split := split_pkgname('package-1.0+git20210101-1-x86_64') or {
		assert false, 'expected success'
		return
	}
	assert split.name == 'package'
	assert split.version == '1.0+git20210101'
	assert split.release == '1'
	assert split.arch == 'x86_64'
}

fn test_split_pkgname_version_with_tilde() {
	split := split_pkgname('package-1.0~rc1-1-x86_64') or {
		assert false, 'expected success'
		return
	}
	assert split.name == 'package'
	assert split.version == '1.0~rc1'
	assert split.release == '1'
	assert split.arch == 'x86_64'
}

fn test_split_pkgname_any_arch() {
	split := split_pkgname('python-3.10-1-any') or {
		assert false, 'expected success'
		return
	}
	assert split.name == 'python'
	assert split.version == '3.10'
	assert split.release == '1'
	assert split.arch == 'any'
}

fn test_split_pkgname_aarch64_arch() {
	split := split_pkgname('package-1.0-1-aarch64') or {
		assert false, 'expected success'
		return
	}
	assert split.name == 'package'
	assert split.version == '1.0'
	assert split.release == '1'
	assert split.arch == 'aarch64'
}

// ---------------------------------------------------------------------------
// split_pkgfile tests
// ---------------------------------------------------------------------------

fn test_split_pkgfile_zst() {
	split := split_pkgfile('glibc-2.35-1-x86_64.pkg.tar.zst') or {
		assert false, 'expected success'
		return
	}
	assert split.name == 'glibc'
	assert split.version == '2.35'
	assert split.release == '1'
	assert split.arch == 'x86_64'
	assert split.extension == '.pkg.tar.zst'
}

fn test_split_pkgfile_xz() {
	split := split_pkgfile('package-1.0-1-any.pkg.tar.xz') or {
		assert false, 'expected success'
		return
	}
	assert split.name == 'package'
	assert split.version == '1.0'
	assert split.release == '1'
	assert split.arch == 'any'
	assert split.extension == '.pkg.tar.xz'
}

fn test_split_pkgfile_gz() {
	split := split_pkgfile('old-package-0.5-1-x86_64.pkg.tar.gz') or {
		assert false, 'expected success'
		return
	}
	assert split.name == 'old-package'
	assert split.version == '0.5'
	assert split.release == '1'
	assert split.arch == 'x86_64'
	assert split.extension == '.pkg.tar.gz'
}

fn test_split_pkgfile_hyphenated_name() {
	split := split_pkgfile('gtk-update-icon-cache-3.24-1-x86_64.pkg.tar.zst') or {
		assert false, 'expected success'
		return
	}
	assert split.name == 'gtk-update-icon-cache'
	assert split.version == '3.24'
	assert split.release == '1'
	assert split.arch == 'x86_64'
	assert split.extension == '.pkg.tar.zst'
}

fn test_split_pkgfile_unknown_extension() {
	if _ := split_pkgfile('package-1.0-1-x86_64.sig') {
		assert false, 'expected failure for unknown extension'
	}
}

fn test_split_pkgfile_no_extension() {
	if _ := split_pkgfile('package-1.0-1-x86_64') {
		assert false, 'expected failure for filename without extension'
	}
}

fn test_split_pkgfile_empty() {
	if _ := split_pkgfile('') {
		assert false, 'expected failure for empty filename'
	}
}

// Verify that PkgNameSplitWithExt embeds PkgNameSplit fields.
fn test_split_pkgfile_embedding() {
	split := split_pkgfile('foo-1.0-1-x86_64.pkg.tar.zst') or {
		assert false, 'expected success'
		return
	}
	// Access embedded PkgNameSplit fields directly.
	assert split.name == 'foo'
	assert split.version == '1.0'
	assert split.release == '1'
	assert split.arch == 'x86_64'
	assert split.extension == '.pkg.tar.zst'
}
