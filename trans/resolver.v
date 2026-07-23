// Module: trans — transaction-level operations for the ace package manager.
//
// sort_by_deps performs a DFS-based topological sort on a list of packages,
// with cycle detection and break handling matching pacman's behavior.
//
// Reference: pacman/lib/libalpm/deps.c:104-279, graph.h, graph.c
module trans

import db
import util

// SortMode determines the ordering strategy for sort_by_deps.
pub enum SortMode {
	install // dependencies appear before their dependents
	remove  // dependents appear before their dependencies
}

// VertexState tracks DFS traversal state for cycle detection.
// unprocessed → processing → processed
enum VertexState {
	unprocessed
	processing
	processed
}

// dep_satisfies checks whether a package satisfies a given dependency.
// A package satisfies a dependency when:
//   - its name matches the dependency name and the version constraint is met, or
//   - one of its provides matches the dependency name and the version constraint is met.
//
// Reference: pacman's _alpm_dep_satisfies (deps.c).
pub fn dep_satisfies(pkg &db.Package, dep &db.Dependency) bool {
	// check_ver returns true if candidate_ver satisfies the dependency constraint.
	check_ver := fn (candidate_ver string, dep_ver string, mod db.DepMod) bool {
		if mod == .any || dep_ver == '' {
			return true
		}
		cmp := util.vercmp(candidate_ver, dep_ver)
		return match mod {
			.eq { cmp == 0 }
			.ge { cmp >= 0 }
			.le { cmp <= 0 }
			.gt { cmp > 0 }
			.lt { cmp < 0 }
			.any { true }
		}
	}

	// Direct name match.
	if pkg.name == dep.name && check_ver(pkg.version, dep.version, dep.modifier) {
		return true
	}

	// Provides match — check each entry in pkg.provides.
	for prov in pkg.provides {
		if prov.name == dep.name && check_ver(prov.version, dep.version, dep.modifier) {
			return true
		}
	}

	return false
}

// sort_by_deps performs a topological sort on a list of packages.
//
// For install mode: dependencies appear before their dependents
// (so package A depending on B yields result order [...B, A...]).
//
// For remove mode: dependents appear before their dependencies
// (so package A depending on B yields result order [...A, B...]).
//
// On cycle detection the function warns via eprintln and breaks the cycle by
// treating one back-edge as satisfied (matching pacman's behavior).  The
// function never aborts or returns an error for cycles.
//
// Reference: pacman's _alpm_sortbydeps (deps.c:104-279).
pub fn sort_by_deps(pkgs []&db.Package, mode SortMode) ?[]&db.Package {
	if pkgs.len == 0 {
		return []&db.Package{}
	}

	// Build a name-to-index map for O(1) lookups.
	mut name_to_idx := map[string]int{}
	for i, pkg in pkgs {
		name_to_idx[pkg.name] = i
	}

	// Build adjacency: edge i → j means package i depends on package j.
	// Dependencies not present in the input list are silently ignored.
	mut adj := [][]int{len: pkgs.len}
	mut seen := map[string]bool{}

	for i, pkg in pkgs {
		// Reset seen set for dedup within a single package's depends.
		seen.clear()

	for dep in pkg.depends {
		// Direct name match in the input list.
		if dep.name in name_to_idx {
			j := name_to_idx[dep.name]
			if j != i && dep.name !in seen {
				seen[dep.name] = true
				adj[i] << j
			}
			continue
		}

			// Provides match: check if any package in the list provides this dep.
			for j, other in pkgs {
				if i == j {
					continue
				}
				for prov in other.provides {
					if prov.name == dep.name && dep.name !in seen {
						seen[dep.name] = true
						adj[i] << j
					}
				}
			}
		}
	}

	mut state := []VertexState{len: pkgs.len}
	for i in 0 .. state.len {
		state[i] = .unprocessed
	}
	mut result := []&db.Package{}

	for i in 0..pkgs.len {
		if state[i] == .unprocessed {
			dfs(i, pkgs, adj, mut state, mut result)
		}
	}

	// For remove mode the standard post-order result is reversed: we want
	// dependents (packages that depend on others) to appear before their
	// dependencies.
	if mode == .remove {
		mut reversed := unsafe { []&db.Package{len: result.len} }
		for i in 0..result.len {
			reversed[result.len - 1 - i] = result[i]
		}
		return reversed
	}

	return result
}

// dfs performs a single DFS traversal rooted at idx.
// Standard post-order: children (dependencies) are visited and committed
// before the current vertex, producing the install order.
fn dfs(idx int, pkgs []&db.Package, adj [][]int, mut state []VertexState, mut result []&db.Package) {
	if state[idx] == .processed {
		return
	}
	if state[idx] == .processing {
		eprintln(color_warn('dependency cycle detected, breaking at ${pkgs[idx].name}'))
		return
	}

	state[idx] = .processing

	for neighbor in adj[idx] {
		if state[neighbor] != .processed {
			dfs(neighbor, pkgs, adj, mut state, mut result)
		}
	}

	state[idx] = .processed
	result << pkgs[idx]
}

// ---------------------------------------------------------------------------
// resolve_deps — recursive dependency resolution
// Reference: pacman/lib/libalpm/deps.c:636-863, sync.c:367-507
// ---------------------------------------------------------------------------

// ProviderChoice records which provider package was selected to satisfy a
// given dependency when the matched package name differs from the dependency
// name (i.e. provides-based resolution).
pub struct ProviderChoice {
pub:
	dep      db.Dependency
	provider &db.Package
}

// ResolveResult holds the complete outcome of a dependency resolution pass.
pub struct ResolveResult {
pub:
	resolved         []&db.Package // packages in topological order (leaves first)
	unresolved       []string       // dependency specifiers that could not be satisfied
	provider_choices []ProviderChoice
}

// ResolveHandle carries resolution configuration: lists of packages or groups
// to ignore, and packages assumed to be already installed (virtual / external).
pub struct ResolveHandle {
pub:
	ignorepkgs       []string
	ignoregroups     []string
	assume_installed []string
	// Pre-built index: virtual provider name → packages that provide it
	// in the local database.  Built once after localdb.populate() to
	// avoid O(N) linear scans in satisfied_by_localdb.
	local_provides   map[string][]&db.Package
}

// resolve_deps resolves all transitive dependencies for the given target
// package names by searching the provided sync databases.
//
// Parameters:
//   handle   — resolution options (ignore lists, assumed-installed)
//   targets  — package names to resolve (the "root" targets of the transaction)
//   syncdbs  — sync database instances to search (ordered; first wins for
//              literal name matches and provider ordering)
//   localdb  — local (installed) database; used to short-circuit deps that
//              are already satisfied by an installed package
//
// Returns a ResolveResult on success (even if some deps are unresolved;
// check .unresolved for failures). Returns none only on internal error.
pub fn resolve_deps(handle &ResolveHandle, targets []string, syncdbs []&db.Database,
	localdb &db.Database) ?ResolveResult {
	// Build a hash map from the providing virtual name -> list of packages
	// that provide it.  This gives O(1) provider lookups instead of scanning
	// every package for every dependency.
	provider_map := build_provider_map(syncdbs)

	mut resolved := []&db.Package{}
	mut unresolved := []string{}
	mut provider_choices := []ProviderChoice{}
	mut visited := map[string]bool{}

	for target in targets {
		if target in visited {
			continue
		}
		if is_assume_installed(handle, target) {
			visited[target] = true
			continue
		}

		// Treat the bare target name as a dep with no version constraint.
		target_dep := db.Dependency{
			name:      target
			modifier:  .any
			name_hash: db.compute_name_hash(target)
		}

		pkg := find_satisfier_in_dbs(target_dep, syncdbs, provider_map, localdb,
			visited) or {
			unresolved << target
			continue
		}

		if is_ignored(handle, pkg, syncdbs) {
			unresolved << target
			continue
		}

		resolve_pkg(handle, pkg, syncdbs, localdb, provider_map, mut resolved,
			mut unresolved, mut provider_choices, mut visited)
	}

	return ResolveResult{
		resolved:         resolved
		unresolved:       unresolved
		provider_choices: provider_choices
	}
}

// ---------------------------------------------------------------------------
// Internal helpers for resolve_deps
// ---------------------------------------------------------------------------

// _build_provider_map scans all sync databases and builds a name -> []&Package
// map from every package's `provides` list. This enables O(1) provider
// lookups during recursive resolution.
fn build_provider_map(syncdbs []&db.Database) map[string][]&db.Package {
	mut pmap := map[string][]&db.Package{}
	for sdb in syncdbs {
		for _, pkg in sdb.pkgcache {
			for prov in pkg.provides {
				if prov.name !in pmap {
					pmap[prov.name] = []&db.Package{}
				}
				unsafe {
					pmap[prov.name] << pkg
				}
			}
		}
	}
	return pmap
}

// resolve_pkg recursively resolves a single package and its transitive
// dependencies. The package is appended to `resolved` only after all of its
// own dependencies have been processed, yielding topological ordering
// (leaves first, dependents last).
fn resolve_pkg(
	handle &ResolveHandle,
	pkg &db.Package,
	syncdbs []&db.Database,
	localdb &db.Database,
	provider_map map[string][]&db.Package,
	mut resolved []&db.Package,
	mut unresolved []string,
	mut provider_choices []ProviderChoice,
	mut visited map[string]bool,
) {
	if pkg.name in visited {
		return
	}
	visited[pkg.name] = true

	for dep in pkg.depends {
		// Already satisfied by a package already in the resolved set.
		if satisfied_by_list(dep, resolved) {
			continue
		}
		// Already satisfied by an installed (local) package.
		if satisfied_by_localdb(dep, localdb, handle.local_provides) {
			continue
		}
		// Assumed installed / virtual package -- no action needed.
		if is_assume_installed(handle, dep.name) {
			continue
		}

		satisfier := find_satisfier_in_dbs(dep, syncdbs, provider_map, localdb,
			visited) or {
			unresolved << dep.to_string()
			continue
		}

		if is_ignored(handle, satisfier, syncdbs) {
			unresolved << dep.to_string()
			continue
		}

		// Record a provider choice when the satisfier's name differs from the
		// dependency name (i.e. it satisfied via `provides` rather than literal).
		if satisfier.name != dep.name {
			provider_choices << ProviderChoice{
				dep:      dep
				provider: satisfier
			}
		}

		resolve_pkg(handle, satisfier, syncdbs, localdb, provider_map,
			mut resolved, mut unresolved, mut provider_choices, mut visited)
	}

	resolved << pkg
}

// find_satisfier_in_dbs searches the sync databases for a package that
// satisfies the given dependency.
//
// Lookup order:
//  1. Literal name match in each sync DB (first DB wins, O(1) via pkgcache).
//  2. Providers (hash-map backed, O(1)) -- the `provides` list of every package
//     in every sync DB, filtered through dep_satisfies.
//
// Among multiple providers, pick_provider applies the selection policy
// (prefer already-installed, otherwise first in DB order).
fn find_satisfier_in_dbs(dep db.Dependency, syncdbs []&db.Database,
	provider_map map[string][]&db.Package, localdb &db.Database,
	excluding map[string]bool) ?&db.Package {
	// 1. Literal match -- check for a package whose name equals dep.name.
	for sdb in syncdbs {
		if pkg := sdb.pkgcache[dep.name] {
			if pkg.name !in excluding && dep_satisfies(pkg, &dep) {
				return pkg
			}
		}
	}

	// 2. Provider match -- packages that provide a virtual name matching dep.name.
	if providers_list := provider_map[dep.name] {
		mut candidates := []&db.Package{}
		for pkg in providers_list {
			if pkg.name !in excluding && dep_satisfies(pkg, &dep) {
				candidates << pkg
			}
		}
		if candidates.len > 0 {
			return pick_provider(candidates, localdb)
		}
	}

	return none
}

// pick_provider selects one provider from a list of candidates.
// Selection priority:
//  1. Already installed in the local database.
//  2. First in candidate order (which follows DB order from the sync-db list).
fn pick_provider(providers []&db.Package, localdb &db.Database) &db.Package {
	// Prefer an already-installed package.
	for pkg in providers {
		if pkg.name in localdb.pkgcache {
			return pkg
		}
	}
	// Otherwise return the first candidate (DB-order).
	return providers[0]
}

// satisfied_by_list checks whether any package already in the resolved
// (or transaction) list satisfies the given dependency.
fn satisfied_by_list(dep db.Dependency, resolved []&db.Package) bool {
	for pkg in resolved {
		if dep_satisfies(pkg, &dep) {
			return true
		}
	}
	return false
}

// satisfied_by_localdb checks whether an installed package in the local
// database satisfies the given dependency.  Uses the pre-built
// local_provides index for O(1) provider lookup when available;
// falls back to O(N) linear scan when the index is empty (not populated).
fn satisfied_by_localdb(dep db.Dependency, localdb &db.Database, local_provides map[string][]&db.Package) bool {
	if pkg := localdb.pkgcache[dep.name] {
		return dep_satisfies(pkg, &dep)
	}
	// Use pre-built index if available (O(1) per lookup).
	if local_provides.len > 0 {
		if providers := local_provides[dep.name] {
			for pkg in providers {
				if dep_satisfies(pkg, &dep) {
					return true
				}
			}
		}
		return false
	}
	// Fallback: linear scan of all installed packages (O(N)).
	for _, pkg in localdb.pkgcache {
		for prov in pkg.provides {
			if prov.name_hash == dep.name_hash && prov.name == dep.name {
				if dep_satisfies(pkg, &dep) {
					return true
				}
			}
		}
	}
	return false
}

// is_ignored checks whether a package matches any entry in the IgnorePkg
// or IgnoreGroup lists carried by the handle.
fn is_ignored(handle &ResolveHandle, pkg &db.Package, syncdbs []&db.Database) bool {
	// IgnorePkg -- exact package name match.
	for ip in handle.ignorepkgs {
		if ip == pkg.name {
			return true
		}
	}
	// IgnoreGroup -- the package belongs to an ignored group.
	for ig in handle.ignoregroups {
		for sdb in syncdbs {
			if group := sdb.grpcache[ig] {
				for gpkg_name in group.packages {
					if gpkg_name == pkg.name {
						return true
					}
				}
			}
		}
	}
	return false
}

// is_assume_installed checks whether a package name is in the
// AssumeInstalled list (treated as already satisfied without looking it up).
fn is_assume_installed(handle &ResolveHandle, name string) bool {
	for ai in handle.assume_installed {
		if ai == name {
			return true
		}
	}
	return false
}

// ============================================================================
// Phase 3 — Dependency comparison engine
// Reference: pacman/lib/libalpm/deps.c:74-212
// ============================================================================

// ---------------------------------------------------------------------------
// fnmatch — simple glob pattern matching for IgnorePkg/IgnoreGroup
// ---------------------------------------------------------------------------

// fnmatch checks whether `name` matches the glob `pattern`.
// Supports `*` (any sequence of characters) and `?` (any single character),
// matching pacman's use of fnmatch(3) for IgnorePkg/IgnoreGroup.
pub fn fnmatch(pattern string, name string) bool {
	mut pi := 0
	mut ni := 0
	mut star_idx := -1
	mut match_idx := 0

	for ni < name.len {
		if pi < pattern.len && (pattern[pi] == name[ni] || pattern[pi] == `?`) {
			pi++
			ni++
		} else if pi < pattern.len && pattern[pi] == `*` {
			star_idx = pi
			match_idx = ni
			pi++
		} else if star_idx != -1 {
			pi = star_idx + 1
			match_idx++
			ni = match_idx
		} else {
			return false
		}
	}

	// Consume any trailing `*` in the pattern.
	for pi < pattern.len && pattern[pi] == `*` {
		pi++
	}

	return pi == pattern.len
}

// ---------------------------------------------------------------------------
// find_satisfier — find a package satisfying a dep string in a list
// ---------------------------------------------------------------------------

// find_satisfier searches `pkgs` for a package that satisfies the dependency
// string `dep_str` (e.g. "glibc>=2.35").  Returns the first matching package,
// or `none`.
//
// Reference: pacman alpm_find_satisfier() at deps.c:289-298.
pub fn find_satisfier(pkgs []&db.Package, dep_str string) ?&db.Package {
	dep := db.Dependency.from_string(dep_str) or {
		return none
	}
	for pkg in pkgs {
		if dep_satisfies(pkg, &dep) {
			return pkg
		}
	}
	return none
}

// ---------------------------------------------------------------------------
// find_dbs_satisfier — find a package satisfying a dep across databases
// ---------------------------------------------------------------------------

// find_dbs_satisfier searches multiple databases for a package satisfying
// `dep_str`.  It first searches for literal name matches in each database,
// then falls back to provides-based matches.  Databases are searched in
// order, so callers should arrange them with local/installed databases first.
//
// Provider selection priority (applied externally via db ordering):
//   (1) already in transaction
//   (2) explicit target
//   (3) currently installed (local db)
//   (4) first in sync DB order
//
// Reference: pacman alpm_find_dbs_satisfier() at deps.c:751-765,
//           resolvedep() at deps.c:636-749.
pub fn find_dbs_satisfier(dbs []&db.Database, dep_str string) ?&db.Package {
	dep := db.Dependency.from_string(dep_str) or {
		return none
	}

	// 1. Literal matches in each database.
	for database in dbs {
		if pkg := database.pkgcache[dep.name] {
			if dep_satisfies(pkg, &dep) {
				return pkg
			}
		}
	}

	// 2. Provides-based matches (skip packages already matched by literal).
	for database in dbs {
		for _, pkg in database.pkgcache {
			if pkg.name_hash == dep.name_hash && pkg.name == dep.name {
				continue
			}
			if dep_satisfies(pkg, &dep) {
				return pkg
			}
		}
	}

	return none
}

// ---------------------------------------------------------------------------
// pkg_in_list — check if a package name exists in a package list
// ---------------------------------------------------------------------------

// pkg_in_list checks whether a package with the given `name` exists in `pkgs`.
fn pkg_in_list(name string, pkgs []&db.Package) bool {
	for p in pkgs {
		if p.name == name {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// issatisfied_by_list — check if any package in a list satisfies a dep
// ---------------------------------------------------------------------------

// issatisfied_by_list checks whether any package in `pkgs` satisfies `dep`.
fn issatisfied_by_list(dep &db.Dependency, pkgs []&db.Package) bool {
	for pkg in pkgs {
		if dep_satisfies(pkg, dep) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// find_causing_pkg — find the package in modified that satisfies a dep
// ---------------------------------------------------------------------------

// find_causing_pkg returns the name of the first package in `modified` that
// satisfies `dep`, or `none` if none do.
fn find_causing_pkg(dep &db.Dependency, modified []&db.Package) ?string {
	for pkg in modified {
		if dep_satisfies(pkg, dep) {
			return pkg.name
		}
	}
	return none
}

// ---------------------------------------------------------------------------
// check_deps — full transaction dependency check
// ---------------------------------------------------------------------------

// check_deps performs a full dependency check for a transaction.
//
// It partitions `local_pkgs` into "modified" (packages present in `remove` or
// `upgrade`) and "unmodified" (the rest).  For each package in `upgrade`, it
// checks that every dependency is satisfied by either the upgrade list or the
// unmodified packages.  When `reversedeps` is true, it also checks that
// unmodified packages' dependencies are not broken by the removal or upgrade
// of their current satisfiers.
//
// Returns a list of missing dependencies.  An empty list means all
// dependencies are satisfied.
//
// Reference: pacman alpm_checkdeps() at deps.c:300-390.
pub fn check_deps(_handle &util.Handle, local_pkgs []&db.Package, remove []&db.Package,
	upgrade []&db.Package, reversedeps bool) ?[]db.DepMissing {
	// Partition local packages into modified (in remove/upgrade) and unmodified.
	mut dblist := []&db.Package{}
	mut modified := []&db.Package{}

	for pkg in local_pkgs {
		if pkg_in_list(pkg.name, remove) || pkg_in_list(pkg.name, upgrade) {
			modified << pkg
		} else {
			dblist << pkg
		}
	}

	mut baddeps := []db.DepMissing{}

	// 1. Check dependencies of each package in the upgrade list.
	//    For each dep, look for a satisfier first in the upgrade list, then
	//    in the unmodified database list (dblist).
	for tp in upgrade {
		for i in 0 .. tp.depends.len {
			dep := &tp.depends[i]
			if !issatisfied_by_list(dep, upgrade) && !issatisfied_by_list(dep,
				dblist) {
				baddeps << db.DepMissing{
					target:      tp.name
					depend:      dep
					causing_pkg: ''
				}
			}
		}
	}

	// 2. Reverse dependency check: ensure unmodified packages' dependencies
	//    are not broken by the transaction.  We look for a "causing" package
	//    in the modified list (remove or upgrade) that currently satisfies
	//    the dependency.  If that dependency would no longer be satisfied
	//    after the transaction, it is a broken dependency.
	if reversedeps {
		for lp in dblist {
			for i in 0 .. lp.depends.len {
				dep := &lp.depends[i]
				if causing := find_causing_pkg(dep, modified) {
					if !issatisfied_by_list(dep, upgrade) &&
						!issatisfied_by_list(dep, dblist) {
						baddeps << db.DepMissing{
							target:      lp.name
							depend:      dep
							causing_pkg: causing
						}
					}
				}
			}
		}
	}

	return baddeps
}

// ---------------------------------------------------------------------------
// pkg_should_ignore — check if a package is ignored via IgnorePkg/IgnoreGroup
// ---------------------------------------------------------------------------

// pkg_should_ignore checks whether a package should be ignored based on
// IgnorePkg and IgnoreGroup lists, using fnmatch glob matching for each
// pattern.  A package is ignored if its name matches any IgnorePkg pattern,
// or if any of its groups matches an IgnoreGroup pattern.
//
// Reference: pacman alpm_pkg_should_ignore().
pub fn pkg_should_ignore(pkg &db.Package, ignorepkgs []string, ignoregroups []string) bool {
	for pattern in ignorepkgs {
		if fnmatch(pattern, pkg.name) {
			return true
		}
	}
	for pattern in ignoregroups {
		for group in pkg.groups {
			if fnmatch(pattern, group) {
				return true
			}
		}
	}
	return false
}
