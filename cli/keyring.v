// --keyring-init / --keyring-populate — GPG keyring management.
//
// Mirrors pacman-key --init and pacman-key --populate for initializing
// and populating the GPG keyring used for package signature verification.
module cli

import os
import util

// run_keyring_init creates a new GPG keyring at the configured GPG directory.
pub fn run_keyring_init(handle &util.Handle) ! {
	gpgdir := if handle.gpgdir != '' { handle.gpgdir } else { '/etc/ace/gnupg' }

	if !os.exists(gpgdir) {
		os.mkdir_all(gpgdir) or {
			return error('cannot create GPG directory ${gpgdir}: ${err}')
		}
		os.chmod(gpgdir, 0o700) or {}
	}

	// Initialize the GPG keyring: create trust database and seed with
	// an empty keyring. Equivalent to `gpg --homedir <dir> --batch --gen-key`
	// with pacman's auto-generated master key.
	gpg_cmd := 'gpg --homedir ' + os.quoted_path(gpgdir) +
		' --batch --passphrase "" --quick-gen-key "ACE Keyring Master" rsa4096 sign never 2>/dev/null'
	result := os.execute(gpg_cmd)
	if result.exit_code != 0 {
		return error('failed to initialize keyring: ${result.output.trim_space()}')
	}

	println(':: Keyring initialized at ${gpgdir}')
}

// run_keyring_populate imports the given keyring package's trusted keys
// into the configured GPG directory.
pub fn run_keyring_populate(handle &util.Handle, keyring_name string) ! {
	gpgdir := if handle.gpgdir != '' { handle.gpgdir } else { '/etc/ace/gnupg' }

	if !os.is_dir(gpgdir) {
		return error('keyring not initialized — run --keyring-init first')
	}

	// Look for the keyring in the standard pacman keyring locations.
	keyring_paths := [
		'/usr/share/pacman/keyrings/${keyring_name}.gpg',
		'/usr/share/pacman/keyrings/${keyring_name}',
	]

	mut found := false
	for path in keyring_paths {
		if os.exists(path) {
			if os.is_dir(path) {
				// Directory of individual key files — import each.
				entries := os.ls(path) or {
					return error('cannot list keyring directory ${path}: ${err}')
				}
				for entry in entries {
					if entry.ends_with('.gpg') {
						import_key(gpgdir, os.join_path(path, entry)) or {
							return err
						}
					}
				}
			} else {
				// Single .gpg keyring file.
				import_key(gpgdir, path) or {
					return err
				}
			}
			found = true
			break
		}
	}

	if !found {
		return error('keyring "${keyring_name}" not found in /usr/share/pacman/keyrings/')
	}

	// After importing, refresh the trust database.
	trust_cmd := 'gpg --homedir ' + os.quoted_path(gpgdir) +
		' --batch --check-trustdb 2>/dev/null'
	os.execute(trust_cmd)

	println(':: Keyring populated with ${keyring_name}')
}

fn import_key(gpgdir string, path string) ! {
	cmd := 'gpg --homedir ' + os.quoted_path(gpgdir) +
		' --batch --import ' + os.quoted_path(path) + ' 2>/dev/null'
	result := os.execute(cmd)
	if result.exit_code != 0 {
		return error('failed to import key ${path}: ${result.output.trim_space()}')
	}
}
