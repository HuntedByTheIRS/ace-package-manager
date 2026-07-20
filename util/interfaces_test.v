module util

// Verify that Handle is constructable with literal syntax.
fn test_handle_can_be_constructed() {
	h := Handle{
		root:               '/'
		dbpath:             '/var/lib/ace/'
		cachedirs:          ['/var/cache/ace/pkg/']
		logfile:            '/var/log/ace.log'
		gpgdir:             '/etc/ace/gpg/'
		hookedirs:          ['/etc/ace/hooks/']
		architectures:      ['x86_64', 'aarch64']
		siglevel:           1
		parallel_downloads: 5
		lockfile_path:      '/var/lib/ace/lock'
		no_confirm:         false
		checkspace:         false
	}
	assert h.root == '/'
	assert h.dbpath == '/var/lib/ace/'
	assert h.cachedirs.len == 1
	assert h.cachedirs[0] == '/var/cache/ace/pkg/'
	assert h.logfile == '/var/log/ace.log'
	assert h.gpgdir == '/etc/ace/gpg/'
	assert h.hookedirs.len == 1
	assert h.hookedirs[0] == '/etc/ace/hooks/'
	assert h.architectures.len == 2
	assert h.architectures[0] == 'x86_64'
	assert h.parallel_downloads == 5
	assert h.lockfile_path == '/var/lib/ace/lock'
	assert h.no_confirm == false
	assert h.checkspace == false
}

// Verify that resolved path methods work correctly.
fn test_handle_resolved_paths() {
	h := Handle{
		root:               '/mnt/ace'
		dbpath:             'var/lib/ace/'
		cachedirs:          ['var/cache/ace/pkg/']
		gpgdir:             'etc/ace/gpg/'
		hookedirs:          ['etc/ace/hooks/']
		parallel_downloads: 1
	}
	assert h.resolved_dbpath() == '/mnt/ace/var/lib/ace/'
	assert h.resolved_cachedirs().len == 1
	assert h.resolved_cachedirs()[0] == '/mnt/ace/var/cache/ace/pkg/'
	assert h.resolved_gpgdir() == '/mnt/ace/etc/ace/gpg/'
	assert h.resolved_hookedirs().len == 1
	assert h.resolved_hookedirs()[0] == '/mnt/ace/etc/ace/hooks/'
}

// Verify that handle with empty root still produces sensible paths.
fn test_handle_empty_root() {
	h := Handle{
		root:               ''
		dbpath:             '/var/lib/ace/'
		parallel_downloads: 1
	}
	// os.join_path('', '/var/lib/ace/') normalises away the leading slash.
	assert h.resolved_dbpath() == 'var/lib/ace/'
}

// Verify that callback types compile.
fn test_callback_types_compile() {
	_ := ProgressCallback(fn (percent int, message string) {
		_ := percent
		_ := message
	})

	// Event and Question are used via & references; just casting to the
	// function type verifies the type signature without referencing params.
	_ := EventCallback(fn (_ &Event) {})
	_ := QuestionCallback(fn (_ &Question) {})
}

// Verify that HookRunner interface is satisfiable.
fn test_hook_runner_interface() {
	runner := NoopHookRunner{}
	// Verify it satisfies HookRunner at compile time.
	_ := HookRunner(runner)
}

// NoopHookRunner is a minimal HookRunner implementation used for testing.
struct NoopHookRunner {}

pub fn (r NoopHookRunner) run_pre(pkgs []&Package) ! {
	_ := pkgs
}

pub fn (r NoopHookRunner) run_post(pkgs []&Package) ! {
	_ := pkgs
}

// Verify Package is constructable.
fn test_package_constructable() {
	pkg := Package{
		name:    'glibc'
		version: '2.35'
		release: '1'
		arch:    'x86_64'
	}
	assert pkg.name == 'glibc'
	assert pkg.version == '2.35'
	assert pkg.release == '1'
	assert pkg.arch == 'x86_64'
}
