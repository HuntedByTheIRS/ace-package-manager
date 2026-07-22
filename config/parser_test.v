module config

import os

const test_dir = '/tmp/ace_config_test'

fn setup() {
	os.rmdir_all(test_dir) or {}
	os.mkdir_all(test_dir, os.MkdirParams{
		mode: 0o755
	}) or {}
}

fn teardown() {
	os.rmdir_all(test_dir) or {}
}

fn write_cfg(path string, content string) {
	os.write_file(path, content) or { panic('failed to write ${path}: ${err}') }
}

// ---------------------------------------------------------------------------
// Empty / minimal configs
// ---------------------------------------------------------------------------

fn test_parse_empty_file() {
	setup()
	defer { teardown() }
	path := test_dir + '/empty.conf'
	write_cfg(path, '')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.rootdir == '/'
	assert cfg.dbpath == '/var/lib/ace/'
	assert cfg.repos.len == 0
	assert cfg.parallel_downloads == 7
}

fn test_parse_comments_only() {
	setup()
	defer { teardown() }
	path := test_dir + '/comments.conf'
	write_cfg(path, '# this is a comment\n# another comment\n   # indented comment\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.rootdir == '/'
}

fn test_parse_blank_lines() {
	setup()
	defer { teardown() }
	path := test_dir + '/blanks.conf'
	write_cfg(path, '\n\n  \n\t\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.rootdir == '/'
}

// ---------------------------------------------------------------------------
// Basic options
// ---------------------------------------------------------------------------

fn test_parse_rootdir() {
	setup()
	defer { teardown() }
	path := test_dir + '/rootdir.conf'
	write_cfg(path, '[options]\nRootDir = /custom/root\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.rootdir == '/custom/root'
}

fn test_parse_dbpath() {
	setup()
	defer { teardown() }
	path := test_dir + '/dbpath.conf'
	write_cfg(path, '[options]\nDBPath = /custom/db\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.dbpath == '/custom/db'
}

fn test_parse_cachedir_multiple() {
	setup()
	defer { teardown() }
	path := test_dir + '/cachedir.conf'
	write_cfg(path, '[options]\nCacheDir = /cache/one\nCacheDir = /cache/two\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.cachedirs.len == 2
	assert cfg.cachedirs[0] == '/cache/one'
	assert cfg.cachedirs[1] == '/cache/two'
}

fn test_parse_architecture() {
	setup()
	defer { teardown() }
	path := test_dir + '/arch.conf'
	write_cfg(path, '[options]\nArchitecture = x86_64\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.architectures.len == 1
	assert cfg.architectures[0] == 'x86_64'
}

fn test_parse_parallel_downloads() {
	setup()
	defer { teardown() }
	path := test_dir + '/parallel.conf'
	write_cfg(path, '[options]\nParallelDownloads = 5\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.parallel_downloads == 5
}

fn test_parse_parallel_downloads_clamped() {
	setup()
	defer { teardown() }
	path := test_dir + '/parallel_clamp.conf'
	write_cfg(path, '[options]\nParallelDownloads = 0\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.parallel_downloads == 1
}

// ---------------------------------------------------------------------------
// Boolean options
// ---------------------------------------------------------------------------

fn test_parse_boolean_bare_key() {
	setup()
	defer { teardown() }
	path := test_dir + '/bool_bare.conf'
	write_cfg(path, '[options]\nVerbosePkgLists\nNoProgressBar\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.verbosepkglists == true
	assert cfg.noprogressbar == true
}

fn test_parse_boolean_with_value() {
	setup()
	defer { teardown() }
	path := test_dir + '/bool_val.conf'
	write_cfg(path, '[options]\nCheckSpace = 1\nUseSyslog = true\nDisableDownloadTimeout = yes\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.checkspace == true
	assert cfg.usesyslog == true
	assert cfg.disabledl_timeout == true
}

// ---------------------------------------------------------------------------
// SigLevel parsing
// ---------------------------------------------------------------------------

fn test_parse_siglevel_required() {
	setup()
	defer { teardown() }
	path := test_dir + '/siglevel_req.conf'
	write_cfg(path, '[options]\nSigLevel = Required\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert int(cfg.siglevel) & int(SigLevel.required) != 0
}

fn test_parse_siglevel_multitoken() {
	setup()
	defer { teardown() }
	path := test_dir + '/siglevel_multi.conf'
	write_cfg(path, '[options]\nSigLevel = Required DatabaseOptional TrustAll\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert int(cfg.siglevel) & int(SigLevel.required) != 0
	assert int(cfg.siglevel) & int(SigLevel.database_optional) != 0
	assert int(cfg.siglevel) & int(SigLevel.marginal_ok) != 0
	assert int(cfg.siglevel) & int(SigLevel.unknown_ok) != 0
}

fn test_parse_siglevel_never() {
	setup()
	defer { teardown() }
	path := test_dir + '/siglevel_never.conf'
	write_cfg(path, '[options]\nSigLevel = Never\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.siglevel == SigLevel.never
}

fn test_parse_siglevel_never_overrides() {
	setup()
	defer { teardown() }
	path := test_dir + '/siglevel_never_override.conf'
	write_cfg(path, '[options]\nSigLevel = Never Required TrustAll\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	// Never overrides everything.
	assert cfg.siglevel == SigLevel.never
}

fn test_parse_siglevel_all_tokens() {
	setup()
	defer { teardown() }
	path := test_dir + '/siglevel_all.conf'
	write_cfg(path, '[options]\nSigLevel = Optional TrustedOnly MarginalOk UnknownOk DatabaseOptional DatabaseRequired\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert int(cfg.siglevel) & int(SigLevel.optional) != 0
	assert int(cfg.siglevel) & int(SigLevel.trusted_only) != 0
	assert int(cfg.siglevel) & int(SigLevel.marginal_ok) != 0
	assert int(cfg.siglevel) & int(SigLevel.unknown_ok) != 0
	assert int(cfg.siglevel) & int(SigLevel.database_optional) != 0
	assert int(cfg.siglevel) & int(SigLevel.database_required) != 0
}

fn test_parse_local_remote_siglevel() {
	setup()
	defer { teardown() }
	path := test_dir + '/local_remote_sig.conf'
	write_cfg(path, '[options]\nLocalFileSigLevel = Optional\nRemoteFileSigLevel = Required\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert int(cfg.local_file_siglevel) & int(SigLevel.optional) != 0
	assert int(cfg.local_file_siglevel) & int(SigLevel.required) == 0
	assert int(cfg.remote_file_siglevel) & int(SigLevel.required) != 0
	assert int(cfg.remote_file_siglevel) & int(SigLevel.optional) == 0
}

// ---------------------------------------------------------------------------
// Repo sections
// ---------------------------------------------------------------------------

fn test_parse_single_repo() {
	setup()
	defer { teardown() }
	path := test_dir + '/single_repo.conf'
	write_cfg(path, '[options]\n\n[core]\nServer = http://mirror.example.com/\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.repos.len == 1
	assert cfg.repos[0].name == 'core'
	assert cfg.repos[0].servers.len == 1
	assert cfg.repos[0].servers[0] == 'http://mirror.example.com/'
}

fn test_parse_multi_repo() {
	setup()
	defer { teardown() }
	path := test_dir + '/multi_repo.conf'
	write_cfg(path, '[options]\n\n[core]\nServer = http://core.example.com/\n\n[extra]\nServer = http://extra.example.com/\n\n[community]\nServer = http://community.example.com/\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.repos.len == 3
	assert cfg.repos[0].name == 'core'
	assert cfg.repos[1].name == 'extra'
	assert cfg.repos[2].name == 'community'
	assert cfg.repos[0].servers[0] == 'http://core.example.com/'
	assert cfg.repos[1].servers[0] == 'http://extra.example.com/'
}

fn test_parse_repo_multiple_servers() {
	setup()
	defer { teardown() }
	path := test_dir + '/repo_multi_server.conf'
	write_cfg(path, '[core]\nServer = http://mirror1.example.com/\nServer = http://mirror2.example.com/\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.repos[0].servers.len == 2
	assert cfg.repos[0].servers[0] == 'http://mirror1.example.com/'
	assert cfg.repos[0].servers[1] == 'http://mirror2.example.com/'
}

fn test_parse_repo_siglevel() {
	setup()
	defer { teardown() }
	path := test_dir + '/repo_siglevel.conf'
	write_cfg(path, '[core]\nSigLevel = Optional\nServer = http://example.com/\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert int(cfg.repos[0].siglevel) & int(SigLevel.optional) != 0
}

fn test_parse_repo_usage() {
	setup()
	defer { teardown() }
	path := test_dir + '/repo_usage.conf'
	write_cfg(path, '[custom]\nUsage = Sync\nServer = http://example.com/\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.repos[0].usage == .sync
}

// ---------------------------------------------------------------------------
// Include directive
// ---------------------------------------------------------------------------

fn test_parse_include() {
	setup()
	defer { teardown() }
	mirrorlist := test_dir + '/mirrorlist'
	write_cfg(mirrorlist, 'Server = http://mirror.example.com/\$repo/os/\$arch\n')
	
	cfg_path := test_dir + '/include_test.conf'
	write_cfg(cfg_path, '[core]\nInclude = ' + mirrorlist + '\n')
	cfg := parse_ini(cfg_path) or { panic('parse failed: ${err}') }
	assert cfg.repos.len == 1
	assert cfg.repos[0].name == 'core'
	assert cfg.repos[0].includes.len == 1
	assert cfg.repos[0].includes[0] == mirrorlist
	assert cfg.repos[0].servers.len >= 1
	assert cfg.repos[0].servers[0].contains('mirror.example.com')
	assert cfg.repos[0].servers[0].contains('/core/os/') // $repo substituted
}

fn test_parse_nested_include() {
	setup()
	defer { teardown() }
	level2 := test_dir + '/level2.conf'
	write_cfg(level2, 'Server = http://nested.example.com/\$repo/\$arch\n')
	
	level1 := test_dir + '/level1.conf'
	write_cfg(level1, 'Include = ' + level2 + '\n')
	
	cfg_path := test_dir + '/nested_include.conf'
	write_cfg(cfg_path, '[test]\nInclude = ' + level1 + '\n')
	cfg := parse_ini(cfg_path) or { panic('parse failed: ${err}') }
	assert cfg.repos[0].name == 'test'
	// Both the intermediate (level1) and leaf (level2) are recorded.
	assert cfg.repos[0].includes.len == 2
	assert cfg.repos[0].includes[0] == level2 || cfg.repos[0].includes[1] == level2
	assert cfg.repos[0].servers.len >= 1
	assert cfg.repos[0].servers[0].contains('nested.example.com')
}

fn test_parse_include_with_inline_server() {
	setup()
	defer { teardown() }
	mirrorlist := test_dir + '/mirrorlist2'
	write_cfg(mirrorlist, 'Server = http://included.example.com/\$repo/os/\$arch\n')
	
	cfg_path := test_dir + '/mixed_include.conf'
	write_cfg(cfg_path, '[core]\nInclude = ' + mirrorlist + '\nServer = http://inline.example.com/\$repo/os/\$arch\n')
	cfg := parse_ini(cfg_path) or { panic('parse failed: ${err}') }
	assert cfg.repos[0].servers.len == 2
	assert cfg.repos[0].servers[0].contains('included.example.com')
	assert cfg.repos[0].servers[1].contains('inline.example.com')
}

// ---------------------------------------------------------------------------
// Variable substitution
// ---------------------------------------------------------------------------

fn test_parse_repo_substitution() {
	setup()
	defer { teardown() }
	path := test_dir + '/repo_sub.conf'
	write_cfg(path, '[mytest]\nServer = http://example.com/\$repo/os/\$arch\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.repos[0].servers[0].contains('/mytest/os/') // $repo → mytest
}

fn test_parse_arch_substitution_auto() {
	setup()
	defer { teardown() }
	path := test_dir + '/arch_auto.conf'
	write_cfg(path, '[options]\nArchitecture = auto\n\n[core]\nServer = http://example.com/\$arch/\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	actual_arch := os.execute('uname -m').output.trim_space()
	assert cfg.repos[0].servers[0].contains('/' + actual_arch + '/')
}

fn test_parse_arch_substitution_explicit() {
	setup()
	defer { teardown() }
	path := test_dir + '/arch_explicit.conf'
	write_cfg(path, '[options]\nArchitecture = aarch64\n\n[core]\nServer = http://example.com/\$arch/\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.repos[0].servers[0].contains('/aarch64/')
}

// ---------------------------------------------------------------------------
// Full config
// ---------------------------------------------------------------------------

fn test_parse_full_config() {
	setup()
	defer { teardown() }
	mirrorlist := test_dir + '/mirrorlist'
	write_cfg(mirrorlist, 'Server = http://community.example.com/\$repo/os/\$arch\n')
	
	path := test_dir + '/full.conf'
	write_cfg(path, '# Ace configuration file
[options]
RootDir = /
DBPath = /var/lib/ace/
CacheDir = /var/cache/ace/
CacheDir = /extra/cache/
LogFile = /var/log/ace.log
GPGDir = /etc/ace/gnupg/
HookDir = /etc/ace/hooks/
HoldPkg = pacman glibc
Architecture = x86_64
IgnorePkg = linux
IgnoreGroup = kde
NoUpgrade = /etc/passwd
NoExtract = /etc/shadow
CheckSpace = 1
ParallelDownloads = 10
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
RemoteFileSigLevel = Required
CleanMethod = KeepCurrent
Color = Auto
VerbosePkgLists = 1
UseSyslog = true
NoProgressBar
DisableDownloadTimeout = yes

[core]
Server = http://mirror.example.com/\$repo/os/\$arch

[extra]
Server = http://extra.example.com/\$repo/os/\$arch
SigLevel = Optional

[community]
Include = ' + mirrorlist + '

[custom]
Server = http://custom.example.com/
Usage = Sync
')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }

	// Options
	assert cfg.rootdir == '/'
	assert cfg.dbpath == '/var/lib/ace/'
	assert cfg.cachedirs.len == 2
	assert cfg.logfile == '/var/log/ace.log'
	assert cfg.gpgdir == '/etc/ace/gnupg/'
	assert cfg.hookdirs.len == 1
	assert cfg.holdpkg.len == 2
	assert cfg.architectures.len == 1
	assert cfg.architectures[0] == 'x86_64'
	assert cfg.ignorepkgs.len == 1
	assert cfg.ignorepkgs[0] == 'linux'
	assert cfg.ignoregroups.len == 1
	assert cfg.ignoregroups[0] == 'kde'
	assert cfg.noupgrade.len == 1
	assert cfg.noextract.len == 1
	assert cfg.checkspace == true
	assert cfg.parallel_downloads == 10
	assert int(cfg.siglevel) & int(SigLevel.required) != 0
	assert int(cfg.siglevel) & int(SigLevel.database_optional) != 0
	assert int(cfg.local_file_siglevel) & int(SigLevel.optional) != 0
	assert int(cfg.remote_file_siglevel) & int(SigLevel.required) != 0
	assert cfg.cleanmethod == .keep_current
	assert cfg.color == .auto
	assert cfg.verbosepkglists == true
	assert cfg.usesyslog == true
	assert cfg.noprogressbar == true
	assert cfg.disabledl_timeout == true

	// Repos
	assert cfg.repos.len == 4
	assert cfg.repos[0].name == 'core'
	assert cfg.repos[0].servers.len == 1
	assert cfg.repos[0].servers[0].contains('mirror.example.com')
	assert cfg.repos[0].servers[0].contains('/core/os/')
	assert cfg.repos[1].name == 'extra'
	assert cfg.repos[1].siglevel != SigLevel.never
	assert cfg.repos[2].name == 'community'
	assert cfg.repos[2].includes.len == 1
	assert cfg.repos[2].servers.len >= 1
	assert cfg.repos[2].servers[0].contains('community.example.com')
	assert cfg.repos[3].name == 'custom'
	assert cfg.repos[3].usage == .sync
}

// ---------------------------------------------------------------------------
// Error handling
// ---------------------------------------------------------------------------

fn test_parse_nonexistent_file() {
	cfg := parse_ini('/tmp/ace_config_test/nonexistent.conf') or {
		// Expected error
		return
	}
	assert false // should not reach here
}

// ---------------------------------------------------------------------------
// Edge cases
// ---------------------------------------------------------------------------

fn test_parse_unknown_key_ignored() {
	setup()
	defer { teardown() }
	path := test_dir + '/unknown_key.conf'
	write_cfg(path, '[options]\nFooBar = baz\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.rootdir == '/' // unchanged
	assert cfg.repos.len == 0
}

fn test_parse_repo_unknown_key_ignored() {
	setup()
	defer { teardown() }
	path := test_dir + '/repo_unknown.conf'
	write_cfg(path, '[myrepo]\nFooBar = baz\nServer = http://example.com/\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.repos[0].servers.len == 1
	assert cfg.repos[0].servers[0] == 'http://example.com/'
}

fn test_parse_options_before_section() {
	setup()
	defer { teardown() }
	path := test_dir + '/options_first.conf'
	write_cfg(path, '# implicit [options] is NOT assumed — options only apply after [options]\nRootDir = /should/be/ignored\n\n[options]\nRootDir = /actual/root\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	// The first RootDir is before [options] so it's ignored (no active section)
	assert cfg.rootdir == '/actual/root'
}

fn test_parse_section_with_whitespace() {
	setup()
	defer { teardown() }
	path := test_dir + '/section_ws.conf'
	write_cfg(path, "[options]\n\n[ myrepo ]\nServer = http://example.com/\n")
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.repos[0].name == 'myrepo'
}

fn test_parse_cleanmethod_keep_installed() {
	setup()
	defer { teardown() }
	path := test_dir + '/cleanmethod.conf'
	write_cfg(path, '[options]\nCleanMethod = KeepInstalled\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.cleanmethod == .keep_installed
}

fn test_parse_color_never() {
	setup()
	defer { teardown() }
	path := test_dir + '/color.conf'
	write_cfg(path, '[options]\nColor = Never\n')
	cfg := parse_ini(path) or { panic('parse failed: ${err}') }
	assert cfg.color == .never
}
