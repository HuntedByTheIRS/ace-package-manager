module cli

import archive
import config
import db
import hooks
import os
import trans
import util

// is_pkg_file checks whether a filename matches a known Arch package extension.
fn is_pkg_file(name string) bool {
	return name.ends_with('.pkg.tar.zst') ||
		name.ends_with('.pkg.tar.xz') ||
		name.ends_with('.pkg.tar.gz') ||
		name.ends_with('.pkg.tar.bz2') ||
		name.ends_with('.pkg.tar.lz4') ||
		name.ends_with('.pkg.tar.lzo') ||
		name.ends_with('.pkg.tar.lrz') ||
		name.ends_with('.pkg.tar.Z') ||
		(name.ends_with('.pkg.tar') &&
			!name.ends_with('.pkg.tar.zst') &&
			!name.ends_with('.pkg.tar.xz') &&
			!name.ends_with('.pkg.tar.gz') &&
			!name.ends_with('.pkg.tar.bz2') &&
			!name.ends_with('.pkg.tar.lz4') &&
			!name.ends_with('.pkg.tar.lzo') &&
			!name.ends_with('.pkg.tar.lrz') &&
			!name.ends_with('.pkg.tar.Z'))
}

pub fn run_upgrade(args &CliArgs, cfg &config.Config, handle &util.Handle) ! {
	if args.targets.len == 0 { return error('no targets specified for upgrade') }
	dbpath := if args.root != '' {
		os.join_path(args.root, if args.dbpath != '' { args.dbpath } else { 'var/lib/ace' })
	} else if args.dbpath != '' {
		args.dbpath
	} else {
		handle.resolved_dbpath()
	}
	mut local_db := db.init(dbpath)!
	local_db.populate()!
	mut pkgfiles := []string{}
	mut collect_errors := []string{}
	for target in args.targets {
		if os.exists(target) && !os.is_dir(target) && is_pkg_file(target) {
			pkgfiles << target
		} else if os.is_dir(target) {
			entries := os.ls(target) or {
				collect_errors << 'cannot list dir ${target}: ${err.msg()}'
				continue
			}
			for entry in entries {
				if is_pkg_file(entry) {
					pkgfiles << os.join_path(target, entry)
				}
			}
		} else {
			collect_errors << 'target not found: ${target}'
		}
	}
	if collect_errors.len > 0 {
		eprintln(warn('some targets could not be processed: ${collect_errors.join("; ")}'))
	}
	if pkgfiles.len == 0 { return error('no valid package files') }
	if args.print {
		println('Target packages to install/upgrade:')
		for pf in pkgfiles {
			// Try to load metadata for installed status preview.
			pkgmeta := archive.load_pkg_full(pf) or {
				println('  ${pf}')
				continue
			}
			if old := local_db.pkgcache[pkgmeta.name] {
				println('  ${pkg(pkgmeta.name)} ${upgrade(old.version, pkgmeta.version)}')
			} else {
				println('  ${new_pkg(pkgmeta.name)} ${light_pink}${pkgmeta.version}${reset}')
			}
		}
		return
	}
	if !confirm_upgrade(pkgfiles, &local_db, args.noconfirm) { println('cancelled'); return }

	// Run pre-transaction hooks.
	mut pre_pkgs := []&util.Package{}
	mut pre_failures := []string{}
	if handle.hookedirs.len > 0 {
		for pf in pkgfiles {
			pkgmeta := archive.load_pkg_full(pf) or {
				pre_failures << pf
				continue
			}
			pre_pkgs << &util.Package{
				name:    pkgmeta.name
				version: pkgmeta.version
				files:   pkgmeta.files.files.map(it.name)
			}
		}
		if pre_failures.len > 0 {
			eprintln(warn('${pre_failures.len} package(s) could not be loaded for pre-transaction hooks'))
		}
		mut engine := hooks.new_hook_engine(handle)
		engine.set_packages(pre_pkgs, []&util.Package{})
		engine.run_pre(pre_pkgs) or {
			eprintln(warn('pre-transaction hook failed: ${err}'))
		}
	}

	mut errors := []string{}
	mut installed_pkgs := []&db.Package{}
	for _, pkgfile in pkgfiles {
		pkgmeta := archive.load_pkg_full(pkgfile) or { errors << pkgfile + ': ' + err.msg(); continue }
		mut db_pkg := &db.Package{
			filename: pkgfile
			name: pkgmeta.name
			name_hash: db.compute_name_hash(pkgmeta.name)
			version: pkgmeta.version
			base: pkgmeta.base
			desc: pkgmeta.desc
			url: pkgmeta.url
			packager: pkgmeta.packager
			arch: pkgmeta.arch
			build_date: pkgmeta.build_date
			isize: pkgmeta.isize
			licenses: pkgmeta.licenses
			groups: pkgmeta.groups
			scriptlet: pkgmeta.scriptlet
			origin: .local_db
		}
		for b in pkgmeta.backup { db_pkg.backup << db.BackupFile{name: b.name, hash: b.hash} }
		for f in pkgmeta.files.files { db_pkg.files.files << db.FileInfo{name: f.name, size: f.size, mode: f.mode} }
		// Copy dependency metadata from archive — required for future
		// -R, -Qd, -Qi, and dep resolution on the installed package.
		for d in pkgmeta.depends      { db_pkg.depends << db.Dependency{
			name: d.name, version: d.version, desc: d.desc, modifier: db.DepMod(d.modifier), name_hash: d.name_hash } }
		for d in pkgmeta.optdepends   { db_pkg.optdepends << db.Dependency{
			name: d.name, version: d.version, desc: d.desc, modifier: db.DepMod(d.modifier), name_hash: d.name_hash } }
		for d in pkgmeta.conflicts    { db_pkg.conflicts << db.Dependency{
			name: d.name, version: d.version, desc: d.desc, modifier: db.DepMod(d.modifier), name_hash: d.name_hash } }
		for d in pkgmeta.provides     { db_pkg.provides << db.Dependency{
			name: d.name, version: d.version, desc: d.desc, modifier: db.DepMod(d.modifier), name_hash: d.name_hash } }
		for d in pkgmeta.replaces     { db_pkg.replaces << db.Dependency{
			name: d.name, version: d.version, desc: d.desc, modifier: db.DepMod(d.modifier), name_hash: d.name_hash } }
		for d in pkgmeta.makedepends  { db_pkg.makedepends << db.Dependency{
			name: d.name, version: d.version, desc: d.desc, modifier: db.DepMod(d.modifier), name_hash: d.name_hash } }
		for d in pkgmeta.checkdepends { db_pkg.checkdepends << db.Dependency{
			name: d.name, version: d.version, desc: d.desc, modifier: db.DepMod(d.modifier), name_hash: d.name_hash } }
		old_pkg := if existing := local_db.pkgcache[pkgmeta.name] { existing } else { none }
		println(heading('Installing ${pkgmeta.name}...'))
		trans.install_package(handle, mut db_pkg, old_pkg) or { errors << pkgfile + ': ' + err.msg(); continue }
		local_db.pkgcache[db_pkg.name] = db_pkg
		installed_pkgs << db_pkg

		// Run per-package post-install hooks.
		if handle.hookedirs.len > 0 {
			mut engine := hooks.new_hook_engine(handle)
			util_pkgs := [&util.Package{
				name:    db_pkg.name
				version: db_pkg.version
				files:   pkg_file_names(db_pkg)
			}]
			engine.set_packages(util_pkgs, []&util.Package{})
			engine.run_post(util_pkgs) or {
				eprintln(warn('post-install hook for ${db_pkg.name} failed: ${err}'))
			}
		}
	}
	// Run post-transaction hooks.
	if handle.hookedirs.len > 0 {
		mut engine := hooks.new_hook_engine(handle)
		mut util_pkgs := []&util.Package{}
		for p in installed_pkgs {
			util_pkgs << &util.Package{
				name:    p.name
				version: p.version
				files:   pkg_file_names(p)
			}
		}
		engine.set_packages(util_pkgs, []&util.Package{})
		engine.run_post(util_pkgs) or {
			eprintln(warn('post-transaction hook failed: ${err}'))
		}
	}
	if errors.len > 0 {
		if installed_pkgs.len > 0 {
			eprintln(warn('${installed_pkgs.len} package(s) installed successfully, ${errors.len} failed'))
		}
		return error('failed: ' + errors.join('; '))
	}
	println(heading('done'))
}

fn confirm_upgrade(pkgfiles []string, local_db &db.LocalDB, noconfirm bool) bool {
	if noconfirm { return true }
	println('')
	println('Packages to upgrade:')
	for pf in pkgfiles {
		pkgmeta := archive.load_pkg_full(pf) or {
			println('  ${pf}')
			continue
		}
		if old := local_db.pkgcache[pkgmeta.name] {
			println('  ${pkg(pkgmeta.name)} ${installed('[installed: ${old.version}]')} ${arrow()} ${new_pkg(pkgmeta.version)}')
		} else {
			println('  ${new_pkg(pkgmeta.name)} ${light_pink}${pkgmeta.version}${reset}')
		}
	}
	println('')
	print('Proceed with installation? [Y/n] ')
	r := os.input('').trim_space().to_lower()
	return r == '' || r == 'y' || r == 'yes'
}
