module hooks

// Trigger matching regressions, taken from the hooks Arch packages actually
// ship.  The three that matter for a root built by ace:
//
//   * 60-depmod.hook            — creates modules.dep, without which
//                                 mkinitcpio resolves no kernel modules
//   * 90-mkinitcpio-install.hook — creates /boot/vmlinuz-linux and the
//                                 initramfs
//   * 11-glibc-ldconfig.hook     — creates the root's /etc/ld.so.cache
//
// Paths carry the shape they have in the database: directories end in '/'.

fn test_depmod_trigger_fires_for_a_new_kernel_directory() {
	// [Trigger] Target = usr/lib/modules/*/ ; Target = !usr/lib/modules/*/?*
	targets := ['usr/lib/modules/*/', '!usr/lib/modules/*/?*']
	assert match_path_targets(targets, 'usr/lib/modules/7.2.8-arch1-2/')
}

fn test_depmod_trigger_ignores_files_inside_an_existing_directory() {
	// The negated target must win for a path that matches it.
	targets := ['usr/lib/modules/*/', '!usr/lib/modules/*/?*']
	assert !match_path_targets(targets, 'usr/lib/modules/7.2.8-arch1-2/vmlinuz')
}

fn test_negated_targets_do_not_behave_like_literals() {
	// The old matcher compared "!usr/..." as a literal pattern, which matched
	// nothing and — more importantly — never excluded anything either.
	assert !match_path_targets(['!usr/lib/modules/*/?*'], 'usr/lib/modules/7.2.8-arch1-2/')
	assert match_path_targets(['usr/lib/modules/7.2.8-arch1-2/'],
		'usr/lib/modules/7.2.8-arch1-2/')
}

fn test_mkinitcpio_kernel_trigger() {
	targets := ['usr/lib/modules/*/vmlinuz']
	assert match_path_targets(targets, 'usr/lib/modules/7.2.8-arch1-2/vmlinuz')
	assert !match_path_targets(targets, 'usr/lib/modules/7.2.8-arch1-2/')
}

fn test_mkinitcpio_initcpio_trigger() {
	// Target = usr/lib/initcpio/*
	assert match_path_targets(['usr/lib/initcpio/*'], 'usr/lib/initcpio/README')
	// Wildcards do not cross '/' (FNM_PATHNAME), so a nested file is not a
	// match for a one-level glob.
	assert !match_path_targets(['usr/lib/initcpio/*'], 'usr/lib/initcpio/install/filesystems')
	// The directory entry itself is a one-level path and does match.
	assert match_path_targets(['usr/lib/initcpio/*'], 'usr/lib/initcpio/install')
}

fn test_literal_directory_target_covers_its_contents() {
	// Hooks written as "Target = usr/share/foo/" keep working even when the
	// package's file list does not carry the parent directory.
	assert match_path_targets(['usr/share/foo/'], 'usr/share/foo/bar/baz.conf')
	assert !match_path_targets(['usr/share/foo/'], 'usr/share/foobar/baz.conf')
}

fn test_leading_slash_is_ignored_on_both_sides() {
	assert match_path_targets(['/usr/lib/modules/*/vmlinuz'],
		'/usr/lib/modules/7.2.8-arch1-2/vmlinuz')
}

fn test_package_trigger_with_negation() {
	targets := ['linux', '!linux-firmware']
	assert match_pkg_targets(targets, 'linux')
	assert !match_pkg_targets(targets, 'linux-firmware')
	assert !match_pkg_targets(['!linux'], 'linux')
}

fn test_package_trigger_globs() {
	assert match_pkg_targets(['glibc'], 'glibc')
	assert !match_pkg_targets(['glibc'], 'glibc-locales')
	assert match_pkg_targets(['mkinitcpio-*'], 'mkinitcpio-busybox')
}
