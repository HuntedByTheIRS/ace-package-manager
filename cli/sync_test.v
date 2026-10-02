module cli

import util

// The download phase and the install phase must resolve the package cache to
// the same directory.  They used to diverge — the install phase joined the
// configured cachedir against cfg.rootdir instead of the transaction root —
// so a --root install downloaded every package into <root>/var/cache/ace/pkg
// and then re-fetched it from the host cache (failing outright when that
// cache was not writable by the invoking user).
fn test_resolve_cachedir_is_rooted_and_shared() {
	handle := &util.Handle{
		root:      './acelib'
		cachedirs: ['/var/cache/ace/pkg/']
	}
	assert resolve_cachedir(handle, './acelib') == './acelib/var/cache/ace/pkg/'
	// The same value the cache helpers derive from the handle: one source of
	// truth for "where are this transaction's archives".
	assert resolve_cachedir(handle, './acelib') == handle.resolved_cachedirs()[0]
}

fn test_resolve_cachedir_installing_to_host_root() {
	handle := &util.Handle{
		root:      '/'
		cachedirs: ['/var/cache/ace/pkg/']
	}
	assert resolve_cachedir(handle, '/') == '/var/cache/ace/pkg/'
}

fn test_resolve_cachedir_explicit_relative_and_empty() {
	explicit := &util.Handle{
		root:      './r'
		cachedirs: ['var/cache/ace/pkg']
	}
	assert resolve_cachedir(explicit, './r') == './r/var/cache/ace/pkg'

	empty := &util.Handle{
		root: './r'
	}
	assert resolve_cachedir(empty, './r') == './r/var/cache/ace/pkg'
}
