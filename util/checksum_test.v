module util

import os

const checksum_test_content = 'The quick brown fox jumps over the lazy dog\n'

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn checksum_tempfile(content string) string {
	path := os.join_path(os.temp_dir(), 'ace_checksum_test.txt')
	os.write_file(path, content) or { assert false, 'write temp file: ${err}' }
	return path
}

fn checksum_cli_hash(cmd string) string {
	res := os.execute(cmd)
	assert res.exit_code == 0, 'CLI command failed: ${cmd}\n  stdout: ${res.output}\n  (is the tool installed?)'
	return res.output.split(' ')[0]
}

// ---------------------------------------------------------------------------
// md5sum
// ---------------------------------------------------------------------------

fn test_md5sum_matches_cli() {
	path := checksum_tempfile(checksum_test_content)
	defer {
		os.rm(path) or {}
	}

	our := md5sum(path) or { assert false, err.msg(); return }
	cli := checksum_cli_hash('md5sum "${path}"')

	assert our == cli, 'our=${our}  cli=${cli}'
}

// ---------------------------------------------------------------------------
// sha256sum
// ---------------------------------------------------------------------------

fn test_sha256sum_matches_cli() {
	path := checksum_tempfile(checksum_test_content)
	defer {
		os.rm(path) or {}
	}

	our := sha256sum(path) or { assert false, err.msg(); return }
	cli := checksum_cli_hash('sha256sum "${path}"')

	assert our == cli, 'our=${our}  cli=${cli}'
}

// ---------------------------------------------------------------------------
// blake2bsum 512  (b2sum output, default length = 512)
// ---------------------------------------------------------------------------

fn test_blake2bsum_512_matches_cli() {
	path := checksum_tempfile(checksum_test_content)
	defer {
		os.rm(path) or {}
	}

	our := blake2bsum(path, 512) or { assert false, err.msg(); return }
	cli := checksum_cli_hash('b2sum "${path}"')

	assert our == cli, 'our=${our}  cli=${cli}'
}

// ---------------------------------------------------------------------------
// blake2bsum 256
// ---------------------------------------------------------------------------

fn test_blake2bsum_256() {
	path := checksum_tempfile(checksum_test_content)
	defer {
		os.rm(path) or {}
	}

	// b2sum --length=256 gives a different-length hash (64 hex chars vs 128)
	our := blake2bsum(path, 256) or { assert false, err.msg(); return }
	cli := checksum_cli_hash('b2sum --length=256 "${path}"')

	assert our == cli, 'our=${our}  cli=${cli}'
}

// ---------------------------------------------------------------------------
// blake2bsum invalid bits
// ---------------------------------------------------------------------------

fn test_blake2bsum_invalid_bits_returns_error() {
	path := checksum_tempfile(checksum_test_content)
	defer {
		os.rm(path) or {}
	}

	blake2bsum(path, 128) or { return }
	assert false, 'expected error for bits=128'
}

// ---------------------------------------------------------------------------
// verify_checksum — correct hash → true
// ---------------------------------------------------------------------------

fn test_verify_checksum_correct() {
	path := checksum_tempfile(checksum_test_content)
	defer {
		os.rm(path) or {}
	}

	hash := md5sum(path) or { assert false, err.msg(); return }
	ok := verify_checksum(path, hash, .md5) or {
		assert false, err.msg(); return
	}
	assert ok == true
}

// ---------------------------------------------------------------------------
// verify_checksum — wrong hash → false
// ---------------------------------------------------------------------------

fn test_verify_checksum_wrong() {
	path := checksum_tempfile(checksum_test_content)
	defer {
		os.rm(path) or {}
	}

	ok := verify_checksum(path, '00000000000000000000000000000000', .md5) or {
		assert false, err.msg(); return
	}
	assert ok == false
}

// ---------------------------------------------------------------------------
// verify_checksum — nonexistent file → error
// ---------------------------------------------------------------------------

fn test_verify_checksum_nonexistent_file() {
	verify_checksum('/tmp/ace_nonexistent_XXXXXXXX', 'abc', .md5) or {
		return
	}
	assert false, 'expected error for nonexistent file'
}

// ---------------------------------------------------------------------------
// verify_checksum with all three algos (correct hash)
// ---------------------------------------------------------------------------

fn test_verify_checksum_md5() {
	path := checksum_tempfile(checksum_test_content)
	defer {
		os.rm(path) or {}
	}

	hash := md5sum(path) or { assert false, err.msg(); return }
	ok := verify_checksum(path, hash, .md5) or { assert false, err.msg(); return }
	assert ok
}

fn test_verify_checksum_sha256() {
	path := checksum_tempfile(checksum_test_content)
	defer {
		os.rm(path) or {}
	}

	hash := sha256sum(path) or { assert false, err.msg(); return }
	ok := verify_checksum(path, hash, .sha256) or { assert false, err.msg(); return }
	assert ok
}

fn test_verify_checksum_blake2b() {
	path := checksum_tempfile(checksum_test_content)
	defer {
		os.rm(path) or {}
	}

	hash := blake2bsum(path, 512) or { assert false, err.msg(); return }
	ok := verify_checksum(path, hash, .blake2b) or { assert false, err.msg(); return }
	assert ok
}

// ---------------------------------------------------------------------------
// Edge: md5sum of a non-existent file returns an error
// ---------------------------------------------------------------------------

fn test_md5sum_nonexistent_file() {
	md5sum('/tmp/ace_nonexistent_XXXXXXXX_md5') or { return }
	assert false, 'expected error for nonexistent file'
}

fn test_sha256sum_nonexistent_file() {
	sha256sum('/tmp/ace_nonexistent_XXXXXXXX_sha256') or { return }
	assert false, 'expected error for nonexistent file'
}

fn test_blake2bsum_nonexistent_file() {
	blake2bsum('/tmp/ace_nonexistent_XXXXXXXX_blake', 512) or { return }
	assert false, 'expected error for nonexistent file'
}
