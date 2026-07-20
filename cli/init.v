// Centralized initialisation: load config, build Handle, apply CLI overrides.
//
// Reference: pacman/src/pacman/conf.c:setdefaults + parsearg_global at
//            pacman/src/pacman/pacman.c:382 and setup_libalpm():897
module cli

import config
import os
import util

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// InitResult bundles a parsed Config and the derived Handle after applying
// CLI overrides.  Callers should use handle for all library operations.
pub struct InitResult {
pub:
	cfg    config.Config
	handle util.Handle
}

// init_from_args loads the config file (--config or the default path),
// parses it, then builds a Handle with config values overridden by any
// CLI-provided values.
//
// Priority (matching pacman):
//   1. CLI / command-line flags
//   2. Config file
//   3. Compiled-in defaults
pub fn init_from_args(mut args CliArgs) !InitResult {
	// 0. Apply --pacman mode: override config defaults with pacman-compatible paths.
	//    Only sets fields that were NOT explicitly provided via CLI flags.
	if args.pacman_mode {
		if args.config == '' {
			args.config = '/etc/pacman.conf'
		}
		if args.root == '' {
			args.root = '/'
		}
		if args.dbpath == '' {
			args.dbpath = '/var/lib/pacman/'
		}
		if args.cachedirs.len == 0 {
			args.cachedirs = ['/var/cache/pacman/pkg/']
		}
		if args.gpgdir == '' {
			args.gpgdir = '/etc/pacman.d/gnupg/'
		}
		if args.logfile == '' {
			args.logfile = '/var/log/pacman.log'
		}
	}

	// 1. Determine config file path.
	cfg_path := if args.config != '' {
		args.config
	} else {
		'/etc/ace.conf'
	}

	// 2. Parse the configuration INI file.
	mut cfg := config.parse_ini(cfg_path) or {
		return error('cannot parse config file ${cfg_path}: ${err}')
	}

	// 3. Apply setdefaults logic (matching pacman's setdefaults in conf.c).
	//    When a rootdir is set and a path was not explicitly provided, derive
	//    dbpath, logfile, etc. from the rootdir.
	if args.root != '' || cfg.rootdir != '' {
		root := if args.root != '' { args.root } else { cfg.rootdir }
		// Strip trailing slash from root.
		mut root_trimmed := root.trim_right('/')
		if root_trimmed == '' {
			root_trimmed = '/'
		}
		// If dbpath not explicitly set from CLI nor config, derive from root.
		if args.dbpath == '' && cfg.dbpath == '' {
			cfg.dbpath = '/var/lib/ace/'
		}
		// If logfile not set, default to root-relative.
		if args.logfile == '' && cfg.logfile == '' {
			cfg.logfile = os.join_path(root_trimmed, 'var/log/ace.log')
		}
	}

	// 4. Build defaults for paths that may still be empty.
	if cfg.rootdir == '' {
		cfg.rootdir = '/'
	}
	if cfg.dbpath == '' {
		cfg.dbpath = '/var/lib/ace/'
	}
	if cfg.cachedirs.len == 0 {
		cfg.cachedirs = ['/var/cache/ace/pkg/']
	}
	if cfg.hookdirs.len == 0 {
		cfg.hookdirs = ['/etc/ace/hooks/']
	}
	if cfg.gpgdir == '' {
		cfg.gpgdir = '/etc/ace/gnupg/'
	}
	if cfg.logfile == '' {
		cfg.logfile = '/var/log/ace.log'
	}
	if cfg.architectures.len == 0 {
		cfg.architectures = ['auto']
	}

	// 5. Build Handle from config values, applying CLI overrides.
	//    Priority: CLI > config file > compiled-in defaults.
	rootdir_val := if args.root != '' { args.root } else { cfg.rootdir }
	dbpath_val := if args.dbpath != '' { args.dbpath } else { cfg.dbpath }
	cachedirs_val := if args.cachedirs.len > 0 { args.cachedirs.clone() } else { cfg.cachedirs.clone() }
	logfile_val := if args.logfile != '' { args.logfile } else { cfg.logfile }
	gpgdir_val := if args.gpgdir != '' { args.gpgdir } else { cfg.gpgdir }
	hookedirs_val := if args.hookdirs.len > 0 { args.hookdirs.clone() } else { cfg.hookdirs.clone() }
	arch_val := if args.arch.len > 0 { args.arch.clone() } else { cfg.architectures.clone() }
	noconfirm_val := args.noconfirm

	lockfile_path_val := os.join_path(rootdir_val, dbpath_val, 'ace.lock')

	mut handle := util.Handle{
		root:               rootdir_val
		dbpath:             dbpath_val
		cachedirs:          cachedirs_val
		logfile:            logfile_val
		gpgdir:             gpgdir_val
		hookedirs:          hookedirs_val
		architectures:      arch_val
		siglevel:           int(cfg.siglevel)
		parallel_downloads: cfg.parallel_downloads
		no_confirm:         noconfirm_val
		noprogressbar:      cfg.noprogressbar || args.debug > 0
		debug_level:        args.debug
		checkspace:         cfg.checkspace
		noextract:          cfg.noextract.clone()
		noupgrade:          cfg.noupgrade.clone()
		overwrite_files:    []string{}
		lockfile_path:      lockfile_path_val
	}

	return InitResult{
		cfg:    cfg
		handle: handle
	}
}
