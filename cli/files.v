// -F (files) subcommand — search or list files from sync databases.
//
// Sub-operations:
//   -Fl / --list         list files owned by specified packages
//   -Fy / --refresh      refresh file databases (same as -Sy)
//   -Fx / --regex        treat search pattern as extended regex
//   --machinereadable    null-delimited machine-readable output
//   -q / --quiet         quiet output
//
// Reference: pacman/src/pacman/files.c
module cli

import config
import db
import download
import lock { LockFile }
import os
import regex
import time

// =============================================================================
// Public entry point
// =============================================================================

// run_files executes the -F operation based on the parsed args.
pub fn run_files(args &CliArgs) ! {
	// 1. Resolve paths
	cfg_path := if args.config != '' { args.config } else { '/etc/pacman.conf' }
	mut dbpath := if args.dbpath != '' {
		args.dbpath
	} else if args.root != '' {
		os.join_path(args.root, 'var/lib/ace')
	} else {
		'/var/lib/ace'
	}

	// 2. Parse config
	cfg := config.parse_ini(cfg_path) or {
		return error('cannot parse config ${cfg_path}: ${err}')
	}

	// Override dbpath from config if not set via CLI
	if args.dbpath == '' && args.root == '' && cfg.dbpath != '' {
		dbpath = cfg.dbpath
	}

	// 3. Acquire lock if -y (refresh) is given
	needs_lock := args.files_refresh > 0

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
	mut sync_repos := filter_sync_repos_files(&cfg)
	if sync_repos.len == 0 {
		return error('no sync repositories configured in ${cfg_path}')
	}

	// 6. Handle -y (refresh) first.
	if args.files_refresh > 0 {
		refresh_files_dbs(args.files_refresh, sync_repos, sync_dir)!
	}

	// 7. Load sync databases for operations that need them.
	need_data := args.files_list || args.targets.len > 0

	mut syncdbs := []&db.Database{}
	if need_data {
		syncdbs = load_sync_dbs_files(sync_repos, sync_dir) or {
			return error('cannot load sync databases: ${err}')
		}
	}

	// 8. List mode (-Fl / --list).
	if args.files_list {
		return files_list_dbs(syncdbs, args.targets, args)
	}

	// 9. Search mode (targets given).
	if args.targets.len > 0 {
		return files_search_dbs(syncdbs, args.targets, args)
	}

	// If only -y was given, success.
	if args.files_refresh > 0 {
		return
	}

	return error('no operation specified for files (use -h for help)')
}

// ===========================================================================
//  Config helpers (mirrors filter_sync_repos in sync.v)
// ===========================================================================

fn filter_sync_repos_files(cfg &config.Config) []config.Repo {
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
//  Database refresh (-Fy / -Fyy) — identical to -Sy refresh
// ===========================================================================

fn refresh_files_dbs(refresh_count int, repos []config.Repo, sync_dir string) ! {
	force := refresh_count >= 2

	println(':: Synchronizing package databases...')

	mut errors := []string{}
	for repo in repos {
		repo_sync_files(repo, sync_dir, force) or {
			errors << '${repo.name}: ${err.msg()}'
		}
	}

	if errors.len > 0 {
		return error('failed to sync databases: ${errors.join("; ")}')
	}
}

fn repo_sync_files(repo config.Repo, sync_dir string, force bool) ! {
	treename := repo.name
	// -Fy downloads .files databases (with per-package file listings),
	// not the regular .db databases used by -Sy.
	db_path := os.join_path(sync_dir, '${treename}.files')

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
		url := '${base}${treename}.files'

		print('  ${treename}: downloading ${treename}.files... ')
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
//  Load sync databases (mirrors load_sync_dbs in sync.v)
// ===========================================================================

fn load_sync_dbs_files(repos []config.Repo, sync_dir string) ![]&db.Database {
	mut result := []&db.Database{}
	mut errors := []string{}

	for repo in repos {
		// Try .files database first (from -Fy), fall back to .db (from -Sy).
		mut db_path := os.join_path(sync_dir, '${repo.name}.files')
		if !os.exists(db_path) {
			db_path = os.join_path(sync_dir, '${repo.name}.db')
		}
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
//  List mode (-Fl)
// ===========================================================================

fn files_list_dbs(syncdbs []&db.Database, targets []string, args &CliArgs) ! {
	mut found_any := false

	if targets.len > 0 {
		// List files of specific packages.  Target format: repo/pkgname or pkgname.
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
					print_pkg_files(pkg, sdb.name, args)
				}
			}

			if !found {
				eprintln("error: package '${target}' was not found")
			}
		}
	} else {
		// List all files for all packages in all databases.
		for sdb in syncdbs {
			for _, pkg in sdb.pkgcache {
				found_any = true
				print_pkg_files(pkg, sdb.name, args)
			}
		}
	}

	if !found_any {
		return error('no packages found')
	}
}

fn print_pkg_files(pkg &db.Package, repo_name string, args &CliArgs) {
	if args.files_machinereadable {
		dump_pkg_machinereadable(repo_name, pkg)
		return
	}

	pkgname := pkg.name

	for f in pkg.files.files {
		if !args.quiet {
			print('${pkgname} ')
		}
		println('${f.name}')
	}
}

fn dump_pkg_machinereadable(repo_name string, pkg &db.Package) {
	// Fields are repo, pkgname, pkgver, filename separated with \0
	for f in pkg.files.files {
		print('${repo_name}\0')
		print('${pkg.name}\0')
		print('${pkg.version}\0')
		println('${f.name}')
	}
}

// ===========================================================================
//  Search mode (targets → find which package owns a file)
// ===========================================================================

fn files_search_dbs(syncdbs []&db.Database, targets []string, args &CliArgs) ! {
	mut found_any := false
	use_regex := args.files_regex

	for target in targets {
		mut is_exact_file := target.contains('/')
		mut targ_str := target

		if is_exact_file {
			// Strip leading slashes.
			for targ_str.len > 1 && targ_str[0] == `/` {
				targ_str = targ_str[1..]
			}
		}

		// Compile regex if needed.
		mut re := regex.RE{}
		if use_regex {
			re = regex.regex_opt(targ_str) or {
				eprintln("error: invalid regular expression '${targ_str}'")
				continue
			}
		}

		mut target_found := false

		for sdb in syncdbs {
			for _, pkg in sdb.pkgcache {
				mut match_files := []string{}

				for f in pkg.files.files {
					mut matched := false

					if is_exact_file {
						if use_regex {
							matched = re.matches_string(f.name)
						} else {
							matched = f.name == targ_str
						}
					} else {
						// Search by basename (last component after '/').
						basename := if last_slash := f.name.last_index('/') {
							f.name[last_slash + 1..]
						} else {
							f.name
						}
						if use_regex {
							matched = re.matches_string(basename)
						} else {
							matched = basename == targ_str
						}
					}

					if matched {
						match_files << f.name
					}
				}

				if match_files.len > 0 {
					target_found = true
					found_any = true
					print_match_files(match_files, sdb.name, pkg, is_exact_file, args)
				}
			}
		}

		if !target_found {
			eprintln("error: no package owns '${target}'")
		}
	}

	if !found_any {
		return error('no matches found')
	}
}

fn print_match_files(match_files []string, repo_name string, pkg &db.Package, exact_file bool,
	args &CliArgs) {
	if args.files_machinereadable {
		for fname in match_files {
			print('${repo_name}\0')
			print('${pkg.name}\0')
			print('${pkg.version}\0')
			println('${fname}')
		}
		return
	}

	if args.quiet {
		println('${repo_name}/${pkg.name}')
		return
	}

	for fname in match_files {
		if exact_file {
			println("${fname} is owned by ${repo_name}/${pkg.name} ${pkg.version}")
		} else {
			print('${repo_name}/${pkg.name} ${pkg.version}')
			println('    ${fname}')
		}
	}
}
