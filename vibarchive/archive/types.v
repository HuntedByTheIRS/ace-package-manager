module archive

// --- Enums ---

// Compression specifies the compression algorithm.
pub enum Compression {
	none
	gzip
	bzip2
	zstd
	xz
	lz4
	lzma
}

// ArchiveFormat specifies the archive container format.
pub enum ArchiveFormat {
	tar
	tar_gz
	tar_bz2
	tar_zst
	tar_xz
	zip
	raw
	seven_zip
}

// --- Option structs ---

// ExtractOpts controls extraction behavior.
@[params]
pub struct ExtractOpts {
pub:
	overwrite        bool = true
	strip_components int
	allow_symlinks   bool = true
	prevent_traversal bool = true
}

// SafeOpts controls safety checks during extraction.
@[params]
pub struct SafeOpts {
pub:
	prevent_traversal bool = true
	allow_symlinks    bool = true
	strip_components  int
}

// CreateOpts controls archive creation behavior.
@[params]
pub struct CreateOpts {
pub:
	compression Compression = .gzip
	format      ArchiveFormat = .tar_gz
	level       int = 6
}

// --- Callback type aliases ---

pub type EntryCallback = fn (entry &ArchiveEntry)
pub type ProgressCallback = fn (done int, total int)
pub type ErrorCallback = fn (err string)
pub type EntryFilter = fn (entry &ArchiveEntry) bool


// FileEntry holds information about an entry in an archive.
pub struct FileEntry {
pub:
	path     string
	size     i64
	is_dir   bool
	is_file  bool
	is_link  bool
	mode     u32
	uid      i64
	gid      i64
	mod_time i64
}
