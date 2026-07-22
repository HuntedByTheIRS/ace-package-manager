module config

import os

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

// SigLevel represents signature verification levels as a bitmask.
// Multiple tokens like "Required DatabaseOptional TrustAll" are OR'd together.
// Values are explicit powers of 2 for safe bitwise combination via int() conversions.
pub enum SigLevel {
	never = 0
	optional = 1
	required = 2
	trusted_only = 4
	marginal_ok = 8
	unknown_ok = 16
	database_optional = 32
	database_required = 64
}

// CleanMethod controls what packages are kept in the cache.
pub enum CleanMethod {
	keep_installed
	keep_current
}

// ColorWhen controls when colour output is used.
pub enum ColorWhen {
	auto
	never
	always
}

// RepoUsage controls what operations a repository can be used for.
pub enum RepoUsage {
	sync
	search
	install
	upgrade
	all
}

// Repo represents a single [repo-name] section in the configuration.
pub struct Repo {
pub mut:
	name     string
	servers  []string
	includes []string
	siglevel SigLevel
	usage    RepoUsage
}

// Config holds all parsed values from a pacman.conf-format INI file.
pub struct Config {
pub mut:
	rootdir                string      = '/'
	dbpath                 string      = '/var/lib/ace/'
	cachedirs              []string
	logfile                string
	gpgdir                 string
	hookdirs               []string
	holdpkg                []string
	architectures          []string
	ignorepkgs             []string
	ignoregroups           []string
	noupgrade              []string
	noextract              []string
	checkspace             bool
	parallel_downloads     int         = 7
	siglevel               SigLevel
	local_file_siglevel    SigLevel
	remote_file_siglevel   SigLevel
	cleanmethod            CleanMethod
	xfercommand            string
	color                  ColorWhen   = .auto
	verbosepkglists        bool
	usesyslog              bool
	noprogressbar          bool
	disabledl_timeout      bool
	disablesandbox         bool
	disablesandbox_fs      bool
	disablesandbox_sys     bool
	repos                  []Repo
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// parse_ini reads a pacman.conf-format INI file and returns a populated Config.
// This is a single-pass parser that handles [section] headers, Key = Value pairs,
// # comments, Include directives (recursive), variable substitution, and
// SigLevel multi-token bitmask parsing.
pub fn parse_ini(path string) !Config {
	mut cfg := Config{}
	// Preset defaults BEFORE parsing so explicit config-file values override them.
	cfg.siglevel = siglevel_or(.required, .database_optional)
	parse_file(path, mut cfg, '', -1)!

	// Apply defaults that depend on other values.
	if cfg.parallel_downloads < 1 {
		cfg.parallel_downloads = 1
	}
	if cfg.architectures.len == 0 {
		cfg.architectures = ['auto']
	}

	// Resolve "auto" architecture.
	if cfg.architectures.len > 0 && cfg.architectures[0] == 'auto' {
		detected := os.execute('uname -m')
		if detected.exit_code == 0 {
			cfg.architectures[0] = detected.output.trim_space()
		}
	}

	return cfg
}

// ---------------------------------------------------------------------------
// Internal recursive parser
// ---------------------------------------------------------------------------

// parse_file reads and processes a single config file, applying settings into
// `cfg`.  The `context_section` and `context_repo_idx` parameters let included
// files inherit the section/repo context from their parent.
fn parse_file(path string, mut cfg Config, context_section string, context_repo_idx int) ! {
	lines := os.read_lines(path)!

	mut section := context_section
	mut repo_idx := context_repo_idx

	for raw_line in lines {
		line := raw_line.trim_space()
		if line.len == 0 || line[0] == `#` {
			continue
		}

		// ---- [section header] ----
		if line[0] == `[` {
			close_bracket := line.last_index(']') or { -1 }
			if close_bracket == -1 {
				continue
			}
			section = line[1..close_bracket].trim_space()
			if section != 'options' {
				cfg.repos << Repo{
					name: section
				}
				repo_idx = cfg.repos.len - 1
			} else {
				repo_idx = -1
			}
			continue
		}

		// ---- Key = Value ----
		eq_pos := line.index('=') or { -1 }
		if eq_pos == -1 {
			// Bare key (boolean flag).
			if repo_idx == -1 {
				apply_config_bool(mut cfg, line, true)
			}
			continue
		}

		key := line[..eq_pos].trim_space()
		raw_val := line[eq_pos + 1..].trim_space()

		// Recursively handle Include (skip missing files silently).
		if key == 'Include' {
			if raw_val.len > 0 && os.exists(raw_val) {
				parse_file(raw_val, mut cfg, section, repo_idx) or {}
				if repo_idx >= 0 {
					cfg.repos[repo_idx].includes << raw_val
				}
			}
			continue
		}

		// Variable substitution.
		val := substitute_vars(raw_val, section, cfg)

		if repo_idx >= 0 {
			// Repo-specific keys.
			match key {
				'Server' {
					cfg.repos[repo_idx].servers << val
				}
				'SigLevel' {
					cfg.repos[repo_idx].siglevel = parse_siglevel(val)
				}
				'Usage' {
					cfg.repos[repo_idx].usage = parse_usage(raw_val)
				}
				else {}
			}
		} else {
			// [options] keys.
			apply_config_option(mut cfg, key, val)
		}
	}
}

// ---------------------------------------------------------------------------
// Option dispatchers
// ---------------------------------------------------------------------------

fn apply_config_option(mut cfg Config, key string, val string) {
	match key {
		'RootDir' {
			cfg.rootdir = val
		}
		'DBPath' {
			cfg.dbpath = val
		}
		'CacheDir' {
			cfg.cachedirs << val
		}
		'LogFile' {
			cfg.logfile = val
		}
		'GPGDir' {
			cfg.gpgdir = val
		}
		'HookDir' {
			cfg.hookdirs << val
		}
		'HoldPkg' {
			// Space-separated list.
			for item in val.split(' ') {
				t := item.trim_space()
				if t.len > 0 {
					cfg.holdpkg << t
				}
			}
		}
		'Architecture' {
			for item in val.split(' ') {
				t := item.trim_space()
				if t.len > 0 {
					cfg.architectures << t
				}
			}
		}
		'IgnorePkg' {
			for item in val.split(' ') {
				t := item.trim_space()
				if t.len > 0 {
					cfg.ignorepkgs << t
				}
			}
		}
		'IgnoreGroup' {
			for item in val.split(' ') {
				t := item.trim_space()
				if t.len > 0 {
					cfg.ignoregroups << t
				}
			}
		}
		'NoUpgrade' {
			for item in val.split(' ') {
				t := item.trim_space()
				if t.len > 0 {
					cfg.noupgrade << t
				}
			}
		}
		'NoExtract' {
			for item in val.split(' ') {
				t := item.trim_space()
				if t.len > 0 {
					cfg.noextract << t
				}
			}
		}
		'CheckSpace' {
			cfg.checkspace = parse_bool(val)
		}
		'ParallelDownloads' {
			cfg.parallel_downloads = val.int()
		}
		'SigLevel' {
			cfg.siglevel = parse_siglevel(val)
		}
		'LocalFileSigLevel' {
			cfg.local_file_siglevel = parse_siglevel(val)
		}
		'RemoteFileSigLevel' {
			cfg.remote_file_siglevel = parse_siglevel(val)
		}
		'CleanMethod' {
			cfg.cleanmethod = parse_cleanmethod(val)
		}
		'XferCommand' {
			cfg.xfercommand = val
		}
		'Color' {
			cfg.color = parse_color(val)
		}
		'VerbosePkgLists' {
			cfg.verbosepkglists = parse_bool(val)
		}
		'UseSyslog' {
			cfg.usesyslog = parse_bool(val)
		}
		'NoProgressBar' {
			cfg.noprogressbar = parse_bool(val)
		}
		'DisableDownloadTimeout' {
			cfg.disabledl_timeout = parse_bool(val)
		}
		'DisableSandbox' {
			cfg.disablesandbox = parse_bool(val)
		}
		'DisableSandboxFilesystem' {
			cfg.disablesandbox_fs = parse_bool(val)
		}
		'DisableSandboxSyscalls' {
			cfg.disablesandbox_sys = parse_bool(val)
		}
		'DownloadUser' {
			// DownloadUser sets the user to drop privileges to for downloading.
			// Example: DownloadUser = nobody
			// TODO: store download_user on Handle when implemented
		}
		else {}
	}
}

fn apply_config_bool(mut cfg Config, key string, _val bool) {
	match key {
		'CheckSpace' {
			cfg.checkspace = true
		}
		'VerbosePkgLists' {
			cfg.verbosepkglists = true
		}
		'UseSyslog' {
			cfg.usesyslog = true
		}
		'NoProgressBar' {
			cfg.noprogressbar = true
		}
		'DisableDownloadTimeout' {
			cfg.disabledl_timeout = true
		}
		'DisableSandbox' {
			cfg.disablesandbox = true
		}
		'DisableSandboxFilesystem' {
			cfg.disablesandbox_fs = true
		}
		'DisableSandboxSyscalls' {
			cfg.disablesandbox_sys = true
		}
		else {}
	}
}

// ---------------------------------------------------------------------------
// Value helpers
// ---------------------------------------------------------------------------

fn parse_bool(val string) bool {
	low := val.to_lower()
	return low == '1' || low == 'yes' || low == 'true' || low == 'on'
}

// siglevel_or bitwise-ORs two SigLevel values via a tiny unsafe cast.
fn siglevel_or(a SigLevel, b SigLevel) SigLevel {
	return unsafe { SigLevel(int(a) | int(b)) }
}

fn parse_siglevel(s string) SigLevel {
	tokens := s.trim_space().split(' ')
	// "Never" overrides everything.
	for t in tokens {
		if t == 'Never' {
			return SigLevel.never
		}
	}
	mut result := SigLevel.never
	for t in tokens {
		val := match t {
			'Optional' {
				SigLevel.optional
			}
			'Required' {
				SigLevel.required
			}
			'TrustedOnly' {
				SigLevel.trusted_only
			}
			'MarginalOk' {
				SigLevel.marginal_ok
			}
			'UnknownOk' {
				SigLevel.unknown_ok
			}
			'DatabaseOptional' {
				SigLevel.database_optional
			}
			'DatabaseRequired' {
				SigLevel.database_required
			}
			'DatabaseTrustedOnly' {
				SigLevel.trusted_only
			}
			'DatabaseMarginalOk' {
				SigLevel.marginal_ok
			}
			'DatabaseUnknownOk' {
				SigLevel.unknown_ok
			}
			'TrustAll' {
				siglevel_or(.marginal_ok, .unknown_ok)
			}
			else {
				SigLevel.never
			}
		}
		result = siglevel_or(result, val)
	}
	return result
}

fn parse_cleanmethod(s string) CleanMethod {
	return match s.trim_space() {
		'KeepInstalled' {
			.keep_installed
		}
		'KeepCurrent' {
			.keep_current
		}
		else {
			.keep_current
		}
	}
}

fn parse_color(s string) ColorWhen {
	return match s.trim_space() {
		'Auto' {
			.auto
		}
		'Never' {
			.never
		}
		'Always' {
			.always
		}
		else {
			.auto
		}
	}
}

fn parse_usage(s string) RepoUsage {
	return match s.trim_space() {
		'Sync' {
			.sync
		}
		'Search' {
			.search
		}
		'Install' {
			.install
		}
		'Upgrade' {
			.upgrade
		}
		'All' {
			.all
		}
		else {
			.all
		}
	}
}

// ---------------------------------------------------------------------------
// Variable substitution
// ---------------------------------------------------------------------------

fn substitute_vars(val string, section string, cfg Config) string {
	// $repo → current section/repo name
	mut result := val.replace('\$repo', section)

	// $arch → first configured architecture.
	// Resolve "auto" inline so substitution works even when "auto" appears
	// in the config before the $arch-using directive.
	if cfg.architectures.len > 0 {
		mut arch := cfg.architectures[0]
		if arch == 'auto' {
			detected := os.execute('uname -m')
			if detected.exit_code == 0 {
				arch = detected.output.trim_space()
			}
		}
		result = result.replace('\$arch', arch)
	} else {
		detected := os.execute('uname -m')
		if detected.exit_code == 0 {
			result = result.replace('\$arch', detected.output.trim_space())
		}
	}

	return result
}
