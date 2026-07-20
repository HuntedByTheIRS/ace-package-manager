module download

import util

// ---------------------------------------------------------------------------
// lookup_user tests
// ---------------------------------------------------------------------------

fn test_lookup_user_root() {
	// root should always exist in /etc/passwd
	pw := lookup_user('root') or {
		assert false, 'expected to find root: ${err.msg()}'; return
	}
	assert pw.uid == 0
	assert pw.gid == 0
}

fn test_lookup_user_nonexistent() {
	lookup_user('thisuserdoesnotexist_ace_test') or {
		return // expected
	}
	assert false, 'expected error for nonexistent user'
}

// ---------------------------------------------------------------------------
// use_sandbox tests
// ---------------------------------------------------------------------------

fn test_use_sandbox_disabled() {
	cfg := SandboxConfig{
		disable_sandbox: true
		download_user:   'nobody'
	}
	assert !use_sandbox(cfg)
}

fn test_use_sandbox_no_user() {
	cfg := SandboxConfig{
		download_user: ''
	}
	assert !use_sandbox(cfg)
}

fn test_use_sandbox_enabled() {
	cfg := SandboxConfig{
		download_user: 'nobody'
	}
	// use_sandbox requires root; in test environment we are non-root.
	assert !use_sandbox(cfg)
}

fn test_sandbox_config_from_handle() {
	mut handle := util_handle()
	handle.disable_sandbox = true
	handle.download_user = 'nobody'

	cfg := sandbox_config_from_handle(&handle)
	assert cfg.disable_sandbox == true
	assert cfg.download_user == 'nobody'
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn util_handle() util.Handle {
	return util.Handle{
		root:    '/'
		dbpath:  '/var/lib/ace/'
		gpgdir:  '/etc/ace/gnupg'
		cachedirs: ['/var/cache/ace/pkg/']
	}
}
