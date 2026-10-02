module archive

// Read holds context for a single block read callback.
// The implementor can inspect the path, block_number, and entry details,
// and set stop_early = true to abort reading.
pub struct Read {
mut:
	block_number int
	entry_type   string
	path         string
	size         u64
pub mut:
	stop_early bool
}

// Reader is the callback interface for archive entry traversal.
// Implementations receive callbacks as each entry is read from the archive.
// Set read.stop_early = true in any callback to abort further reading.
pub interface Reader {
mut:
	// dir_block is called when a directory entry is read.
	dir_block(mut read Read, size u64)

	// file_block is called when a file entry is read.
	// size is the expected file size in bytes.
	file_block(mut read Read, size u64)

	// data_block is called with file data chunks.
	// data contains up to block_size bytes. pending indicates remaining bytes.
	data_block(mut read Read, data []u8, pending int)

	// other_block is called for entry types other than directory, file, or unknown.
	other_block(mut read Read, details string)
}

// DebugReader implements Reader and prints each block to stdout.
pub struct DebugReader {}

fn (mut d DebugReader) dir_block(mut read Read, size u64) {
	println('DIR:  block ${read.block_number}  size ${size}  path "${read.path}"')
}

fn (mut d DebugReader) file_block(mut read Read, size u64) {
	println('FILE: block ${read.block_number}  size ${size}  path "${read.path}"')
}

fn (mut d DebugReader) data_block(mut read Read, data []u8, pending int) {
	println('DATA: block ${read.block_number}  ${data.len} bytes  ${pending} pending  path "${read.path}"')
}

fn (mut d DebugReader) other_block(mut read Read, details string) {
	println('OTHER: block ${read.block_number}  type "${details}"  path "${read.path}"')
}

// new_debug_reader returns a new DebugReader.
pub fn new_debug_reader() DebugReader {
	return DebugReader{}
}

// read_archive_callback reads all entries from the archive, calling the
// appropriate Reader callback for each entry type. Stops early if the
// callback sets read.stop_early = true.
pub fn read_archive_callback(a &ArchiveReader, mut cb Reader) ! {
	mut block_number := 0
	for {
		entry := a.next_header() or { break }

		mut read := Read{
			block_number: block_number
			path:    entry.pathname()
			size:    u64(entry.size())
		}

		if entry.is_dir() {
			cb.dir_block(mut read, u64(entry.size()))
		} else if entry.is_file() {
			cb.file_block(mut read, u64(entry.size()))
			// Stream file data in chunks
			mut buf := []u8{len: 32768}
			for {
				n := a.read_data(mut buf) or { break }
				if n <= 0 {
					break
				}
				pending := int(u64(entry.size()) - u64(block_number * 32768 + buf.len))
				if pending < 0 {
					break
				}
				cb.data_block(mut read, buf[..int(n)], pending)
				if read.stop_early {
					return
				}
			}
			if read.stop_early {
				return
			}
		} else {
			details := entry.strmode()
			cb.other_block(mut read, details)
		}

		if read.stop_early {
			return
		}
		block_number++
	}
}
