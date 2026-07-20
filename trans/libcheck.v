// Module: trans/libcheck — library-level dependency checking.
//
// When --libs is passed, this module builds a reverse index of shared
// library provides across all sync databases and resolves implicit
// library-level dependencies that may not be captured by explicit
// package-level depends declarations.
//
// Example: if package A links against libfoo.so and package B provides
// libfoo.so but A does not explicitly depend on B, --libs will add B
// to the install targets.
//
// Reference: Arch Linux shared library packaging conventions
//   — packages list .so files in their %PROVIDES% metadata
module trans

import db
import os

// LibCheck holds the reverse index of library provides across sync
// databases and performs library-level dependency resolution.
pub struct LibCheck {
pub mut:
	// lib_index maps a stripped soname (e.g. "libc.so") to the set of
	// package names that provide it.
	lib_index map[string][]string
	// cache_path is the filesystem path to the libcheck cache file.
	cache_path string
	// cache_entries maps package name → cached provider list.
	cache_entries map[string][]string
	// cache_loaded is true if the cache has been read from disk.
	cache_loaded bool
	// cache_dirty is true if cache_entries have been modified since load.
	cache_dirty bool
}

// new_lib_check creates a LibCheck by scanning all sync databases and
// building a library-to-package reverse index from each package's
// provides field.
//
// Library provides in Arch packages follow the format:
//   libfoo.so
//   libfoo.so=1-64
//   libfoo.so=1
//
// The soname is extracted by stripping the version constraint suffix.
pub fn new_lib_check(syncdbs []&db.Database) LibCheck {
	mut lc := LibCheck{
		lib_index:     map[string][]string{}
		cache_entries: map[string][]string{}
		cache_loaded:  false
		cache_dirty:   false
	}

	for sdb in syncdbs {
		for _, pkg in sdb.pkgcache {
			for prov in pkg.provides {
				soname := extract_soname(prov.name)
				if soname != '' {
					lc.lib_index[soname] << pkg.name
				}
			}
		}
	}

	// Deduplicate entries in each lib_index value.
	// Collect keys first to avoid map mutation during iteration.
	mut keys := []string{cap: lc.lib_index.len}
	for soname, _ in lc.lib_index {
		keys << soname
	}
	for soname in keys {
		lc.lib_index[soname] = dedup_strings(lc.lib_index[soname])
	}

	return lc
}

// resolve_libs takes a list of target package names and the sync databases
// and returns additional package names that should be installed to satisfy
// library-level dependencies.
//
// Algorithm:
//   1. For each target, look up its package in the sync DBs.
//   2. For each dependency of that package, find the providing package.
//   3. For each providing package, check what libraries it provides.
//   4. For each library provided, check if another package also provides
//      that library but isn't in the install set — add it as a candidate.
//   5. Cross-check: for every candidate, verify it's actually needed by
//      scanning its own library provides and checking if any target links
//      against any of them.
//
// Returns: []string of additional package names to install (may be empty).
pub fn (lc &LibCheck) resolve_libs(targets []string, syncdbs []&db.Database) []string {
	if targets.len == 0 || lc.lib_index.len == 0 {
		return []
	}

	mut to_add := map[string]bool{}
	mut seen := map[string]bool{}
	for t in targets {
		seen[t] = true
	}

	// Phase 1: For each target, trace its dependency chain and discover
	// library-level providers that might be missing.
	for target in targets {
		// Find the target package in sync DBs.
		target_pkg := find_pkg_in_syncdbs(target, syncdbs) or {
			eprintln('warning: libcheck: target ${target} not in sync DBs, skipping')
			continue
		}

		// Check each direct dependency of the target.
		for dep in target_pkg.depends {
			dep_pkg := find_pkg_in_syncdbs(dep.name, syncdbs) or {
				eprintln('warning: libcheck: dep ${dep.name} not in sync DBs, skipping')
				continue
			}

			// For each library this dependency provides, check if any
			// OTHER package also provides it. If so, that other package
			// may be an alternative provider that should be included.
			for prov in dep_pkg.provides {
				soname := extract_soname(prov.name)
				if soname == '' {
					continue
				}
				providers := lc.lib_index[soname] or { continue }
				for provider in providers {
					if !seen[provider] && provider != dep.name {
						to_add[provider] = true
					}
				}
			}
		}
	}

	// Phase 2: For each candidate, verify that it is actually relevant
	// by checking if it provides a library that any target needs.
	// A target "needs" a library if one of its dependencies provides
	// that same library (indicating the target links against it).
	mut verified := []string{}
	for candidate, _ in to_add {
		cand_pkg := find_pkg_in_syncdbs(candidate, syncdbs) or { continue }

		// Check what libraries this candidate provides.
		for prov in cand_pkg.provides {
			soname := extract_soname(prov.name)
			if soname == '' {
				continue
			}
			// Check if any target package's dependency chain references
			// this soname (i.e., a dep provides the same library).
			if is_soname_needed_by_targets(soname, targets, syncdbs) {
				verified << candidate
				seen[candidate] = true
				break
			}
		}
	}

	return verified
}

// resolve_libs_deep performs a deeper library-level resolution that
// recursively follows library provide chains to find all implicit
// library dependencies. This is more thorough but more expensive.
//
// Returns: []string of package names to add, sorted topologically.
pub fn (lc &LibCheck) resolve_libs_deep(targets []string, syncdbs []&db.Database) []string {
	mut to_add := map[string]bool{}
	mut seen := map[string]bool{}
	mut added := []string{}
	for t in targets {
		seen[t] = true
	}

	// Iteratively expand: for every package in the seen set, check its
	// library provides against the index and add missing co-providers.
	// Repeat until no new packages are added.
	mut changed := true
	for changed {
		changed = false
		// Collect current packages to check (from sync DBs).
		mut current_pkgs := map[string]&db.Package{}
		for name, _ in seen {
			if p := find_pkg_in_syncdbs(name, syncdbs) {
				current_pkgs[name] = p
			}
		}

		for _, pkg in current_pkgs {
			// Libraries this package provides.
			for prov in pkg.provides {
				soname := extract_soname(prov.name)
				if soname == '' {
					continue
				}
				providers := lc.lib_index[soname] or { continue }
				for provider in providers {
					if !seen[provider] {
						seen[provider] = true
						to_add[provider] = true
						changed = true
					}
				}
			}
		}
	}

	// Build result from to_add in deterministic order.
	for candidate, _ in to_add {
		added << candidate
	}
	added.sort()
	return added
}

// resolve_libs_reverse implements Approach #3 — reverse-depends map.
//
// Instead of finding packages that PROVIDE the same libraries (co-providers),
// this finds packages that DEPEND on the same things as the targets.
// If package B depends on the same libraries as the install set, B may be
// a relevant provider that should be included.
//
// Algorithm:
//   1. Collect all depends names from target packages into set D.
//   2. For each d ∈ D, scan ALL sync DB packages to find those that ALSO
//      depend on d.
//   3. Filter out packages already in the install set.
//   4. Return unique package names, sorted.
//
// Returns: []string of additional package names to install (may be empty).
pub fn (lc &LibCheck) resolve_libs_reverse(targets []string, syncdbs []&db.Database) []string {
	if targets.len == 0 {
		return []
	}

	// Phase 1: Collect the set of all dependency names from target packages.
	mut dep_set := map[string]bool{}
	mut seen_targets := map[string]bool{}
	for t in targets {
		seen_targets[t] = true
		target_pkg := find_pkg_in_syncdbs(t, syncdbs) or { continue }
		for dep in target_pkg.depends {
			dep_set[dep.name] = true
		}
	}

	if dep_set.len == 0 {
		return []
	}

	// Phase 2: For each dep in the set, find all packages that also
	// depend on it.  Accumulate candidates (packages that share at least
	// one dependency with the targets).
	mut candidate_hits := map[string]int{} // package → shared dep count
	for sdb in syncdbs {
		for _, pkg in sdb.pkgcache {
			if seen_targets[pkg.name] {
				continue // already in the install set
			}
			for dep in pkg.depends {
				if dep_set[dep.name] {
					candidate_hits[pkg.name] = candidate_hits[pkg.name] + 1
				}
			}
		}
	}

	if candidate_hits.len == 0 {
		return []
	}

	// Phase 3: Verify candidates against the library index — only keep
	// those that provide at least one library relevant to the targets.
	mut verified := []string{}
	for candidate, _ in candidate_hits {
		cand_pkg := find_pkg_in_syncdbs(candidate, syncdbs) or { continue }
		for prov in cand_pkg.provides {
			soname := extract_soname(prov.name)
			if soname == '' {
				continue
			}
			if is_soname_needed_by_targets(soname, targets, syncdbs) {
				verified << candidate
				seen_targets[candidate] = true
				break
			}
		}
	}

	verified.sort()
	return verified
}

// ---------------------------------------------------------------------------
// ldconfig-based library resolution (--extreme-libs / Approach #4)
// ---------------------------------------------------------------------------

// resolve_libs_ldconfig cross-references the system's ldconfig cache against
// the sync DB provides index to find library providers that may be missing
// from the install set.
//
// This shells out to `ldconfig -p` to get the current system's library
// state, then cross-references each soname against the lib_index built
// from sync DB provides entries.
//
// Caveat: this only reflects the CURRENT system state — it cannot predict
// library needs on a different system or chroot.
//
// Returns: []string of additional package names to install (may be empty).
pub fn (lc &LibCheck) resolve_libs_ldconfig(targets []string, syncdbs []&db.Database) []string {
	ldconfig_output := run_ldconfig() or {
		eprintln('warning: ldconfig failed — ${err}')
		return []
	}
	if ldconfig_output == '' {
		return []
	}

	system_libs := parse_ldconfig_output(ldconfig_output)
	if system_libs.len == 0 {
		return []
	}

	mut seen := map[string]bool{}
	for t in targets {
		seen[t] = true
	}

	// For each target, find what libraries it needs from its dependency
	// chain, and check if those libraries are on the system but not yet
	// accounted for by any package in the install set.
	mut to_add := map[string]bool{}
	for target in targets {
		target_pkg := find_pkg_in_syncdbs(target, syncdbs) or { continue }
		for dep in target_pkg.depends {
			dep_pkg := find_pkg_in_syncdbs(dep.name, syncdbs) or { continue }
			for prov in dep_pkg.provides {
				soname := extract_soname(prov.name)
				if soname == '' {
					continue
				}
				// If this library is on the system...
				if _ := system_libs[soname] {
					// ...find which packages provide it (from sync DBs)
					providers := lc.lib_index[soname] or { continue }
					for provider in providers {
						if !seen[provider] {
							to_add[provider] = true
						}
					}
				}
			}
		}
	}

	mut result := []string{}
	for name, _ in to_add {
		result << name
	}
	result.sort()
	return result
}

// run_ldconfig executes `ldconfig -p` and returns its stdout.
// Returns an error if ldconfig is not available.
fn run_ldconfig() !string {
	result := os.execute('timeout 30 ldconfig -p')
	if result.exit_code != 0 {
		return error('ldconfig failed (exit ${result.exit_code}): ${result.output}\nstderr: ${result.output}')
	}
	return result.output
}

// parse_ldconfig_output parses the output of `ldconfig -p` into a map
// of soname → filesystem path.
//
// ldconfig -p output format:
//   3917 libs found in cache `/etc/ld.so.cache'
//       libfoo.so (libc6,x86-64) => /usr/lib/libfoo.so
//       libbar.so.1 (libc6) => /usr/lib/libbar.so.1
//
// Each library entry begins with a tab, has the soname, optional ABI
// tags in parentheses, and a => arrow pointing to the on-disk path.
fn parse_ldconfig_output(output string) map[string][]string {
	mut result := map[string][]string{}
	for line in output.split_into_lines() {
		trimmed := line.trim_space()
		if trimmed.len == 0 || !trimmed.contains(' => ') {
			continue
		}
		// Split on " => " (space-arrow-space).
		arrow_idx := trimmed.index(' => ') or { continue }
		left := trimmed[..arrow_idx].trim_space()
		right := trimmed[arrow_idx + 4..].trim_space()

		if left.len == 0 || right.len == 0 {
			continue
		}

		// Strip ABI tags from the soname: "libfoo.so (libc6,x86-64)" → "libfoo.so"
		soname := if paren_idx := left.index(' (') {
			left[..paren_idx]
		} else {
			left
		}

		if soname != '' {
			result[soname] << right
		}
	}
	return result
}

// ---------------------------------------------------------------------------
// Cache subsystem — speeds up --libs by caching per-package results.
// Cache is invalidated when sync DB files are newer than the cache file.
// --extreme-libs always bypasses the cache for maximum accuracy.
// ---------------------------------------------------------------------------

// init_cache sets the cache file path and loads existing cache entries.
// dbpath should be the resolved database path (e.g. /var/lib/ace/).
pub fn (mut lc LibCheck) init_cache(dbpath string) ! {
	lc.cache_path = os.join_path(dbpath, 'cache', 'libcheck_cache')
	if !os.exists(os.dir(lc.cache_path)) {
		os.mkdir_all(os.dir(lc.cache_path)) or {}
	}
	lc.load_cache()
}

// load_cache reads the cache file from disk into cache_entries.
fn (mut lc LibCheck) load_cache() {
	lc.cache_entries = map[string][]string{}
	lc.cache_loaded = true
	lc.cache_dirty = false

	if lc.cache_path == '' || !os.exists(lc.cache_path) {
		return
	}

	data := os.read_file(lc.cache_path) or { return }
	for line in data.split_into_lines() {
		trimmed := line.trim_space()
		// Skip comments and empty lines.
		if trimmed.len == 0 || trimmed[0] == `#` {
			continue
		}
		// Format: pkgname=provider1,provider2,...
		if eq_idx := trimmed.index('=') {
			pkgname := trimmed[..eq_idx].trim_space()
			providers_str := trimmed[eq_idx + 1..].trim_space()
			if providers_str.len > 0 {
				lc.cache_entries[pkgname] = providers_str.split(',')
			} else {
				lc.cache_entries[pkgname] = []
			}
		}
	}
}

// save_cache writes cache_entries to the cache file on disk.
fn (mut lc LibCheck) save_cache() {
	if !lc.cache_dirty || lc.cache_path == '' {
		return
	}

	mut lines := []string{cap: lc.cache_entries.len + 1}
	lines << '# ace libcheck cache v1 — auto-generated'
	for pkgname, providers in lc.cache_entries {
		if providers.len > 0 {
			lines << '${pkgname}=${providers.join(",")}'
		} else {
			lines << '${pkgname}='
		}
	}

	os.write_file(lc.cache_path, lines.join('\n') + '\n') or {
		eprintln('warning: failed to write libcheck cache: ${err}')
	}
	lc.cache_dirty = false
}

// is_cache_valid checks whether the cache is still valid by comparing
// its modification time against the newest sync DB file.
// If any sync DB was updated since the cache was written, the cache
// is considered stale and should be regenerated.
fn (lc &LibCheck) is_cache_valid() bool {
	if lc.cache_path == '' || !os.exists(lc.cache_path) {
		return false
	}
	cache_stat := os.stat(lc.cache_path) or { return false }
	cache_mtime := cache_stat.mtime

	// Check if any of the syncdb files are newer than the cache.
	// The sync DBs live in {dbpath}/sync/{repo}.db.
	dbpath := os.dir(os.dir(lc.cache_path))
	sync_dir := os.join_path(dbpath, 'sync')
	if !os.exists(sync_dir) {
		return false
	}
	entries := os.ls(sync_dir) or { return false }
	for entry in entries {
		if !entry.ends_with('.db') {
			continue
		}
		db_path := os.join_path(sync_dir, entry)
		db_stat := os.stat(db_path) or { continue }
		if db_stat.mtime > cache_mtime {
			return false // sync DB is newer — cache is stale
		}
	}
	return true
}

// cache_hit returns the cached provider list for a package, or none.
fn (lc &LibCheck) cache_hit(pkgname string) ?[]string {
	if !lc.cache_loaded || pkgname !in lc.cache_entries {
		return none
	}
	return lc.cache_entries[pkgname]
}

// cache_store records a resolution result for a package.
fn (mut lc LibCheck) cache_store(pkgname string, providers []string) {
	if !lc.cache_loaded {
		return
	}
	lc.cache_entries[pkgname] = providers
	lc.cache_dirty = true
}

// resolve_libs_cached is the --libs fast path.  It checks the cache
// first for each target and only resolves uncached packages.  Results
// are stored back to the cache for future runs.
pub fn (mut lc LibCheck) resolve_libs_cached(targets []string, syncdbs []&db.Database) []string {
	if targets.len == 0 || lc.lib_index.len == 0 {
		return []
	}

	cache_valid := lc.is_cache_valid()
	mut uncached := []string{}
	mut result := []string{}

	// Phase 1: check cache for each target.
	for target in targets {
		if cache_valid {
			if cached := lc.cache_hit(target) {
				result << cached
				continue
			}
		}
		uncached << target
	}

	// Phase 2: resolve uncached packages.
	if uncached.len > 0 {
		deep_result := lc.resolve_libs_deep(uncached, syncdbs)
		reverse_result := lc.resolve_libs_reverse(uncached, syncdbs)
		result << deep_result
		result << reverse_result

		// Cache the combined result per uncached package.
		// Build a fresh cache entry that includes both deep and reverse results.
		if cache_valid || lc.cache_loaded {
			for target in uncached {
				// Find providers that specifically relate to this target.
				mut providers := []string{}
				for p in deep_result {
					if !providers_contains(providers, p) {
						providers << p
					}
				}
				for p in reverse_result {
					if !providers_contains(providers, p) {
						providers << p
					}
				}
				lc.cache_store(target, providers)
			}
			lc.save_cache()
		}
	}

	return dedup_strings(result)
}

// resolve_libs_ldconfig_uncached is the --extreme-libs implementation
// that ALWAYS runs fresh — bypassing the cache entirely for maximum
// accuracy regardless of speed.
pub fn (lc &LibCheck) resolve_libs_ldconfig_uncached(targets []string, syncdbs []&db.Database) []string {
	return lc.resolve_libs_ldconfig(targets, syncdbs)
}

// providers_contains is a helper that checks whether a string is in
// a slice, used during cache deduplication.
fn providers_contains(haystack []string, needle string) bool {
	for item in haystack {
		if item == needle {
			return true
		}
	}
	return false
}

// extract_soname strips version suffix from a library provide name.
// "libfoo.so=1-64" → "libfoo.so", "libc.so" → "libc.so", "" → ""
fn extract_soname(name string) string {
	if name.len == 0 {
		return ''
	}
	// Must contain ".so" to be a shared library (case-insensitive).
	if !name.to_lower().contains('.so') {
		return ''
	}
	// Strip "=version" suffix, then re-check the result.
	if eq_idx := name.index('=') {
		result := name[..eq_idx]
		if !result.contains('.so') {
			return ''
		}
		return result
	}
	return name
}

// find_pkg_in_syncdbs looks up a package by name across all sync databases.
fn find_pkg_in_syncdbs(name string, syncdbs []&db.Database) ?&db.Package {
	for sdb in syncdbs {
		if p := sdb.pkgcache[name] {
			return p
		}
	}
	return none
}

// is_soname_needed_by_targets checks whether any target package's dependency
// chain includes a package that provides the given soname.
fn is_soname_needed_by_targets(soname string, targets []string, syncdbs []&db.Database) bool {
	for target in targets {
		target_pkg := find_pkg_in_syncdbs(target, syncdbs) or { continue }
		for dep in target_pkg.depends {
			dep_pkg := find_pkg_in_syncdbs(dep.name, syncdbs) or { continue }
			for prov in dep_pkg.provides {
				if extract_soname(prov.name) == soname {
					return true
				}
			}
		}
	}
	return false
}

// dedup_strings removes duplicate strings from a slice while preserving order.
fn dedup_strings(items []string) []string {
	mut seen := map[string]bool{}
	mut result := []string{}
	for item in items {
		if !seen[item] {
			seen[item] = true
			result << item
		}
	}
	return result
}
