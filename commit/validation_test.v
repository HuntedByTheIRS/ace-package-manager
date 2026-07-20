module commit

import os
import util

// ---------------------------------------------------------------------------
// helper functions (no test_ prefix — they are not test functions)
// ---------------------------------------------------------------------------

fn tempfile(content string) string {
	path := os.join_path(os.temp_dir(), 'ace_commit_test.bin')
	os.write_file(path, content) or { assert false, 'write temp file: ${err}' }
	return path
}

fn make_handle() util.Handle {
	return util.Handle{
		root:      '/'
		dbpath:    '/var/lib/ace/'
		gpgdir:    '/etc/ace/gnupg'
		cachedirs: ['/var/cache/ace/pkg/']
	}
}

// ---------------------------------------------------------------------------
// validate_package tests
// ---------------------------------------------------------------------------

fn test_validate_package_nonexistent_file() {
	handle := make_handle()
	pkg := util.Package{
		name:    'test-pkg'
		version: '1.0-1'
		arch:    'x86_64'
	}
	validate_package(&handle, '/tmp/nonexistent_ace_test_XXXXX', &pkg, 0) or {
		return // expected
	}
	assert false, 'expected error for nonexistent file'
}

fn test_validate_package_empty_file() {
	handle := make_handle()
	path := tempfile('')
	defer {
		os.rm(path) or {}
	}

	pkg := util.Package{
		name:    'test-pkg'
		version: '1.0-1'
		arch:    'x86_64'
	}
	validate_package(&handle, path, &pkg, 0) or {
		assert err.msg().contains('empty')
		return
	}
	assert false, 'expected error for empty file'
}

fn test_validate_package_checksum_mismatch() {
	handle := make_handle()
	path := tempfile('hello package data')
	defer {
		os.rm(path) or {}
	}

	pkg := util.Package{
		name:      'test-pkg'
		version:   '1.0-1'
		arch:      'x86_64'
		sha256sum: '0000000000000000000000000000000000000000000000000000000000000000'
	}
	validate_package(&handle, path, &pkg, 	int(0)) or {
		assert err.msg().contains('checksum mismatch')
		return
	}
	assert false, 'expected checksum mismatch error'
}

fn test_validate_package_checksum_match() {
	handle := make_handle()
	content := 'hello package data'
	path := tempfile(content)
	defer {
		os.rm(path) or {}
	}

	hash := util.sha256sum(path) or { assert false, err.msg(); return }

	pkg := util.Package{
		name:      'test-pkg'
		version:   '1.0-1'
		arch:      'x86_64'
		sha256sum: hash
	}
	validate_package(&handle, path, &pkg, 	int(0)) or {
		assert false, 'expected no error: ${err.msg()}'
		return
	}
}

fn test_validate_package_no_expected_hash() {
	// When package has no expected SHA256, validation should pass
	// (it computes the hash but doesn't compare).
	handle := make_handle()
	path := tempfile('some package data')
	defer {
		os.rm(path) or {}
	}

	pkg := util.Package{
		name:    'test-pkg'
		version: '1.0-1'
		arch:    'x86_64'
		// sha256sum is empty — no expected hash to compare
	}
	validate_package(&handle, path, &pkg, 	int(0)) or {
		assert false, 'expected no error: ${err.msg()}'
		return
	}
}

// ---------------------------------------------------------------------------
// is_corrupted_pkg tests
// ---------------------------------------------------------------------------

fn test_is_corrupted_pkg_checksum_mismatch() {
	assert is_corrupted_pkg('SHA256 checksum mismatch for foo')
}

fn test_is_corrupted_pkg_signature_failure() {
	assert is_corrupted_pkg('PGP signature verification failed')
}

fn test_is_corrupted_pkg_empty_file() {
	assert is_corrupted_pkg('package file is empty')
}

fn test_is_corrupted_pkg_normal() {
	assert !is_corrupted_pkg('disk space error')
	assert !is_corrupted_pkg('permission denied')
	assert !is_corrupted_pkg('file not found in cache')
}

// ---------------------------------------------------------------------------
// verify_package_signature tests (siglevel = Never — skip)
// ---------------------------------------------------------------------------

fn test_verify_signature_siglevel_never() {
	handle := make_handle()
	pkg := util.Package{
		name:    'test-pkg'
		version: '1.0-1'
	}
	result := verify_package_signature(&handle, '', &pkg, 	int(0)) or {
		assert false, 'expected no error: ${err.msg()}'; return
	}
	assert result.success
}

fn test_verify_signature_missing_optional() {
	handle := make_handle()
	// Optional siglevel (without Required) — missing sig is OK.
	siglevel := 	int(1) // optional = 1
	pkg := util.Package{
		name:    'test-pkg'
		version: '1.0-1'
	}
	result := verify_package_signature(&handle, '/tmp/nonexistent', &pkg, siglevel) or {
		assert false, 'expected no error for missing optional sig: ${err.msg()}'; return
	}
	assert result.success
}

fn test_verify_signature_missing_required() {
	handle := make_handle()
	// Required siglevel but no .sig file.
	siglevel := 	int(2) // required = 2
	pkg := util.Package{
		name:    'test-pkg'
		version: '1.0-1'
	}
	result := verify_package_signature(&handle, '/tmp/nonexistent', &pkg, siglevel) or {
		assert false, 'expected non-error result (success=false)'; return
	}
	assert !result.success
	assert result.err_msg.contains('missing required PGP signature')
}


