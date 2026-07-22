module szip

fn test_compress_decompress_roundtrip() {
	data := [u8(0x41), 0x42, 0x43, 0x44, 0x45].clone()
	compressed := compress(data)!
	decompressed := decompress(compressed)!
	assert decompressed == data
}
