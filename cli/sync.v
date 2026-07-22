// cli/sync.v — -S (sync) subcommand implementation.
//
// Handles all -S sub-operations matching pacman's sync.c:
//   -Sc/-Scc  clean package cache and unused sync databases
//   -Sy/-Syy  refresh repository package databases
//   -Ss       search sync databases for packages
//   -Sg/-Sgg  list package groups
//   -Si/-Sii  show package info from sync databases
//   -Sl       list packages in sync databases
//   -Su/-Suu  full system upgrade
//   targets   install specific packages from sync databases
//
// Reference: pacman/src/pacman/sync.c
module cli

import cache
import config
import db
import download
import hooks
import lock { LockFile }
import os
import regex
import time
import trans
import util

// ===========================================================================
//  Public entry point
// ===========================================================================

// run_sync executes the -S operation, dispatching to sub-operations based
// on the flags set in args.
// cfg and handle are pre-initialised (config loaded at startup).
pub fn run_sync(args &CliArgs, cfg &config.Config, handle &util.Handle) ! {
	// 1. Resolve paths
	mut dbpath := if args.dbpath != '' {
		args.dbpath
	} else if args.root != '' {
		os.join_path(args.root, 'var/lib/ace')
	} else {
		handle.resolved_dbpath()
	}

	// 3. Acquire database lock for operations that modify state.
	// Query operations (search, info, list, groups) and --print skip the lock.
	needs_lock := (args.sync_count > 0 || args.sync_clean > 0 || args.sync_upgrade > 0 ||
		args.download_only || args.targets.len > 0) &&
		!args.sync_search && args.sync_info == 0 && !args.sync_list && args.sync_group == 0 &&
		!args.print

	mut lf := LockFile{}
	if needs_lock {
		lf.acquire(dbpath) or {
			return error('cannot lock database at ${dbpath}: ${err}')
		}
		defer {
			lf.release()
		}
	}

	// 4. Ensure sync database directory exists.
	// When --pacman is used, use ACE's own sync directory to avoid
	// overwriting pacman's signature-verified sync databases.
	sync_dir := if args.pacman_mode {
		os.join_path('/var/lib/ace', 'sync')
	} else {
		os.join_path(dbpath, 'sync')
	}
	if !os.exists(sync_dir) {
		os.mkdir_all(sync_dir)!
	}

	// 5. Filter repositories that can be used for sync operations.
	mut sync_repos := filter_sync_repos(cfg)

	// 6. Handle clean first (matching pacman's dispatch order).
	if args.sync_clean > 0 {
		sync_clean(args.sync_clean, cfg, handle)!
		return
	}

	// 7. Refresh databases if -y is given.
	if args.sync_count > 0 {
		if sync_repos.len == 0 {
			return error('no sync repositories configured')
		}
		refresh_databases(args.sync_count, sync_repos, sync_dir)!
	}

	// 8. Load sync databases for operations that need them.
	need_data := args.sync_search || args.sync_info > 0 || args.sync_list ||
		args.sync_group > 0 || args.targets.len > 0 || args.sync_upgrade > 0

	mut syncdbs := []&db.Database{}
	if need_data {
		if sync_repos.len == 0 {
			return error('no sync repositories configured')
		}
		syncdbs = load_sync_dbs(sync_repos, sync_dir) or {
			return error('cannot load sync databases: ${err}')
		}
	}

	// 9. Dispatch sub-operations (matching pacman_sync order).
	if args.sync_search {
		return sync_search_dbs(syncdbs, args.targets, args.quiet)
	}

	if args.sync_group > 0 {
		return sync_group_list(syncdbs, args.sync_group, args.targets, args.quiet)
	}

	if args.sync_info > 0 {
		return sync_info_dbs(syncdbs, args.sync_info, args.targets, args.quiet)
	}

	if args.sync_list {
		return sync_list_dbs(syncdbs, args.targets, dbpath, args.quiet)
	}

	// 10. Install / upgrade.
	if args.targets.len > 0 || args.sync_upgrade > 0 {
		return sync_install_or_upgrade(args, syncdbs, cfg, dbpath)
	}

	// If only -y was given (databases refreshed), success.
	if args.sync_count > 0 {
		return
	}

	return error('no operation specified for sync (use -h for help)')
}

// ===========================================================================
//  Path / config helpers
// ===========================================================================

// filter_sync_repos returns repos that have sync or all usage and at least
// one server configured.
fn filter_sync_repos(cfg &config.Config) []config.Repo {
	mut result := []config.Repo{}
	for repo in cfg.repos {
		if repo.usage != .sync && repo.usage != .all {
			continue
		}
		if repo.servers.len == 0 {
			continue
		}
		result << repo
	}
	return result
}

// ===========================================================================
//  Database refresh (-Sy / -Syy)
// ===========================================================================

// refresh_databases downloads package databases for all configured repos
// in parallel, with colored progress bars and cache-aware skipping.
fn refresh_databases(sync_count int, repos []config.Repo, sync_dir string) ! {
	force := sync_count >= 2

	println(heading_str('Synchronizing package databases...'))

	// Build download payloads for repos that need fetching.
	// Skip repos whose .db file already exists unless forced (-Syy).
	mut db_payloads := []download.DownloadPayload{}
	mut db_repos := []config.Repo{}

	for repo in repos {
		treename := repo.name
		db_path := os.join_path(sync_dir, '${treename}.db')

		// Cache check: skip if DB exists and not forced.
		if !force && os.exists(db_path) {
			continue
		}

		need_db_sig := int(repo.siglevel) & (int(config.SigLevel.database_required) |
			int(config.SigLevel.database_optional)) != 0
		sig_optional := int(repo.siglevel) & int(config.SigLevel.database_optional) != 0

		// Use first server (parallel download doesn't iterate servers).
		if repo.servers.len == 0 {
			continue
		}
		resolved := repo.servers[0].replace('\$repo', treename)
		base := if resolved.ends_with('/') { resolved } else { resolved + '/' }
		url := '${base}${treename}.db'

		db_payloads << download.DownloadPayload{
			url:          url
			filename:     '${treename}.db'
			dest_path:    db_path
			force:        force
			sig_download: need_db_sig
			sig_optional: sig_optional
			allow_resume: false
			max_size:     128 * 1024 * 1024 // 128 MiB hard limit
		}
		db_repos << repo
	}

	if db_payloads.len == 0 {
		println('  all databases are up to date')
		return
	}

	// Download all DBs in parallel with progress bars.
	download_parallel_files(db_payloads, 7)

	// Write .lastupdate timestamps for successfully downloaded DBs.
	now := time.unix_now()
	for repo in db_repos {
		treename := repo.name
		os.write_file(os.join_path(sync_dir, '${treename}.lastupdate'), '${now}\n') or {
			eprintln(warn('cannot write .lastupdate for ${treename}: ${err}'))
		}
	}
}

// repo_sync downloads the database (and signature) for a single repository.
// Used by -Fy (files database refresh) with cache-aware skipping.
fn repo_sync(repo config.Repo, sync_dir string, force bool) ! {
	treename := repo.name
	db_path := os.join_path(sync_dir, '${treename}.db')

	// Cache: skip if DB file exists and not forced (matching refresh_databases).
	if !force && os.exists(db_path) {
		return
	}

	need_db_sig := int(repo.siglevel) & (int(config.SigLevel.database_required) |
		int(config.SigLevel.database_optional)) != 0
	sig_optional := int(repo.siglevel) & int(config.SigLevel.database_optional) != 0

	mut dl := download.Downloader{}
	dl.init('ace/0.1', 30000, fn (pct int, msg string) {
		if pct >= 0 {
			print('\r  ${progress_bar_str(pct, 30)}')
		}
	})

	mut last_db_err := error('no servers configured')

	for server_url in repo.servers {
		resolved := server_url.replace('\$repo', treename)
		base := if resolved.ends_with('/') { resolved } else { resolved + '/' }
		url := '${base}${treename}.db'

		print('  ${treename}: downloading ${treename}.db...\n')
		dl.download(download.DownloadPayload{
			url:            url
			filename:       '${treename}.db'
			dest_path:      db_path
			force:          force
			sig_download:   need_db_sig
			sig_optional:   sig_optional
			allow_resume:   false
			max_size:       128 * 1024 * 1024 // 128 MiB hard limit
		}) or {
			print('\r\033[K')
			println('  ${treename}: failed (${err.msg()})')
			last_db_err = err
			continue
		}
		print('\r\033[K  ${treename}: ${ok('done')}\n')

		// Log the successful sync timestamp.
		now := time.unix_now()
		os.write_file(os.join_path(sync_dir, '${treename}.lastupdate'), '${now}\n') or {
			eprintln(warn('cannot write .lastupdate for ${treename}: ${err}'))
		}
		return
	}

	return error('${treename}: all mirrors failed — ${last_db_err.msg()}')
}

// ===========================================================================
//  Load sync databases
// ===========================================================================

// DBResult is used by load_sync_dbs for channel-based result collection
// from parallel goroutines. Must be at module scope so V generates a
// single C type across all closures.
struct DBResult {
	database  &db.Database
	repo_name string
	err_msg   string
}

// load_sync_dbs loads all sync database files into Database structs.
// Each repo's .db.tar is parsed in a parallel goroutine since populate()
// operates on its own SyncDB/ArchiveReader instances with no shared state.
fn load_sync_dbs(repos []config.Repo, sync_dir string) ![]&db.Database {
	if repos.len == 0 {
		return []&db.Database{}
	}

	// Result type for channel-based collection from goroutines.
	result_ch := chan DBResult{cap: repos.len}

	for repo in repos {
		go fn [repo, sync_dir, result_ch]() {
			db_path := os.join_path(sync_dir, '${repo.name}.db')
			if !os.exists(db_path) {
				result_ch <- DBResult{
					database: unsafe { nil }
					repo_name: repo.name
					err_msg: '${repo.name}: database not found at ${db_path}'
				}
				return
			}

			mut sdb := db.new_sync_db()
			db.populate(mut sdb, db_path) or {
				result_ch <- DBResult{
					database: unsafe { nil }
					repo_name: repo.name
					err_msg: '${repo.name}: ${err.msg()}'
				}
				return
			}

			mut database := &db.Database{
				pkgcache: sdb.pkgcache
				name:     repo.name
				servers:  repo.servers
			}
			db.build_grpcache(mut database)

			result_ch <- DBResult{
				database:  database
				repo_name: repo.name
			}
		}()
	}

	// Collect results preserving insertion-agnostic ordering.
	mut result := []&db.Database{}
	mut errors := []string{}

	for _ in 0 .. repos.len {
		r := <-result_ch
		if r.err_msg != '' {
			errors << r.err_msg
		} else {
			result << r.database
		}
	}

	if result.len == 0 {
		return error('no databases could be loaded: ${errors.join("; ")}')
	}

	if errors.len > 0 {
		eprintln('warning: some databases failed to load: ${errors.join("; ")}')
	}

	return result
}

// ===========================================================================
//  Cache & DB cleaning (-Sc / -Scc)
// ===========================================================================

// sync_clean handles -Sc and -Scc: removes cached package files and unused
// sync database files from the sync directory.
//
// Refactored to delegate the core logic to cache.clean_cache.
//
// -Sc:  selective removal — respects CleanMethod (KeepInstalled / KeepCurrent)
// -Scc: removes ALL cached package files regardless of CleanMethod
fn sync_clean(level int, cfg &config.Config, handle &util.Handle) ! {
	// Detect piped/non-TTY stdin for confirmation prompts.
	stdin_tty := os.is_atty(0) != 0

	if level == 1 {
		// -Sc: Determine clean method from config.
		mut keep_installed := true
		mut keep_current := false
		match cfg.cleanmethod {
			.keep_installed {
				keep_installed = true
				keep_current = false
			}
			.keep_current {
				keep_installed = false
				keep_current = true
			}
		}

		// Prompt before selective cleaning.
		if !handle.no_confirm {
			if !stdin_tty {
				eprintln(warn('stdin is not a terminal; use --noconfirm to skip prompts'))
				return error('cannot confirm cache cleaning on non-interactive terminal')
			}
			print('Do you want to remove all other packages from cache? [Y/n] ')
			response := os.input('').trim_space().to_lower()
			if response != '' && response != 'y' && response != 'yes' {
				println('skipping cache cleaning')
				return
			}
		}

		cache.clean_cache(handle, keep_installed, keep_current)!
	} else {
		// -Scc: Remove ALL — unconditionally pass both flags as false.
		if !handle.no_confirm {
			if !stdin_tty {
				eprintln(warn('stdin is not a terminal; use --noconfirm to skip prompts'))
				return error('cannot confirm cache cleaning on non-interactive terminal')
			}
			print('Do you want to remove ALL files from cache? [y/N] ')
			response := os.input('').trim_space().to_lower()
			if response != 'y' && response != 'yes' {
				println('skipping cache cleaning')
				return
			}
		}

		cache.clean_cache(handle, false, false)!
	}
}

// ===========================================================================
//  Search (-Ss)
// ===========================================================================

// sync_search_dbs searches all sync databases for packages matching any
// target pattern (regex).  Matching is done on package name and description.
fn sync_search_dbs(syncdbs []&db.Database, targets []string, quiet bool) ! {
	if targets.len == 0 {
		return error('no search target specified')
	}

	// Compile all patterns.
	mut patterns := []regex.RE{}
	for target in targets {
		re := regex.regex_opt(target) or {
			return error('invalid regex pattern "${target}": ${err}')
		}
		patterns << re
	}

	for sdb in syncdbs {
		for _, pkg in sdb.pkgcache {
			mut matched := false
			for re in patterns {
				if re.matches_string(pkg.name) || re.matches_string(pkg.desc) {
					matched = true
					break
				}
			}
			if matched {
				if quiet {
					println('${sdb.name}/${pkg.name} ${pkg.version}')
				} else {
					println('${sdb.name}/${pkg.name} ${pkg.version}')
					if pkg.desc != '' {
						println('    ${pkg.desc}')
					}
				}
			}
		}
	}
}

// ===========================================================================
//  Groups (-Sg / -Sgg)
// ===========================================================================

// sync_group_list lists package groups from all sync databases.
// level=1: only group names.  level=2: group names with member packages.
// targets filters to specific groups.
fn sync_group_list(syncdbs []&db.Database, level int, targets []string, quiet bool) ! {
	if targets.len > 0 {
		for target in targets {
			mut found := false
			for sdb in syncdbs {
				if group := sdb.grpcache[target] {
					found = true
					if quiet {
						for pkgname in group.packages {
							println('${pkgname}')
						}
					} else if level > 1 {
						for pkgname in group.packages {
							println('${group.name} ${pkgname}')
						}
					} else {
						println('${group.name}')
					}
				}
			}
			if !found {
				eprintln('warning: group "${target}" was not found')
			}
		}
	} else {
		mut seen := map[string]bool{}
		for sdb in syncdbs {
			for gname, group in sdb.grpcache {
				if gname in seen {
					continue
				}
				seen[gname] = true
				if quiet {
					println('${gname}')
				} else if level > 1 {
					for pkgname in group.packages {
						println('${gname} ${pkgname}')
					}
				} else {
					println('${gname}')
				}
			}
		}
	}
}

// ===========================================================================
//  Info (-Si / -Sii)
// ===========================================================================

// sync_info_dbs shows detailed package info from sync databases.
// level=1: standard info.  level=2: more verbose (shows backup files etc.).
// If targets is empty, shows info for ALL packages.
fn sync_info_dbs(syncdbs []&db.Database, level int, targets []string, quiet bool) ! {
	mut found_any := false

	if targets.len > 0 {
		// Show info for specific targets.  Target format: repo/pkgname or pkgname.
		for target in targets {
			mut t_repo := ''
			mut t_pkg := target
			if slash_idx := target.index('/') {
				t_repo = target[..slash_idx]
				t_pkg = target[slash_idx + 1..]
			}

			mut found := false
			for sdb in syncdbs {
				if t_repo != '' && sdb.name != t_repo {
					continue
				}
				if pkg := sdb.pkgcache[t_pkg] {
					found = true
					found_any = true
					if !quiet {
						print_sync_pkg_info(pkg, sdb.name, level)
					} else {
						println('${sdb.name}/${pkg.name} ${pkg.version}')
					}
				}
			}
			if !found {
				eprintln('warning: package "${target}" was not found')
			}
		}
	} else {
		// Show info for ALL packages across all databases.
		for sdb in syncdbs {
			for _, pkg in sdb.pkgcache {
				found_any = true
				if !quiet {
					print_sync_pkg_info(pkg, sdb.name, level)
				} else {
					println('${sdb.name}/${pkg.name} ${pkg.version}')
				}
			}
		}
	}

	if !found_any {
		return error('no packages found')
	}
}

// print_sync_pkg_info prints detailed information about a sync package.
fn print_sync_pkg_info(pkg &db.Package, repo_name string, level int) {
	println('Repository    : ${repo_name}')
	println('Name          : ${pkg.name}')
	println('Version       : ${pkg.version}')
	if pkg.base != '' && pkg.base != pkg.name {
		println('Base          : ${pkg.base}')
	}
	if pkg.desc != '' {
		println('Description   : ${pkg.desc}')
	}
	println('Architecture  : ${pkg.arch}')
	if pkg.url != '' {
		println('URL           : ${pkg.url}')
	}
	if pkg.licenses.len > 0 {
		println('Licenses      : ${pkg.licenses.join("  ")}')
	}
	if pkg.groups.len > 0 {
		println('Groups        : ${pkg.groups.join("  ")}')
	}
	if pkg.download_size > 0 {
		println('Download Size : ${pkg.download_size} B')
	}
	if pkg.isize > 0 {
		println('Installed Size: ${pkg.isize} B')
	}
	if pkg.packager != '' {
		println('Packager      : ${pkg.packager}')
	}
	if pkg.build_date > 0 {
		println('Build Date    : ${pkg.build_date}')
	}
	if pkg.filename != '' {
		println('Filename      : ${pkg.filename}')
	}
	if pkg.sha256sum != '' {
		println('SHA256 Sum    : ${pkg.sha256sum}')
	}
	if pkg.base64_sig != '' {
		println('PGP Signature : (present)')
	}

	if pkg.replaces.len > 0 {
		mut repl_strs := []string{}
		for d in pkg.replaces {
			repl_strs << d.to_string()
		}
		println('Replaces      : ${repl_strs.join("  ")}')
	}
	if pkg.depends.len > 0 {
		mut dep_strs := []string{}
		for d in pkg.depends {
			dep_strs << d.to_string()
		}
		println('Depends On    : ${dep_strs.join("  ")}')
	}
	if pkg.optdepends.len > 0 {
		mut opt_strs := []string{}
		for d in pkg.optdepends {
			if d.desc != '' {
				opt_strs << '${d.name}: ${d.desc}'
			} else {
				opt_strs << d.to_string()
			}
		}
		println('Optional Deps : ${opt_strs.join("  ")}')
	}
	if pkg.makedepends.len > 0 {
		mut m_strs := []string{}
		for d in pkg.makedepends {
			m_strs << d.to_string()
		}
		println('Make Deps     : ${m_strs.join("  ")}')
	}
	if pkg.checkdepends.len > 0 {
		mut c_strs := []string{}
		for d in pkg.checkdepends {
			c_strs << d.to_string()
		}
		println('Check Deps    : ${c_strs.join("  ")}')
	}
	if pkg.conflicts.len > 0 {
		mut conf_strs := []string{}
		for d in pkg.conflicts {
			conf_strs << d.to_string()
		}
		println('Conflicts With: ${conf_strs.join("  ")}')
	}
	if pkg.provides.len > 0 {
		mut prov_strs := []string{}
		for d in pkg.provides {
			prov_strs << d.to_string()
		}
		println('Provides      : ${prov_strs.join("  ")}')
	}

	// Level 2: show files if present.
	if level >= 2 && pkg.files.files.len > 0 {
		println('Files         :')
		for f in pkg.files.files {
			println('  ${f.name}')
		}
	}

	println('')
}

// ===========================================================================
//  List (-Sl)
// ===========================================================================

// sync_list_dbs lists packages in sync databases.
// If targets are given, only those repositories are shown.
fn sync_list_dbs(syncdbs []&db.Database, targets []string, dbpath string, quiet bool) ! {
	mut dbs_to_show := []&db.Database{}

	if targets.len > 0 {
		for target in targets {
			mut found := false
			for sdb in syncdbs {
				if sdb.name == target {
					dbs_to_show << sdb
					found = true
					break
				}
			}
			if !found {
				eprintln('warning: repository "${target}" was not found')
			}
		}
	} else {
		dbs_to_show = syncdbs.clone()
	}

	// Load local database for [installed] markers.
	mut local_pkgcache := map[string]&db.Package{}
	{
		local_dir := os.join_path(dbpath, 'local')
		if os.is_dir(local_dir) {
			if ldb := db.init(dbpath) {
				mut ldb_mut := ldb
				ldb_mut.populate() or {}
				                local_pkgcache = ldb_mut.pkgcache.clone()
			}
		}
	}

	for sdb in dbs_to_show {
		for _, pkg in sdb.pkgcache {
			if quiet {
				println('${pkg.name}')
			} else {
				installed_marker := if pkg.name in local_pkgcache {
					' [installed]'
				} else {
					''
				}
				println('${sdb.name} ${pkg.name} ${pkg.version}${installed_marker}')
			}
		}
	}
}

// ===========================================================================
//  Install / Upgrade (-Su, -Suu, and/or targets)
// ===========================================================================

// sync_install_or_upgrade handles package installation and system upgrade.
// This is the most complex sync sub-operation, analogous to sync_trans()
// in pacman's sync.c.
fn sync_install_or_upgrade(args &CliArgs, syncdbs []&db.Database, cfg &config.Config,
	dbpath string) ! {
	// 1. Resolve root.
	mut root := if args.root != '' { args.root } else { cfg.rootdir }
	if root == '' {
		root = '/'
	}

	// 2. Build the handle.  dbpath may already be root-prefixed (from run_sync);
	// strip the root prefix so resolved_dbpath() doesn't double-join.
	mut handle_dbpath := dbpath
	if root != '' && root != '/' && dbpath.starts_with(root) {
		handle_dbpath = dbpath[root.len..]
	}
	handle := &util.Handle{
		root:            root
		dbpath:          handle_dbpath
		overwrite_files: args.overwrite_files
		hookedirs:       if args.hookdirs.len > 0 { args.hookdirs.clone() } else { cfg.hookdirs.clone() }
	}

	// 3. Open local database.
	mut localdb_raw := db.init(dbpath) or {
		return error('cannot open local database: ${err}')
	}
	localdb_raw.populate()!

	mut localdb := &db.Database{
		pkgcache: localdb_raw.pkgcache
	}

	// 4. Build ignore lists from args and config.
	mut ignorepkgs := []string{}
	ignorepkgs << args.ignore_pkgs
	ignorepkgs << cfg.ignorepkgs

	mut ignoregroups := []string{}
	ignoregroups << cfg.ignoregroups
	ignoregroups << args.ignore_groups

	resolve_hnd := &trans.ResolveHandle{
		ignorepkgs:   ignorepkgs
		ignoregroups: ignoregroups
		// Pre-build local provides index for O(1) provider lookups
		// during dependency resolution.  Without this, satisfied_by_localdb
		// does an O(N) scan of every installed package per dependency.
		local_provides: build_local_provides(localdb)
	}

	// 5. Set up transaction flags.
	mut trans_flags := 0
	if args.nodeps >= 1 {
		trans_flags |= trans.trans_flag_nodepversion
	}
	if args.nodeps >= 2 {
		trans_flags |= trans.trans_flag_nodeps
	}
	if args.dbonly {
		trans_flags |= trans.trans_flag_dbonly
		trans_flags |= trans.trans_flag_noscriptlet // --dbonly implies --noscriptlet
	}
	if args.noscriptlet {
		trans_flags |= trans.trans_flag_noscriptlet
	}
	if args.download_only {
		trans_flags |= trans.trans_flag_downloadonly
	}
	if args.needed {
		trans_flags |= trans.trans_flag_needed
	}

	// 6. Build the list of packages to install/upgrade.
	mut pkg_targets := []&db.Package{}
	mut pkg_names_added := map[string]bool{}
	mut errors := []string{}

	// 6a. Full system upgrade (-Su / -Suu).
	if args.sync_upgrade > 0 {
		downgrade := args.sync_upgrade >= 2
		println(':: Starting full system upgrade...')

		for local_name, local_pkg in localdb.pkgcache {
			// Check if this package is ignored.
			if trans.pkg_should_ignore(local_pkg, ignorepkgs, ignoregroups) {
				println('  skipping ${local_name} (ignored)')
				continue
			}

			// Find the package in sync databases.
			mut sync_pkg := &db.Package{}
			mut found_in_sync := false
			for sdb in syncdbs {
				if p := sdb.pkgcache[local_name] {
					sync_pkg = unsafe { p }
					found_in_sync = true
					break
				}
			}

			if !found_in_sync {
				// Package not in sync DBs — no upgrade available, skip.
				continue
			}

			cmp := util.vercmp(sync_pkg.version, local_pkg.version)

			if cmp > 0 {
				// Newer version available — upgrade.
				if pkg_names_added[sync_pkg.name] {
					continue
				}
				pkg_targets << sync_pkg
				pkg_names_added[sync_pkg.name] = true
				println('  upgrading ${local_name} (${local_pkg.version} -> ${sync_pkg.version})')
			} else if cmp < 0 && downgrade {
				// Downgrade (only with -Suu).
				if pkg_names_added[sync_pkg.name] {
					continue
				}
				pkg_targets << sync_pkg
				pkg_names_added[sync_pkg.name] = true
				println('  downgrading ${local_name} (${local_pkg.version} -> ${sync_pkg.version})')
			} else {
				// Same version or local is newer — never reinstall during
				// system upgrade.  --needed controls explicit -S <pkg>
				// reinstalls, not -Su behavior (matching pacman).
			}

			// --all-optional: also pull in optional deps for upgraded pkgs.
			if args.all_optional {
				for opt in sync_pkg.optdepends {
					if pkg_names_added[opt.name] {
						continue
					}
					for opt_sdb in syncdbs {
						if opt_pkg := opt_sdb.pkgcache[opt.name] {
							pkg_targets << opt_pkg
							pkg_names_added[opt.name] = true
							break
						}
					}
				}
			}
		}
	}

	// 6b. Specific package targets.
	for target in args.targets {
		if pkg_names_added[target] {
			continue
		}

		mut t_repo := ''
		mut t_pkg_name := target
		if slash_idx := target.index('/') {
			t_repo = target[..slash_idx]
			t_pkg_name = target[slash_idx + 1..]
		}

		mut found_pkg := false
		for sdb in syncdbs {
			if t_repo != '' && sdb.name != t_repo {
				continue
			}
			if p := sdb.pkgcache[t_pkg_name] {
				// --needed: skip if already installed at the same version.
				if args.needed {
					if old := localdb.pkgcache[t_pkg_name] {
						if util.vercmp(p.version, old.version) == 0 {
							println('  skipping ${t_pkg_name} (already up to date)')
							found_pkg = true
							break
						}
					}
				}

				pkg_targets << p
				pkg_names_added[t_pkg_name] = true
				found_pkg = true

				// --all-optional: also install all optional dependencies.
				if args.all_optional {
					for opt in p.optdepends {
						if pkg_names_added[opt.name] {
							continue
						}
						// Search ALL sync DBs for the optional dep.
						mut found_opt := false
						for opt_sdb in syncdbs {
							if opt_pkg := opt_sdb.pkgcache[opt.name] {
								pkg_targets << opt_pkg
								pkg_names_added[opt.name] = true
								found_opt = true
								break
							}
						}
						if !found_opt {
							eprintln(warn('optional dependency ${opt.name} not found in any repository'))
						}
					}
				}
				break
			}
		}

		if !found_pkg {
			// Check if it's a group name.
			mut found_group := false
			for sdb in syncdbs {
				if t_repo != '' && sdb.name != t_repo {
					continue
				}
				if group := sdb.grpcache[t_pkg_name] {
					for gname in group.packages {
						if pkg_names_added[gname] {
							continue
						}
						if p := sdb.pkgcache[gname] {
							pkg_targets << p
							pkg_names_added[gname] = true
						}
					}
					found_group = true
					break
				}
			}
			if !found_group {
				errors << 'target not found: ${target}'
			}
		}
	}

	if errors.len > 0 {
		return error(errors.join('; '))
	}

	// 6c. --libs & --extreme-libs: build library index once, then resolve.
	// Share LibCheck to avoid double construction when both flags are set.
	mut libcheck_shared := if args.libs || args.extreme_libs {
		mut lc := trans.new_lib_check(syncdbs)
		lc.init_cache(dbpath) or {
			eprintln(warn('cannot init libcheck cache: ${err}'))
		}
		lc
	} else {
		trans.LibCheck{}
	}

	// 6c-i. --libs: fast path — uses cache for speed, less accurate.
	if args.libs {
		println(heading_str('Resolving library dependencies (cached)...'))

		// Collect current target names for the resolver.
		mut current_names := []string{}
		for p in pkg_targets {
			current_names << p.name
		}

		// Resolve via cached fast path — checks cache first, resolves
		// only uncached packages, stores results back.
		extra_libs := libcheck_shared.resolve_libs_cached(current_names, syncdbs)
		for lib_pkg_name in extra_libs {
			if pkg_names_added[lib_pkg_name] {
				continue
			}
			// Skip if already installed at the same version — library
			// providers don't need reinstallation when up-to-date.
			if old := localdb.pkgcache[lib_pkg_name] {
				mut found_ver_match := false
				for sdb in syncdbs {
					if p := sdb.pkgcache[lib_pkg_name] {
						if util.vercmp(p.version, old.version) == 0 {
							found_ver_match = true
						}
						break
					}
				}
				if found_ver_match {
					continue
				}
			}
			mut found := false
			for sdb in syncdbs {
				if p := sdb.pkgcache[lib_pkg_name] {
					pkg_targets << p
					pkg_names_added[lib_pkg_name] = true
					found = true
					println('  adding ${lib_pkg_name} (cached library provider)')
					break
				}
			}
			if !found {
				eprintln('  warning: library provider ${lib_pkg_name} not found in sync databases')
			}
		}
		if extra_libs.len == 0 {
			println('  no additional library providers needed')
		}
		println('')
	}

	// 6c-ii. --extreme-libs: always fresh ldconfig — maximum accuracy.
	if args.extreme_libs {
		println(heading_str('Cross-referencing with installed libraries (ldconfig, fresh)...'))

		// Collect current target names for the resolver.
		mut current_names := []string{}
		for p in pkg_targets {
			current_names << p.name
		}

		// Resolve via fresh ldconfig cross-reference — bypasses cache.
		extreme_libs := libcheck_shared.resolve_libs_ldconfig_uncached(current_names, syncdbs)
		for lib_pkg_name in extreme_libs {
			if pkg_names_added[lib_pkg_name] {
				continue
			}
			// Skip if already installed at same version.
			if old := localdb.pkgcache[lib_pkg_name] {
				mut found_ver_match := false
				for sdb in syncdbs {
					if p := sdb.pkgcache[lib_pkg_name] {
						if util.vercmp(p.version, old.version) == 0 {
							found_ver_match = true
						}
						break
					}
				}
				if found_ver_match {
					continue
				}
			}
			mut found := false
			for sdb in syncdbs {
				if p := sdb.pkgcache[lib_pkg_name] {
					pkg_targets << p
					pkg_names_added[lib_pkg_name] = true
					found = true
					println('  adding ${lib_pkg_name} (fresh ldconfig provider)')
					break
				}
			}
			if !found {
				eprintln('  warning: ldconfig provider ${lib_pkg_name} not found in sync databases')
			}
		}
		if extreme_libs.len == 0 {
			println('  no additional providers found via ldconfig')
		}
		println('')
	}

	if pkg_targets.len == 0 {
		println(' there is nothing to do')
		return
	}

	// 7. Set up and run the transaction.
	mut t := trans.new_transaction()
	trans.trans_init(mut t, handle, trans_flags, resolve_hnd, syncdbs, localdb) or {
		return error('cannot initialize transaction: ${err}')
	}
	defer {
		t.release()
	}

	// Add packages to the transaction.
	for pkg in pkg_targets {
		trans.add_pkg_to_trans(mut t, pkg) or {
			errors << '${pkg.name}: ${err.msg()}'
		}
	}
	if errors.len > 0 {
		return error('failed to add packages: ${errors.join("; ")}')
	}

	// 8. Prepare (resolve dependencies, check conflicts).
	// prepare returns ?[]db.DepMissing — none means success.
	if miss := trans.prepare(mut t) {
		for m in miss {
			eprintln('warning: cannot resolve "${m.target}", skipping')
		}
	}

	// After prepare, the transaction's add_pkgs list has been re-sorted and
	// enriched with dependencies.  Get the final package list.
	display_pkgs := trans.get_add_pkgs(&t)

	if display_pkgs.len == 0 {
		println(' there is nothing to do')
		return
	}

	// 9. Print mode (--print).
	if args.print {
		println('Packages to install/upgrade:')
		for dpkg in display_pkgs {
			if old := localdb.pkgcache[dpkg.name] {
				println('  ${pkg(dpkg.name)} ${upgrade(old.version, dpkg.version)}')
			} else {
				println('  ${new_pkg(dpkg.name)} ${light_pink}${dpkg.version}${reset}')
			}
		}
		return
	}

	// 10. Confirmation prompt.
	println('')
	if display_pkgs.len > 0 {
		println('resolving dependencies...')
		println('looking for conflicting packages...')
		println('')
		println(pkg('Packages') + ' (${display_pkgs.len}):')
		for dpkg in display_pkgs {
			if old := localdb.pkgcache[dpkg.name] {
				println('  ${pkg(dpkg.name)} ${installed('[installed: ${old.version}]')} ${arrow()} ${new_pkg(dpkg.version)}')
			} else {
				println('  ${new_pkg(dpkg.name)}-${pkg_version(dpkg.version)}')
			}
		}

		// Show optional dependencies for each package that has them.
		mut has_optdeps := false
		for dpkg in display_pkgs {
			if dpkg.optdepends.len > 0 {
				has_optdeps = true
				break
			}
		}
		if has_optdeps {
			println('')
			println(muted('Optional dependencies:'))
			for dpkg in display_pkgs {
				if dpkg.optdepends.len == 0 {
					continue
				}
				for opt in dpkg.optdepends {
					installed_mark := if _ := localdb.pkgcache[opt.name] {
						' ${installed('[installed]')}'
					} else {
						''
					}
					if opt.desc != '' {
						println('  ${opt_dep(opt.name, opt.desc)}${installed_mark}')
					} else {
						println('  ${opt_dep(opt.name, '')}${installed_mark}')
					}
				}
			}
		}

		mut total_download_size := i64(0)
		mut total_installed_size := i64(0)
		for pkg in display_pkgs {
			total_download_size += pkg.download_size
			total_installed_size += pkg.isize
		}
		if total_download_size > 0 {
			println('')
			print('Total Download Size:   ')
			print_human_size(total_download_size)
			println('')
		}
		if total_installed_size > 0 {
			print('Total Installed Size:  ')
			print_human_size(total_installed_size)
			println('')
		}
	}
	println('')
	if !handle.no_confirm && !args.print {
		confirm_prompt := if args.download_only {
			':: Proceed with download? [Y/n] '
		} else {
			':: Proceed with installation? [Y/n] '
		}
		print('${confirm_prompt}')
		response_input := os.input('').trim_space().to_lower()
		if response_input != '' && response_input != 'y' && response_input != 'yes' {
			println('cancelled')
			return
		}
	}

	// 11. Download packages.
	if syncdbs.len > 0 && display_pkgs.len > 0 {
		// Determine cache directory.
		cachedir := if cfg.cachedirs.len > 0 {
			os.join_path(root, cfg.cachedirs[0])
		} else {
			os.join_path(root, 'var/cache/ace/pkg')
		}
		if !os.exists(cachedir) {
			os.mkdir_all(cachedir)!
		}

		// Build download payloads for packages that have a filename.
		mut payloads := []download.DownloadPayload{}
		for pkg in display_pkgs {
			if pkg.filename == '' {
				continue
			}
			dest := os.join_path(cachedir, pkg.filename)
			if os.exists(dest) && !args.download_only {
				// Already downloaded, keep going.
				continue
			}

			// Find the server URL from the repo that contains this package.
			mut server_url := ''
			for sdb in syncdbs {
				if p := sdb.pkgcache[pkg.name] {
					if p.name == pkg.name {
						for su in sdb.servers {
							resolved := su.replace('\$repo', sdb.name)
							base := if resolved.ends_with('/') { resolved } else { resolved + '/' }
							server_url = '${base}${pkg.filename}'
							break
						}
						break
					}
				}
				if server_url != '' {
					break
				}
			}
			if server_url == '' {
				continue
			}

			payloads << download.DownloadPayload{
				url:          server_url
				filename:     pkg.filename
				dest_path:    dest
				force:        false
				allow_resume: true
				errors_ok:    true
				max_size:     2 * 1024 * 1024 * 1024 // 2 GiB limit
			}
		}

		if payloads.len > 0 {
			println(heading_str('Downloading packages...'))
			download_parallel_files(payloads, cfg.parallel_downloads)
		}
	}

	// 12. If download-only, stop here.
	if args.download_only {
		println(':: Packages downloaded to cache')
		return
	}

	// 13. Install packages.
	println(heading_str('Installing packages...'))
	mut install_errors := []string{}
	cachedir2 := if cfg.cachedirs.len > 0 {
		os.join_path(cfg.rootdir, cfg.cachedirs[0])
	} else {
		os.join_path(root, 'var/cache/ace/pkg')
	}
	if !os.exists(cachedir2) {
		os.mkdir_all(cachedir2)!
	}

	// 13a. Run pre-transaction hooks before any package installation.
	// Create the hook engine once — cached_hooks avoids re-parsing .hook
	// files from disk for every subsequent per-package post-install call.
	mut hook_engine := hooks.new_hook_engine(handle)
	run_pre_hooks(mut hook_engine, display_pkgs, []&db.Package{})

	for i in 0 .. display_pkgs.len {
		p := display_pkgs[i]
		if p.filename == '' {
			install_errors << '${p.name}: missing filename, cannot install'
			continue
		}
		pkg_path := os.join_path(cachedir2, p.filename)

		// If the package file doesn't exist in cache, try a direct download
		// from the sync database server
		if !os.exists(pkg_path) {
			// Try downloading directly
			mut server_url := ''
			for sdb in syncdbs {
				if _ := sdb.pkgcache[p.name] {
					for su in sdb.servers {
						resolved := su.replace('\$repo', sdb.name)
						base_url := if resolved.ends_with('/') { resolved } else { resolved + '/' }
						server_url = '${base_url}${p.filename}'
						break
					}
					break
				}
			}
			if server_url != '' {
				mut dl := download.Downloader{}
				dl.init('ace/0.1', 60000, fn (pct int, msg string) {})
				dl.download(download.DownloadPayload{
					url:       server_url
					filename:  p.filename
					dest_path: pkg_path
				}) or {
					install_errors << '${p.name}: download failed (${err.msg()})'
					continue
				}
			} else {
				install_errors << '${p.name}: no server URL found'
				continue
			}
		}

		old_pkg := if old := localdb.pkgcache[p.name] { old } else { none }
		// Create an install copy — only filename, origin, and files differ
		// from the sync DB entry.  All dependency arrays (depends, provides,
		// conflicts, etc.) are shared via slice-header copy — they are
		// never modified during install, so cloning them is wasteful.
		mut install_pkg := unsafe { &db.Package{} }
		install_pkg.name = p.name
		install_pkg.name_hash = p.name_hash
		install_pkg.version = p.version
		install_pkg.filename = pkg_path
		install_pkg.base = p.base
		install_pkg.desc = p.desc
		install_pkg.url = p.url
		install_pkg.packager = p.packager
		install_pkg.arch = p.arch
		install_pkg.build_date = p.build_date
		install_pkg.install_date = p.install_date
		install_pkg.isize = p.isize
		install_pkg.download_size = p.download_size
		install_pkg.licenses = p.licenses // shared — never mutated
		install_pkg.replaces = p.replaces
		install_pkg.groups = p.groups
		install_pkg.depends = p.depends
		install_pkg.optdepends = p.optdepends
		install_pkg.conflicts = p.conflicts
		install_pkg.provides = p.provides
		install_pkg.origin = .local_db
		install_pkg.reason = p.reason
		install_pkg.validation = p.validation
		install_pkg.scriptlet = p.scriptlet
		install_pkg.sha256sum = p.sha256sum
		install_pkg.base64_sig = p.base64_sig
		// files.files and backup are NOT pre-copied — extract_package_files
		// clears pkg.files (line 39 of trans/install.v) and repopulates from
		// the archive, so any pre-copied data would be discarded.

		trans.install_package(handle, mut install_pkg, old_pkg) or {
			install_errors << '${p.name}: ${err.msg()}'
			continue
		}
		localdb.pkgcache[p.name] = install_pkg

		// Run post-install hooks for this specific package.
		run_post_install_hook(mut hook_engine, install_pkg)
	}

	if install_errors.len > 0 {
		return error('installation failed: ${install_errors.join("; ")}')
	}

	// Run post-transaction hooks (initramfs, font cache, etc.).
	run_post_hooks(mut hook_engine, display_pkgs, []&db.Package{})

	println(heading_str('done'))
}

// DLResult carries per-file download completion status.
struct DLResult {
	idx      int
	filename string
	ok       bool
}

// DLProg carries per-file download progress updates from goroutines.
struct DLProg {
	idx int
	pct int
}

// download_parallel_files downloads multiple files concurrently using
// goroutines for true parallelism, with real-time colored progress bars
// per active download.  A semaphore limits concurrency (pre-fetched
// tokens prevent slot leaks on panic).  Progress is collected from each
// goroutine and rendered as multi-line ANSI bars.
fn download_parallel_files(payloads []download.DownloadPayload, parallel_downloads int) {
	if payloads.len == 0 {
		return
	}

	max_conc := if parallel_downloads > 0 { parallel_downloads } else { 7 }
	total := payloads.len

	// Semaphore channel: pre-fill with max_conc tokens.
	sem := chan int{cap: max_conc}
	for _ in 0 .. max_conc {
		sem <- 0
	}
	result_ch := chan DLResult{cap: total}

	// Progress channel for real-time bar updates.
	prog_ch := chan DLProg{cap: total * 200}

	// Build display filenames (truncated).
	mut disp_names := []string{len: total}
	for i, payload in payloads {
		disp_names[i] = if payload.filename.len > 42 {
			payload.filename[..39] + '...'
		} else {
			payload.filename
		}
	}

	// Current progress per index (updated by render goroutine).
	mut prog_map := []int{len: total, init: -1}
	mut done_map := []bool{len: total}

	// Spawn download goroutines.
	println('')
	for i, payload in payloads {
		go fn [payload, i, sem, result_ch, prog_ch]() {
			_ = <-sem
			defer {
				sem <- 0
			}

			mut download_ok := false
			defer {
				result_ch <- DLResult{
					idx: i
					filename: ''
					ok: download_ok
				}
				// Signal completion with 100%.
				prog_ch <- DLProg{
					idx: i
					pct: 100
				}
			}

			mut dl := download.Downloader{}
			dl.init('ace/0.1', 60000, fn [i, prog_ch] (pct int, _ string) {
				if pct >= 0 {
					prog_ch <- DLProg{
						idx: i
						pct: pct
					}
				}
			})
			dl.download(payload) or { return }
			download_ok = true
		}()
	}

	// --- collect results while rendering progress bars ---

	// Track how many lines we printed so we can clear them at the end.
	mut bar_lines := 0

	mut completed := 0
	mut failures := 0

	redraw_bars := fn [disp_names, prog_map, done_map, total, max_conc, mut bar_lines] () {
		// Count active downloads.
		mut active := 0
		for i in 0 .. total {
			if !done_map[i] && prog_map[i] >= 0 {
				active++
			}
		}
		if active == 0 && bar_lines == 0 {
			return
		}

		// Move cursor up to previous render position.
		if bar_lines > 0 {
			print('\033[${bar_lines}A')
		}

		mut drawn := 0
		for i in 0 .. total {
			if done_map[i] || prog_map[i] < 0 {
				continue
			}
			mut pct := prog_map[i]
			if pct > 100 {
				pct = 100
			}
			bar := progress_bar_str(pct, 30)
			print('\r\033[K  ${bar} ${disp_names[i]}\n')
			drawn++
			if drawn >= max_conc {
				break
			}
		}

		// Clear leftover lines if the bar count decreased.
		if drawn < bar_lines {
			for _ in drawn .. bar_lines {
				print('\033[K\n')
			}
			// Move back up past cleared lines.
			print('\033[${bar_lines - drawn}A')
		}
		bar_lines = drawn
	}

	// Collect results — render bars after each progress update or result.
	mut collected := 0
	for collected < total {
		select {
			r := <-result_ch {
				collected++
				completed++
				done_map[r.idx] = true
				// Clear the bar area before printing the result line,
				// otherwise bars "clone" below the result on redraw.
				if bar_lines > 0 {
					print('\033[${bar_lines}A')
					for _ in 0 .. bar_lines {
						print('\033[K\n')
					}
					print('\033[${bar_lines}A')
				}
				bar_lines = 0
				if !r.ok {
					failures++
					print('\r\033[K  ${disp_names[r.idx]} ${warn('FAILED')}\n')
				} else {
					print('\r\033[K  ${disp_names[r.idx]} ${ok('done')}\n')
				}
				// Render remaining active bars below the result.
				redraw_bars()
			}
			p := <-prog_ch {
				prog_map[p.idx] = p.pct
				redraw_bars()
			}
		}
	}

	// Final summary line.
	if bar_lines > 0 {
		print('\033[${bar_lines}A')
		for _ in 0 .. bar_lines {
			print('\033[K\n')
		}
		print('\033[${bar_lines}A')
	}
	print('\r\033[K  ' + progress('Downloaded: ${completed}/${total}'))
	if failures > 0 {
		println('  ' + warn('(${failures} failed)'))
	} else {
		println('')
	}
	println('')

	if failures > 0 {
		eprintln(warn('${failures}/${total} downloads failed'))
	}
}

// progress_bar_str renders a colored progress bar like "[#####-----]  47%".
fn progress_bar_str(pct int, width int) string {
	mut filled := pct
	if filled < 0 {
		filled = 0
	}
	if filled > 100 {
		filled = 100
	}
	n := filled * width / 100
	mut bar := '['
	for i in 0 .. width {
		if i < n {
			bar += '#'
		} else {
			bar += '-'
		}
	}
	bar += ']'
	if pct >= 0 {
		bar += ' ${filled:3d}%'
	}
	return bar
}

fn heading_str(s string) string { return heading(s) }
fn pkg_str(s string) string { return pkg(s) }
fn sync_ver(s string) string { return pkg_version(s) }
fn pkg_head(s string) string { return pkg(s) }

// run_pre_hooks executes pre-transaction hooks before any package
// installation begins.  Uses the shared hook_engine so cached .hook
// file parses survive for subsequent per-package post-install calls.
fn run_pre_hooks(mut engine hooks.HookEngine, add_pkgs []&db.Package, remove_pkgs []&db.Package) {
	if engine.handle.hookedirs.len == 0 {
		return
	}
	mut util_pkgs := []&util.Package{}
	for p in add_pkgs {
		util_pkgs << &util.Package{
			name:    p.name
			version: p.version
		}
	}
	mut util_rm_pkgs := []&util.Package{}
	for p in remove_pkgs {
		util_rm_pkgs << &util.Package{
			name:    p.name
			version: p.version
		}
	}
	engine.set_packages(util_pkgs, util_rm_pkgs)
	engine.run_pre(util_pkgs) or {
		eprintln('warning: pre-transaction hook failed: ${err}')
	}
}

// run_post_install_hook executes post-install hooks for a single package
// immediately after it has been installed.  Uses the shared engine so
// .hook files are parsed only once across all packages in the transaction.
fn run_post_install_hook(mut engine hooks.HookEngine, pkg db.Package) {
	if engine.handle.hookedirs.len == 0 {
		return
	}
	util_pkgs := [&util.Package{
		name:    pkg.name
		version: pkg.version
	}]
	engine.set_packages(util_pkgs, []&util.Package{})
	engine.run_post(util_pkgs) or {
		eprintln('warning: post-install hook for ${pkg.name} failed: ${err}')
	}
}

fn run_post_hooks(mut engine hooks.HookEngine, add_pkgs []&db.Package, _ []&db.Package) {
	if engine.handle.hookedirs.len == 0 {
		return
	}
	mut util_pkgs := []&util.Package{}
	for p in add_pkgs {
		util_pkgs << &util.Package{
			name:    p.name
			version: p.version
		}
	}
	engine.set_packages(util_pkgs, []&util.Package{})
	engine.run_post(util_pkgs) or {
		eprintln('warning: post-transaction hook failed: ${err}')
	}
}

// build_local_provides builds an index from virtual provider names to the
// installed packages that provide them.  Used by the resolver for O(1)
// lookups instead of scanning every package's provides list linearly.
fn build_local_provides(localdb &db.Database) map[string][]&db.Package {
	mut idx := map[string][]&db.Package{}
	for _, pkg in localdb.pkgcache {
		for prov in pkg.provides {
			mut list := idx[prov.name] or { []&db.Package{} }
			list << pkg
			idx[prov.name] = list
		}
	}
	return idx
}
