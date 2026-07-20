module lib

// V C interop wrapper for libzstd.
// Exposes safe decompression — no raw C pointers reach the caller.
#flag -lzstd
#include <zstd.h>

// ---------- C function declarations ----------

fn C.ZSTD_decompress(dst voidptr, dst_capacity u64, src voidptr, src_size u64) u64
fn C.ZSTD_getFrameContentSize(src voidptr, src_size u64) u64
fn C.ZSTD_isError(code u64) int

// ---------- public wrappers ----------

// zstd_decompress decompresses a zstd-compressed byte slice.
// The caller passes compressed data and gets back the decompressed bytes,
// or an error if decompression fails (corrupt data, truncated input, etc.).
pub fn zstd_decompress(compressed []u8) ![]u8 {
	// Determine the decompressed size from the frame header.
	content_size := C.ZSTD_getFrameContentSize(compressed.data, compressed.len)
	// content_size == 0 on error; ULLONG_MAX means "unknown" (requires streaming).
	if content_size == 0 || content_size == u64(0xFFFFFFFFFFFFFFFF) {
		return error('zstd: cannot determine decompressed size (unknown or corrupt frame)')
	}

	// Allocate the exact output buffer.
	mut decompressed := []u8{len: int(content_size)}

	// Perform the single-pass decompression.
	result := C.ZSTD_decompress(decompressed.data, content_size, compressed.data, compressed.len)

	if C.ZSTD_isError(result) != 0 {
		return error('zstd: decompression failed')
	}

	return decompressed
}
