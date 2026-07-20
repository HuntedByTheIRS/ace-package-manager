// -T (deptest) subcommand — check if packages satisfy each other's dependencies.
//
// Reference: pacman/src/pacman/deptest.c
module cli

import config
import db
import os
import util

// run_deptest executes the -T operation for the given targets. For each target
// (package name or dependency spec like "glibc>=2.35"), it checks whether an
// installed package satisfies it — either via a direct package-name lookup or
// via a satisfiability check against the full package cache (including
// provides).  Unsatisfied targets are printed to stdout (one per line) and the
// process exits with code 127, matching pacman's behaviour (exit 0 = all
// satisfied).
pub fn run_deptest(args &CliArgs, cfg &config.Config, handle &util.Handle) ! {
	dbpath := if args.root != '' {
		os.join_path(args.root, if args.dbpath != '' { args.dbpath } else { 'var/lib/ace' })
	} else if args.dbpath != '' {
		args.dbpath
	} else {
		handle.resolved_dbpath()
	}

	mut local_db := db.init(dbpath)!
	local_db.populate()!

	// Build a name → &Package map for O(1) lookups and cache scanning.
	mut pkgcache_map := map[string]&db.Package{}
	for pkg in local_db.get_pkgcache() {
		pkgcache_map[pkg.name] = pkg
	}

	mut unsatisfied := []string{}

	for target in args.targets {
		if !is_target_satisfied(pkgcache_map, target) {
			unsatisfied << target
		}
	}

	if unsatisfied.len == 0 {
		return
	}

	for dep in unsatisfied {
		println(dep)
	}
	exit(127)
}

// ---------------------------------------------------------------------------
// Internal helpers — satisfiability checks
// ---------------------------------------------------------------------------

// is_target_satisfied returns true when `target` (a package name or dependency
// spec) is satisfied by at least one installed package. It performs two
// checks matching pacman's deptest logic:
//
//  1. Direct package-name lookup  (alpm_db_get_pkg)
//  2. Dependency satisfier search (alpm_find_satisfier)
//
fn is_target_satisfied(pkgcache map[string]&db.Package, target string) bool {
	// Step 1: direct package-name lookup (alpm_db_get_pkg equivalent).
	if target in pkgcache {
		return true
	}

	// Step 2: parse as a dependency string and look for a satisfier
	// (alpm_find_satisfier equivalent).
	dep := db.Dependency.from_string(target) or { return false }

	for _, pkg in pkgcache {
		// Check by package name.
		if pkg.name == dep.name {
			if dep.modifier == .any || version_match(util.vercmp(pkg.version, dep.version),
				dep.modifier) {
				return true
			}
		}

		// Check by provides — a package may provide the dependency under a
		// different name (e.g. "hello" provides "greeter").
		for prov in pkg.provides {
			if prov.name == dep.name {
				if dep.modifier == .any {
					return true
				}
				// Use the provides entry's own version if present, otherwise
				// fall back to the package version.
				prov_ver := if prov.version != '' { prov.version } else { pkg.version }
				if version_match(util.vercmp(prov_ver, dep.version), dep.modifier) {
					return true
				}
			}
		}
	}

	return false
}

// version_match reports whether the vercmp result `cmp` satisfies the given
// dependency modifier (e.g. >=, <=, =).
fn version_match(cmp int, modifier db.DepMod) bool {
	return match modifier {
		.eq { cmp == 0 }
		.ge { cmp >= 0 }
		.le { cmp <= 0 }
		.gt { cmp > 0 }
		.lt { cmp < 0 }
		.any { true }
	}
}
