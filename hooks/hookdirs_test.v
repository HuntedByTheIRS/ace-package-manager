module hooks

import util

// Hook directories decide which hooks run at all.  Reading the host's
// directories for a rooted install left the new root with no /etc/ld.so.cache:
// its own hooks (glibc ships the ldconfig one in /usr/share/libalpm/hooks)
// were never walked.
fn test_hook_dirs_for_host_install_keeps_configured_dirs() {
	handle := &util.Handle{
		root:      '/'
		hookedirs: ['/etc/ace/hooks/']
	}
	assert hook_dirs_for(handle) == ['/etc/ace/hooks/']
}

fn test_hook_dirs_for_rooted_install_resolves_inside_the_root() {
	handle := &util.Handle{
		root:      '/mnt/newroot'
		hookedirs: ['/etc/ace/hooks/']
	}
	dirs := hook_dirs_for(handle)
	// ace's own directory first — the walk is reversed, so the first entry
	// has the highest priority.
	assert dirs[0] == '/mnt/newroot/etc/ace/hooks/'
	// Then the directories Arch packages ship hooks in.
	assert '/mnt/newroot/usr/share/libalpm/hooks/' in dirs
	assert '/mnt/newroot/etc/pacman.d/hooks/' in dirs
	// Never the host's directories.
	assert '/etc/ace/hooks/' !in dirs
}

fn test_hook_dirs_for_does_not_duplicate_configured_compat_dirs() {
	handle := &util.Handle{
		root:      '/mnt/r'
		hookedirs: ['/usr/share/libalpm/hooks/']
	}
	mut count := 0
	for d in hook_dirs_for(handle) {
		if d == '/mnt/r/usr/share/libalpm/hooks/' {
			count++
		}
	}
	assert count == 1
}
