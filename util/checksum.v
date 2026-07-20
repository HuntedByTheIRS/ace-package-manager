module util

import os
import crypto.md5
import crypto.sha256
import crypto.blake2b

// ChecksumAlgo enumerates the supported hash algorithms.
pub enum ChecksumAlgo {
	md5
	sha256
	blake2b
}

// read_chunk_size is 64 KiB — large enough for efficient streaming
// without loading the entire file into memory.
const read_chunk_size = 65536

// md5sum computes the MD5 hex hash of a file.
// The result matches the `md5sum` CLI tool output.
pub fn md5sum(path string) !string {
	mut f := os.open_file(path, 'r', 0)!
	defer {
		f.close()
	}

	mut h := md5.new()
	mut buf := []u8{len: read_chunk_size}

	for {
		n := f.read(mut buf) or { break }
		h.write(buf[..n])!
	}

	return h.sum([]u8{}).hex()
}

// sha256sum computes the SHA256 hex hash of a file.
// The result matches the `sha256sum` CLI tool output.
pub fn sha256sum(path string) !string {
	mut f := os.open_file(path, 'r', 0)!
	defer {
		f.close()
	}

	mut h := sha256.new()
	mut buf := []u8{len: read_chunk_size}

	for {
		n := f.read(mut buf) or { break }
		h.write(buf[..n])!
	}

	return h.sum([]u8{}).hex()
}

// blake2bsum computes the BLAKE2b hex hash of a file with the given
// digest size in bits (256 or 512).  The result matches the `b2sum` CLI
// tool output for the respective size.
pub fn blake2bsum(path string, bits int) !string {
	if bits != 256 && bits != 512 {
		return error('blake2bsum: bits must be 256 or 512, got ${bits}')
	}

	mut f := os.open_file(path, 'r', 0)!
	defer {
		f.close()
	}

	mut h := blake2b.new256()!
	if bits == 512 {
		h = blake2b.new512()!
	}

	mut buf := []u8{len: read_chunk_size}

	for {
		n := f.read(mut buf) or { break }
		h.write(buf[..n])!
	}

	return h.checksum().hex()
}

// verify_checksum verifies that the file at `path` hashes to the
// expected hex string using the given algorithm.  Returns `true` when
// the hash matches, `false` when it does not, or an error when the
// file cannot be read.
pub fn verify_checksum(path string, expected string, algo ChecksumAlgo) !bool {
	computed := match algo {
		.md5 { md5sum(path)! }
		.sha256 { sha256sum(path)! }
		.blake2b { blake2bsum(path, 512)! }
	}
	return computed == expected
}
