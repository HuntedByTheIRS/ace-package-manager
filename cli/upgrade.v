module cli

import archive
import config
import db
import hooks
import os
import trans
import util

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
	for target in args.targets {
		if os.exists(target) && !os.is_dir(target) && target.contains('.pkg.tar') {
			pkgfiles << target
		} else if os.is_dir(target) {
			entries := os.ls(target) or { return error('cannot list dir: ' + err.msg()) }
			for entry in entries { if entry.contains('.pkg.tar') { pkgfiles << os.join_path(target, entry) } }
		} else { return error('target not found: ' + target) }
	}
	if pkgfiles.len == 0 { return error('no valid package files') }
	if args.print {
		println('Target packages to install/upgrade:')
		for pf in pkgfiles { println('  ' + pf) }
		return
	}
	if !confirm_upgrade(pkgfiles, args.noconfirm) { println('cancelled'); return }
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
		trans.install_package(handle, mut db_pkg, old_pkg) or { errors << pkgfile + ': ' + err.msg(); continue }
		local_db.pkgcache[db_pkg.name] = db_pkg
		installed_pkgs << db_pkg
	}
	// Run post-transaction hooks.
	if handle.hookedirs.len > 0 {
		mut engine := hooks.new_hook_engine(handle)
		mut util_pkgs := []&util.Package{}
		for p in installed_pkgs {
			util_pkgs << &util.Package{name: p.name, version: p.version}
		}
		engine.set_packages(util_pkgs, []&util.Package{})
		engine.run_post(util_pkgs) or {
			eprintln('warning: post-transaction hook failed: ${err}')
		}
	}
	if errors.len > 0 { return error('failed: ' + errors.join('; ')) }
}

fn confirm_upgrade(pkgfiles []string, noconfirm bool) bool {
	if noconfirm { return true }
	println('')
	println('Packages to upgrade:')
	for pf in pkgfiles { println('  ' + pf) }
	println('')
	print('Proceed with installation? [Y/n] ')
	r := os.input('').trim_space().to_lower()
	return r == '' || r == 'y' || r == 'yes'
}
