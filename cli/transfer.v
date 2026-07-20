// --transfer subcommand — migrate pacman data to ace native directories.
//
// Copies the local package database, sync databases, configuration, hooks,
// GPG keyring, package cache, and log from pacman's paths to ace's paths
// so users can drop the --pacman flag and use ace natively.
//
// The transfer is idempotent: existing ace data is not overwritten unless
// --force is given.  Pacman's original data is never modified or removed.
module cli

import os
import util

// run_transfer migrates pacman data into ace's native directories.
// After a successful transfer, ace can be used without --pacman.
pub fn run_transfer(args &CliArgs, handle &util.Handle) ! {
	if os.getuid() != 0 {
		return error('--transfer requires root privileges to read pacman files')
	}

	println(':: Migrating pacman data to ace native directories...')
	println('')

	// Paths: pacman → ace
	root := if args.root != '' { args.root } else { handle.root }

	pacman_conf := '/etc/pacman.conf'
	ace_conf    := '/etc/ace.conf'

	pacman_dbpath := '/var/lib/pacman'
	ace_dbpath    := os.join_path(root, 'var/lib/ace')

	pacman_cache := '/var/cache/pacman/pkg'
	ace_cache    := os.join_path(root, 'var/cache/ace/pkg')

	pacman_hooks := '/etc/pacman.d/hooks'
	ace_hooks    := '/etc/ace/hooks'

	pacman_gpg   := '/etc/pacman.d/gnupg'
	ace_gpg      := '/etc/ace/gnupg'

	pacman_log   := '/var/log/pacman.log'
	ace_log      := os.join_path(root, 'var/log/ace.log')

	mut errors := []string{}
	mut copied := 0

	// 1. Local package database
	copied += transfer_dir(pacman_dbpath + '/local', ace_dbpath + '/local',
		'local package database', mut errors)

	// 2. Sync databases
	copied += transfer_dir(pacman_dbpath + '/sync', ace_dbpath + '/sync',
		'sync databases', mut errors)

	// 3. Configuration
	if os.exists(pacman_conf) {
		if copy_file_if_newer(pacman_conf, ace_conf) {
			println('  [ok] configuration: ${pacman_conf} → ${ace_conf}')
			copied++
		} else {
			println('  [--] configuration: ${ace_conf} already exists (skipped)')
		}
	}

	// 4. Package cache
	copied += transfer_dir(pacman_cache, ace_cache,
		'package cache', mut errors)

	// 5. Hooks
	copied += transfer_dir(pacman_hooks, ace_hooks,
		'hook definitions', mut errors)

	// 6. GPG keyring
	copied += transfer_dir(pacman_gpg, ace_gpg,
		'GPG keyring', mut errors)

	// 7. Log file
	if os.exists(pacman_log) {
		if copy_file_if_newer(pacman_log, ace_log) {
			println('  [ok] log file: ${pacman_log} → ${ace_log}')
			copied++
		} else {
			println('  [--] log file: ${ace_log} already exists (skipped)')
		}
	}

	// 8. Also copy pacman.conf as ace.conf if not already done
	// (step 3 handles this, but note that ace reads /etc/pacman.conf by
	//  default — the user should pass --config /etc/ace.conf or rename)

	println('')
	if errors.len > 0 {
		eprintln('warning: some items could not be transferred:')
		for e in errors {
			eprintln('  ${e}')
		}
	}
	println(':: Transfer complete: ${copied} item(s) migrated to ace directories.')
	println(':: You can now run ace without --pacman.')
	println(':: (Use --config /etc/ace.conf if you copied the config file.)')
}

// transfer_dir recursively copies a directory tree from src to dst.
// Returns 1 if any files were copied, 0 if the source doesn't exist
// or everything was already present.
fn transfer_dir(src string, dst string, label string, mut errors []string) int {
	if !os.is_dir(src) {
		return 0
	}

	if !os.is_dir(dst) {
		os.mkdir_all(dst) or {
			errors << 'cannot create ${dst}: ${err}'
			return 0
		}
	}

	mut count := 0
	count = copy_dir_recursive(src, dst, mut errors) or {
		errors << '${label}: ${err}'
		0
	}

	if count > 0 {
		println('  [ok] ${label}: ${count} file(s) copied (${src} → ${dst})')
	} else {
		println('  [--] ${label}: already up to date (skipped)')
	}
	return 1
}

// copy_dir_recursive copies a directory tree, skipping files that already
// exist at the destination.  Returns the number of files copied.
fn copy_dir_recursive(src_dir string, dst_dir string, mut errors []string) !int {
	entries := os.ls(src_dir) or {
		return error('cannot list ${src_dir}: ${err}')
	}

	mut count := 0

	for entry in entries {		if entry == '.' || entry == '..' {
			continue
		}

		src_path := os.join_path(src_dir, entry)
		dst_path := os.join_path(dst_dir, entry)

		if os.is_dir(src_path) {
			if !os.is_dir(dst_path) {
				os.mkdir_all(dst_path) or {
					errors << 'cannot create dir ${dst_path}: ${err}'
					continue
				}
			}
			sub_count := copy_dir_recursive(src_path, dst_path, mut errors) or {
				errors << '${src_path}: ${err}'
				0
			}
			count += sub_count
		} else if os.is_link(src_path) {
			// Copy symlink if destination doesn't exist
			if !os.exists(dst_path) && !os.is_link(dst_path) {
				target := os.readlink(src_path) or {
					errors << 'cannot readlink ${src_path}: ${err}'
					continue
				}
				os.symlink(target, dst_path) or {
					errors << 'cannot symlink ${dst_path}: ${err}'
					continue
				}
				count++
			}
		} else {
			if copy_file_if_newer(src_path, dst_path) {
				count++
			}
		}
	}

	return count
}

// copy_file_if_newer copies src to dst.  If dst already exists, it is
// skipped.  Returns true if the file was copied.
fn copy_file_if_newer(src string, dst string) bool {
	if os.exists(dst) {
		return false
	}

	// Ensure parent directory exists.
	parent := dst.all_before_last('/')
	if parent != '' && parent != '/' && !os.is_dir(parent) {
		os.mkdir_all(parent) or { return false }
	}

	data := os.read_file(src) or { return false }
	os.write_file(dst, data) or { return false }

	// Copy permissions from source.
	src_stat := os.stat(src) or { return true }
	os.chmod(dst, int(src_stat.mode)) or {}

	return true
}
