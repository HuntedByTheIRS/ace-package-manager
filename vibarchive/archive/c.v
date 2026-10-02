module archive

#flag -larchive

#include "archive.h"
#include "archive_entry.h"

// Opaque structs
pub struct C.struct_archive {}
pub struct C.struct_archive_entry {}
pub struct C.wchar_t {}

// Return code constants
pub const archive_ok     = 0
pub const archive_eof    = 1
pub const archive_retry  = -10
pub const archive_warn   = -20
pub const archive_failed = -25
pub const archive_fatal  = -30

// Read lifecycle
fn C.archive_read_new() &C.struct_archive
fn C.archive_read_free(&C.struct_archive) i32
fn C.archive_read_close(&C.struct_archive) i32

// Format support
fn C.archive_read_support_format_all(&C.struct_archive) i32
fn C.archive_read_support_format_tar(&C.struct_archive) i32
fn C.archive_read_support_format_zip(&C.struct_archive) i32
fn C.archive_read_support_format_7zip(&C.struct_archive) i32
fn C.archive_read_support_format_iso9660(&C.struct_archive) i32
fn C.archive_read_support_format_raw(&C.struct_archive) i32
fn C.archive_read_support_format_empty(&C.struct_archive) i32
fn C.archive_read_support_format_cpio(&C.struct_archive) i32
fn C.archive_read_support_format_rar(&C.struct_archive) i32
fn C.archive_read_support_format_gnutar(&C.struct_archive) i32

// Filter support
fn C.archive_read_support_filter_all(&C.struct_archive) i32
fn C.archive_read_support_filter_gzip(&C.struct_archive) i32
fn C.archive_read_support_filter_bzip2(&C.struct_archive) i32
fn C.archive_read_support_filter_zstd(&C.struct_archive) i32
fn C.archive_read_support_filter_xz(&C.struct_archive) i32
fn C.archive_read_support_filter_lz4(&C.struct_archive) i32
fn C.archive_read_support_filter_lzma(&C.struct_archive) i32
fn C.archive_read_support_filter_compress(&C.struct_archive) i32
fn C.archive_read_support_filter_lzip(&C.struct_archive) i32
fn C.archive_read_support_filter_lzop(&C.struct_archive) i32
fn C.archive_read_support_filter_grzip(&C.struct_archive) i32
fn C.archive_read_support_filter_lrzip(&C.struct_archive) i32
fn C.archive_read_support_filter_none(&C.struct_archive) i32
fn C.archive_read_support_filter_program(&C.struct_archive, &char) i32
fn C.archive_read_support_filter_uu(&C.struct_archive) i32
fn C.archive_read_support_filter_rpm(&C.struct_archive) i32

// Open functions
@[keep_args_alive]
fn C.archive_read_open_memory(&C.struct_archive, voidptr, u64) i32
fn C.archive_read_open_filename(&C.struct_archive, &char, u64) i32
fn C.archive_read_open_fd(&C.struct_archive, i32, u64) i32
fn C.archive_read_open_FILE(&C.struct_archive, &C.FILE, u64) i32

// Entry iteration
fn C.archive_read_next_header(&C.struct_archive, &&C.struct_archive_entry) i32
fn C.archive_read_next_header2(&C.struct_archive, &C.struct_archive_entry) i32

// Data reading
@[keep_args_alive]
fn C.archive_read_data(&C.struct_archive, voidptr, u64) i64
fn C.archive_read_data_skip(&C.struct_archive) i32
fn C.archive_read_data_into_fd(&C.struct_archive, i32) i32

// Utility
fn C.archive_error_string(&C.struct_archive) &char
fn C.archive_errno(&C.struct_archive) i32
fn C.archive_file_count(&C.struct_archive) i32
fn C.archive_format(&C.struct_archive) i32
fn C.archive_format_name(&C.struct_archive) &char
fn C.archive_filter_count(&C.struct_archive) i32
fn C.archive_filter_code(&C.struct_archive, i32) i32
fn C.archive_filter_name(&C.struct_archive, i32) &char

// Filter code constants
pub const archive_filter_none     = 0
pub const archive_filter_gzip     = 1
pub const archive_filter_bzip2    = 2
pub const archive_filter_compress = 3
pub const archive_filter_program  = 4
pub const archive_filter_lzma     = 5
pub const archive_filter_xz       = 6
pub const archive_filter_uu       = 7
pub const archive_filter_rpm      = 8
pub const archive_filter_lzip     = 9
pub const archive_filter_lrzip    = 10
pub const archive_filter_lzop     = 11
pub const archive_filter_grzip    = 12
pub const archive_filter_lz4      = 13
pub const archive_filter_zstd     = 14

// Format code constants
pub const archive_format_base_mask           = i32(0xff0000)
pub const archive_format_tar                 = i32(0x30000)
pub const archive_format_tar_ustar           = i32(0x30001)
pub const archive_format_tar_pax_interchange = i32(0x30002)
pub const archive_format_tar_pax_restricted  = i32(0x30003)
pub const archive_format_tar_gnutar          = i32(0x30004)
pub const archive_format_zip                 = i32(0x50000)
pub const archive_format_raw                 = i32(0x90000)
pub const archive_format_7zip                = i32(0xe0000)
pub const archive_format_iso9660             = i32(0x40000)
pub const archive_format_cpio                = i32(0x10000)
pub const archive_format_empty               = i32(0x60000)
pub const archive_format_ar                  = i32(0x70000)
pub const archive_format_xar                 = i32(0xa0000)
pub const archive_format_lha                 = i32(0xb0000)
pub const archive_format_cab                 = i32(0xc0000)
pub const archive_format_rar                 = i32(0xd0000)
pub const archive_format_warc                = i32(0xf0000)

// File type constants
pub const ae_ifmt  = i32(0o170000)
pub const ae_ifreg = i32(0o100000)
pub const ae_iflnk = i32(0o120000)
pub const ae_ifsock = i32(0o140000)
pub const ae_ifchr = i32(0o020000)
pub const ae_ifblk = i32(0o060000)
pub const ae_ifdir = i32(0o040000)
pub const ae_ififo = i32(0o010000)

// Write lifecycle
fn C.archive_write_new() &C.struct_archive
fn C.archive_write_free(&C.struct_archive) i32
fn C.archive_write_close(&C.struct_archive) i32
fn C.archive_write_finish_entry(&C.struct_archive) i32

// Write open functions
@[keep_args_alive]
fn C.archive_write_open_memory(&C.struct_archive, voidptr, u64, &u64) i32
fn C.archive_write_open_filename(&C.struct_archive, &char) i32
fn C.archive_write_open_fd(&C.struct_archive, i32) i32
fn C.archive_write_open_FILE(&C.struct_archive, &C.FILE) i32

// Write filter functions
fn C.archive_write_add_filter_none(&C.struct_archive) i32
fn C.archive_write_add_filter_gzip(&C.struct_archive) i32
fn C.archive_write_add_filter_bzip2(&C.struct_archive) i32
fn C.archive_write_add_filter_zstd(&C.struct_archive) i32
fn C.archive_write_add_filter_xz(&C.struct_archive) i32
fn C.archive_write_add_filter_lz4(&C.struct_archive) i32
fn C.archive_write_add_filter_lzma(&C.struct_archive) i32
fn C.archive_write_add_filter_lzip(&C.struct_archive) i32
fn C.archive_write_add_filter_lzop(&C.struct_archive) i32
fn C.archive_write_add_filter_compress(&C.struct_archive) i32
fn C.archive_write_add_filter_grzip(&C.struct_archive) i32
fn C.archive_write_add_filter_lrzip(&C.struct_archive) i32
fn C.archive_write_add_filter_b64encode(&C.struct_archive) i32
fn C.archive_write_add_filter_uuencode(&C.struct_archive) i32

// Write format functions
fn C.archive_write_set_format(&C.struct_archive, i32) i32
fn C.archive_write_set_format_by_name(&C.struct_archive, &char) i32
fn C.archive_write_set_format_7zip(&C.struct_archive) i32
fn C.archive_write_set_format_ar_bsd(&C.struct_archive) i32
fn C.archive_write_set_format_ar_svr4(&C.struct_archive) i32
fn C.archive_write_set_format_cpio(&C.struct_archive) i32
fn C.archive_write_set_format_gnutar(&C.struct_archive) i32
fn C.archive_write_set_format_iso9660(&C.struct_archive) i32
fn C.archive_write_set_format_pax(&C.struct_archive) i32
fn C.archive_write_set_format_pax_restricted(&C.struct_archive) i32
fn C.archive_write_set_format_raw(&C.struct_archive) i32
fn C.archive_write_set_format_shar(&C.struct_archive) i32
fn C.archive_write_set_format_ustar(&C.struct_archive) i32
fn C.archive_write_set_format_v7tar(&C.struct_archive) i32
fn C.archive_write_set_format_warc(&C.struct_archive) i32
fn C.archive_write_set_format_xar(&C.struct_archive) i32
fn C.archive_write_set_format_zip(&C.struct_archive) i32

// Write header/data
fn C.archive_write_header(&C.struct_archive, &C.struct_archive_entry) i32
@[keep_args_alive]
fn C.archive_write_data(&C.struct_archive, voidptr, u64) i64

// Write block control
fn C.archive_write_set_bytes_per_block(&C.struct_archive, i32) i32
fn C.archive_write_get_bytes_per_block(&C.struct_archive) i32
fn C.archive_write_set_bytes_in_last_block(&C.struct_archive, i32) i32
fn C.archive_write_get_bytes_in_last_block(&C.struct_archive) i32

// Archive entry lifecycle
fn C.archive_entry_new() &C.struct_archive_entry
fn C.archive_entry_new2(&C.struct_archive) &C.struct_archive_entry
fn C.archive_entry_clone(&C.struct_archive_entry) &C.struct_archive_entry
fn C.archive_entry_clear(&C.struct_archive_entry) &C.struct_archive_entry
fn C.archive_entry_free(&C.struct_archive_entry)

// Archive entry getters
fn C.archive_entry_pathname(&C.struct_archive_entry) &char
fn C.archive_entry_pathname_utf8(&C.struct_archive_entry) &char
fn C.archive_entry_pathname_w(&C.struct_archive_entry) &C.wchar_t
fn C.archive_entry_hardlink(&C.struct_archive_entry) &char
fn C.archive_entry_symlink(&C.struct_archive_entry) &char
fn C.archive_entry_sourcepath(&C.struct_archive_entry) &char
fn C.archive_entry_size(&C.struct_archive_entry) i64
fn C.archive_entry_size_is_set(&C.struct_archive_entry) i32
fn C.archive_entry_filetype(&C.struct_archive_entry) u32
fn C.archive_entry_mode(&C.struct_archive_entry) u32
fn C.archive_entry_perm(&C.struct_archive_entry) u32
fn C.archive_entry_uid(&C.struct_archive_entry) i64
fn C.archive_entry_gid(&C.struct_archive_entry) i64
fn C.archive_entry_uname(&C.struct_archive_entry) &char
fn C.archive_entry_gname(&C.struct_archive_entry) &char
fn C.archive_entry_mtime(&C.struct_archive_entry) i64
fn C.archive_entry_mtime_nsec(&C.struct_archive_entry) i64
fn C.archive_entry_atime(&C.struct_archive_entry) i64
fn C.archive_entry_atime_nsec(&C.struct_archive_entry) i64
fn C.archive_entry_ctime(&C.struct_archive_entry) i64
fn C.archive_entry_ctime_nsec(&C.struct_archive_entry) i64
fn C.archive_entry_birthtime(&C.struct_archive_entry) i64
fn C.archive_entry_birthtime_nsec(&C.struct_archive_entry) i64
fn C.archive_entry_nlink(&C.struct_archive_entry) u32
fn C.archive_entry_dev(&C.struct_archive_entry) u64
fn C.archive_entry_devmajor(&C.struct_archive_entry) u64
fn C.archive_entry_devminor(&C.struct_archive_entry) u64
fn C.archive_entry_ino(&C.struct_archive_entry) u64
fn C.archive_entry_ino64(&C.struct_archive_entry) u64
fn C.archive_entry_strmode(&C.struct_archive_entry) &char

// Archive entry setters
fn C.archive_entry_set_pathname(&C.struct_archive_entry, &char)
fn C.archive_entry_copy_pathname(&C.struct_archive_entry, &char)
fn C.archive_entry_set_size(&C.struct_archive_entry, i64)
fn C.archive_entry_unset_size(&C.struct_archive_entry)
fn C.archive_entry_set_filetype(&C.struct_archive_entry, u32)
fn C.archive_entry_set_mode(&C.struct_archive_entry, u32)
fn C.archive_entry_set_perm(&C.struct_archive_entry, u32)
fn C.archive_entry_set_uid(&C.struct_archive_entry, i64)
fn C.archive_entry_set_gid(&C.struct_archive_entry, i64)
fn C.archive_entry_set_uname(&C.struct_archive_entry, &char)
fn C.archive_entry_set_gname(&C.struct_archive_entry, &char)
fn C.archive_entry_set_mtime(&C.struct_archive_entry, i64, i64)
fn C.archive_entry_set_atime(&C.struct_archive_entry, i64, i64)
fn C.archive_entry_set_ctime(&C.struct_archive_entry, i64, i64)
fn C.archive_entry_set_birthtime(&C.struct_archive_entry, i64, i64)
fn C.archive_entry_set_symlink(&C.struct_archive_entry, &char)
fn C.archive_entry_set_hardlink(&C.struct_archive_entry, &char)
fn C.archive_entry_set_dev(&C.struct_archive_entry, u64)
fn C.archive_entry_set_devmajor(&C.struct_archive_entry, u64)
fn C.archive_entry_set_devminor(&C.struct_archive_entry, u64)
fn C.archive_entry_set_ino64(&C.struct_archive_entry, u64)
fn C.archive_entry_set_nlink(&C.struct_archive_entry, u32)

// Extract flags
pub const archive_extract_owner              = i32(0x0001)
pub const archive_extract_perm               = i32(0x0002)
pub const archive_extract_time               = i32(0x0004)
pub const archive_extract_no_overwrite       = i32(0x0008)
pub const archive_extract_unlink             = i32(0x0010)
pub const archive_extract_acl                = i32(0x0020)
pub const archive_extract_fflags             = i32(0x0040)
pub const archive_extract_xattr              = i32(0x0080)
pub const archive_extract_secure_symlinks    = i32(0x0100)
pub const archive_extract_secure_nodotdot    = i32(0x0200)
pub const archive_extract_no_autodir         = i32(0x0400)
pub const archive_extract_no_overwrite_newer = i32(0x0800)
pub const archive_extract_sparse             = i32(0x1000)
pub const archive_extract_secure_noabsolutepaths = i32(0x10000)
pub const archive_extract_safe_writes        = i32(0x40000)

// Extract functions
fn C.archive_read_extract(&C.struct_archive, &C.struct_archive_entry, i32) i32
fn C.archive_read_extract2(&C.struct_archive, &C.struct_archive_entry, &C.struct_archive) i32
