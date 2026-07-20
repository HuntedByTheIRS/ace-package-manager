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
	// Query operations (search, info, list, groups) skip the lock.
	needs_lock := args.sync_count > 0 || args.sync_clean > 0 || args.targets.len > 0 ||
		args.sync_upgrade > 0 || args.download_only

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

// refresh_databases downloads the package database for each configured repo.
fn refresh_databases(sync_count int, repos []config.Repo, sync_dir string) ! {
	force := sync_count >= 2

	println(heading_str('Synchronizing package databases...'))

	mut errors := []string{}
	for repo in repos {
		repo_sync(repo, sync_dir, force) or {
			errors << '${repo.name}: ${err.msg()}'
		}
	}

	if errors.len > 0 {
		return error('failed to sync databases: ${errors.join("; ")}')
	}
}

// repo_sync downloads the database (and signature) for a single repository.
fn repo_sync(repo config.Repo, sync_dir string, force bool) ! {
	treename := repo.name
	db_path := os.join_path(sync_dir, '${treename}.db')

	need_db_sig := int(repo.siglevel) & (int(config.SigLevel.database_required) |
		int(config.SigLevel.database_optional)) != 0
	sig_optional := int(repo.siglevel) & int(config.SigLevel.database_optional) != 0

	mut dl := download.Downloader{}
	dl.init('ace/0.1', 30000, fn (pct int, msg string) {
		if pct >= 0 {
			print('\r  ${pct}%')
		}
	})

	mut last_db_err := error('no servers configured')

	for server_url in repo.servers {
		resolved := server_url.replace('\$repo', treename)
		base := if resolved.ends_with('/') { resolved } else { resolved + '/' }
		url := '${base}${treename}.db'

		print('  ${treename}: downloading ${treename}.db... ')
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
			print('failed (${err.msg()})\n')
			last_db_err = err
			continue
		}
		print('done\n')

		// Log the successful sync timestamp.
		now := time.unix_now()
		os.write_file(os.join_path(sync_dir, '${treename}.lastupdate'), '${now}\n') or {}
		return
	}

	return error('${treename}: all mirrors failed — ${last_db_err.msg()}')
}

// ===========================================================================
//  Load sync databases
// ===========================================================================

// load_sync_dbs loads all sync database files into Database structs.
fn load_sync_dbs(repos []config.Repo, sync_dir string) ![]&db.Database {
	mut result := []&db.Database{}
	mut errors := []string{}

	for repo in repos {
		db_path := os.join_path(sync_dir, '${repo.name}.db')
		if !os.exists(db_path) {
			errors << '${repo.name}: database not found at ${db_path}'
			continue
		}

		mut sdb := db.new_sync_db()
		db.populate(mut sdb, db_path) or {
			errors << '${repo.name}: ${err.msg()}'
			continue
		}

		mut database := &db.Database{
			pkgcache: sdb.pkgcache
			name:     repo.name
			servers:  repo.servers
		}
		db.build_grpcache(mut database)

		result << database
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
	if level == 1 {
		// -Sc: Determine clean method from config.
		keep_installed := cfg.cleanmethod == .keep_installed || (cfg.cleanmethod != .keep_current)
		keep_current := cfg.cleanmethod == .keep_current

		// Prompt before selective cleaning.
		if !handle.no_confirm {
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
				                local_pkgcache = ldb_mut.pkgcache.clone().clone()
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

	resolve_hnd := &trans.ResolveHandle{
		ignorepkgs:   ignorepkgs
		ignoregroups: ignoregroups
	}

	// 5. Set up transaction flags.
	mut trans_flags := 0
	if args.nodeps {
		trans_flags |= trans.trans_flag_nodeps
	}
	if args.dbonly {
		trans_flags |= trans.trans_flag_dbonly
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
				// Newer version available.
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
				// Same version (or local is newer without -Suu).
				if !args.needed || args.download_only {
					// If --needed, skip up-to-date packages.
					if pkg_names_added[sync_pkg.name] {
						continue
					}
					pkg_targets << sync_pkg
					pkg_names_added[sync_pkg.name] = true
					println('  reinstalling ${local_name} (${local_pkg.version})')
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
				pkg_targets << p
				pkg_names_added[t_pkg_name] = true
				found_pkg = true

				// --all-optional: also install all optional dependencies.
				if args.all_optional {
					for opt in p.optdepends {
						if pkg_names_added[opt.name] {
							continue
						}
						if opt_pkg := sdb.pkgcache[opt.name] {
							pkg_targets << opt_pkg
							pkg_names_added[opt.name] = true
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
		for pkg in display_pkgs {
			old := if installed := localdb.pkgcache[pkg.name] {
				installed.version
			} else {
				''
			}
			if old != '' {
				println('  ${pkg.name} (${old} -> ${pkg.version})')
			} else {
				println('  ${pkg.name} ${pkg.version}')
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
		println(pkg_head('Packages') + ' (${display_pkgs.len}) ${pkg_str(display_pkgs[0].name)}-${sync_ver(display_pkgs[0].version)}')
		for i := 1; i < display_pkgs.len; i++ {
			println('             ${pkg_str(display_pkgs[i].name)}-${sync_ver(display_pkgs[i].version)}')
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
	if !handle.no_confirm {
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
			os.join_path(cfg.rootdir, cfg.cachedirs[0])
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

	for i in 0 .. display_pkgs.len {
		p := display_pkgs[i]
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
				dl.init('ace/0.1', 30000, unsafe { nil })
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
		// Create a mutable copy with the local file path for install.
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
		install_pkg.licenses = p.licenses.clone()
		install_pkg.replaces = p.replaces.clone()
		install_pkg.groups = p.groups.clone()
		install_pkg.depends = p.depends.clone()
		install_pkg.optdepends = p.optdepends.clone()
		install_pkg.conflicts = p.conflicts.clone()
		install_pkg.provides = p.provides.clone()
		install_pkg.origin = .local_db
		install_pkg.reason = p.reason
		install_pkg.validation = p.validation
		install_pkg.scriptlet = p.scriptlet
		install_pkg.sha256sum = p.sha256sum
		install_pkg.base64_sig = p.base64_sig

		// Copy file list and backup files from sync DB
		for f in p.files.files { install_pkg.files.files << f }
		for b in p.backup { install_pkg.backup << b }

		trans.install_package(handle, mut install_pkg, old_pkg) or {
			install_errors << '${p.name}: ${err.msg()}'
			continue
		}
		localdb.pkgcache[p.name] = install_pkg
	}

	if install_errors.len > 0 {
		return error('installation failed: ${install_errors.join("; ")}')
	}

	// Run post-transaction hooks (initramfs, font cache, etc.).
	run_post_hooks(handle, display_pkgs, []&db.Package{})

	println(heading_str('done'))
}

// download_parallel_files downloads multiple files concurrently using
// the download module's parallel downloading infrastructure.
fn download_parallel_files(payloads []download.DownloadPayload, parallel_downloads int) {
	if payloads.len == 0 {
		return
	}

	max_conc := if parallel_downloads > 0 { parallel_downloads } else { 1 }

	mut success_count := 0
	mut error_count := 0

	// Use a simple sequential approach for now (parallel via goroutines
	// would be ideal but requires careful channel management here).
	for i, payload in payloads {
		mut dl := download.Downloader{}
		dl.init('ace/0.1', 60000, fn (pct int, msg string) {
			if pct >= 0 && pct < 100 {
				print('\r  ${pct}%')
			}
		})

		if i > 0 && i % max_conc == 0 {
			// Flow control: wait between batches (simplified).
			println('')
		}

		print('  ${payload.filename}: downloading... ')
		dl.download(payload) or {
			print('failed (${err.msg()})\n')
			error_count++
			continue
		}
		print('done\n')
		success_count++
	}

	if error_count > 0 {
		eprintln('warning: ${error_count}/${payloads.len} downloads failed')
	}
}

fn heading_str(s string) string { return '\033[1m\033[38;5;160m::\033[0m \033[1m${s}\033[0m' }
fn pkg_str(s string) string { return '\033[1m\033[38;5;160m${s}\033[0m' }
fn sync_ver(s string) string { return '\033[38;5;160m${s}\033[0m' }
fn pkg_head(s string) string { return '\033[1m\033[38;5;160m${s}\033[0m' }

fn run_post_hooks(handle &util.Handle, add_pkgs []&db.Package, _ []&db.Package) {
	if handle.hookedirs.len == 0 {
		return
	}
	mut engine := hooks.new_hook_engine(handle)
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
