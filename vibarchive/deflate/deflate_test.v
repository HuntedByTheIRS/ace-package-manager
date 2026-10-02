module deflate

fn test_compress_decompress_roundtrip() {
	data := 'hello world'.bytes()
	compressed := compress(data)!
	decompressed := decompress(compressed)!
	assert decompressed.len == data.len
	assert decompressed.bytestr() == data.bytestr()
}

fn test_empty_data() {
	data := []u8{}
	compressed := compress(data)!
	decompressed := decompress(compressed)!
	assert decompressed.len == 0
}

fn test_binary_data() {
	data := []u8{len: 256, init: u8(0x42)}
	compressed := compress(data)!
	decompressed := decompress(compressed)!
	assert decompressed.len == 256
	assert decompressed[0] == u8(0x42)
	assert decompressed[255] == u8(0x42)
}
