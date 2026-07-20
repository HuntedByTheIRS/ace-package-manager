module trans

import db
import util

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_pkg(name string, deps []string) &db.Package {
	mut depends := []db.Dependency{}
	for d in deps {
		dep := db.Dependency.from_string(d) or {
			db.Dependency{
				name:      d
				modifier:  .any
				name_hash: db.compute_name_hash(d)
			}
		}
		depends << dep
	}
	return &db.Package{
		name:      name
		version:   '1.0'
		depends:   depends
		name_hash: db.compute_name_hash(name)
	}
}

fn make_pkg_with_ver(name string, version string, deps []string) &db.Package {
	mut depends := []db.Dependency{}
	for d in deps {
		dep := db.Dependency.from_string(d) or {
			db.Dependency{
				name:      d
				modifier:  .any
				name_hash: db.compute_name_hash(d)
			}
		}
		depends << dep
	}
	return &db.Package{
		name:      name
		version:   version
		depends:   depends
		name_hash: db.compute_name_hash(name)
	}
}

fn make_pkg_provides(name string, deps []string, provides []string) &db.Package {
	mut depends := []db.Dependency{}
	for d in deps {
		dep := db.Dependency.from_string(d) or {
			db.Dependency{
				name:      d
				modifier:  .any
				name_hash: db.compute_name_hash(d)
			}
		}
		depends << dep
	}
	mut prov_deps := []db.Dependency{}
	for p in provides {
		prov_dep := db.Dependency.from_string(p) or {
			db.Dependency{
				name:      p
				modifier:  .any
				name_hash: db.compute_name_hash(p)
			}
		}
		prov_deps << prov_dep
	}
	return &db.Package{
		name:      name
		version:   '1.0'
		depends:   depends
		provides:  prov_deps
		name_hash: db.compute_name_hash(name)
	}
}

fn pkg_names(pkgs []&db.Package) string {
	mut names := []string{}
	for p in pkgs {
		names << p.name
	}
	return names.join(', ')
}

fn assert_order(result []&db.Package, expected []string, tc_name string) {
	assert result.len == expected.len, '${tc_name}: expected ${expected.len} packages, got ${result.len}'
	got := pkg_names(result)
	exp_str := expected.join(', ')
	assert got == exp_str, '${tc_name}: expected [${exp_str}], got [${got}]'
	// Also verify all expected names are present
	for name in expected {
		mut found := false
		for p in result {
			if p.name == name {
				found = true
				break
			}
		}
		assert found, '${tc_name}: missing package ${name} in result'
	}
}

// ---------------------------------------------------------------------------
// sort_by_deps
// ---------------------------------------------------------------------------

fn test_sort_by_deps_empty() {
	result := sort_by_deps([], .install) or { panic('unexpected error: ${err}') }
	assert result.len == 0
}

fn test_sort_by_deps_single() {
	a := make_pkg('A', [])
	result := sort_by_deps([a], .install) or { panic('unexpected error: ${err}') }
	assert result.len == 1
	assert result[0].name == 'A'
}

fn test_sort_by_deps_linear_install() {
	// A depends on B, B depends on C
	// Install mode: dependencies first → C, B, A
	a := make_pkg('A', ['B'])
	b := make_pkg('B', ['C'])
	c := make_pkg('C', [])
	pkgs := [a, b, c]
	result := sort_by_deps(pkgs, .install) or { panic('unexpected error: ${err}') }
	assert_order(result, ['C', 'B', 'A'], 'linear install')
}

fn test_sort_by_deps_linear_remove() {
	// A depends on B, B depends on C
	// Remove mode: dependents first → A, B, C
	a := make_pkg('A', ['B'])
	b := make_pkg('B', ['C'])
	c := make_pkg('C', [])
	pkgs := [a, b, c]
	result := sort_by_deps(pkgs, .remove) or { panic('unexpected error: ${err}') }
	assert_order(result, ['A', 'B', 'C'], 'linear remove')
}

fn test_sort_by_deps_no_deps() {
	// No dependencies — order is determined by iteration (stable-ish)
	a := make_pkg('A', [])
	b := make_pkg('B', [])
	c := make_pkg('C', [])
	pkgs := [a, b, c]
	result := sort_by_deps(pkgs, .install) or { panic('unexpected error: ${err}') }
	assert result.len == 3
	// Only guarantee: all three are present
	mut names := map[string]bool{}
	for p in result {
		names[p.name] = true
	}
	assert names['A'] && names['B'] && names['C']
}

fn test_sort_by_deps_diamond() {
	// A→B, A→C, B→D, C→D
	// Install: D must be before B and C; B and C before A
	a := make_pkg('A', ['B', 'C'])
	b := make_pkg('B', ['D'])
	c := make_pkg('C', ['D'])
	d := make_pkg('D', [])
	pkgs := [a, b, c, d]
	result := sort_by_deps(pkgs, .install) or { panic('unexpected error: ${err}') }

	// D must be first, A last, B and C before A
	assert result[0].name == 'D', 'diamond install: D should be first, got ${result[0].name}'
	assert result[result.len - 1].name == 'A', 'diamond install: A should be last, got ${result[result.len - 1].name}'
	// B and C are somewhere in the middle
	mut b_pos := -1
	mut c_pos := -1
	mut a_pos := -1
	mut d_pos := -1
	for i, p in result {
		match p.name {
			'A' { a_pos = i }
			'B' { b_pos = i }
			'C' { c_pos = i }
			'D' { d_pos = i }
			else {}
		}
	}
	assert d_pos < b_pos, 'diamond install: D (pos ${d_pos}) must be before B (pos ${b_pos})'
	assert d_pos < c_pos, 'diamond install: D (pos ${c_pos}) must be before C (pos ${c_pos})'
	assert b_pos < a_pos, 'diamond install: B (pos ${b_pos}) must be before A (pos ${a_pos})'
	assert c_pos < a_pos, 'diamond install: C (pos ${c_pos}) must be before A (pos ${a_pos})'
}

fn test_sort_by_deps_cycle() {
	// A→B→C→A — cycle
	// Should warn and break the cycle, still return all packages
	a := make_pkg('A', ['B'])
	b := make_pkg('B', ['C'])
	c := make_pkg('C', ['A'])
	pkgs := [a, b, c]
	result := sort_by_deps(pkgs, .install) or { panic('unexpected error: ${err}') }
	assert result.len == 3, 'cycle: expected 3 packages, got ${result.len}'
	mut names := map[string]bool{}
	for p in result {
		names[p.name] = true
	}
	assert names['A'] && names['B'] && names['C'], 'cycle: missing packages in result'
	// No duplicate names
	mut seen := map[string]int{}
	for p in result {
		seen[p.name]++
	}
	for name, count in seen {
		assert count == 1, 'cycle: duplicate ${name} appears ${count} times'
	}
}

fn test_sort_by_deps_self_loop() {
	// A→A (self-loop should be ignored)
	a := make_pkg('A', ['A'])
	pkgs := [a]
	result := sort_by_deps(pkgs, .install) or { panic('unexpected error: ${err}') }
	assert result.len == 1
	assert result[0].name == 'A'
}

fn test_sort_by_deps_external_dep() {
	// A depends on B, but B is NOT in the list
	// External deps are silently ignored
	a := make_pkg('A', ['B'])
	pkgs := [a]
	result := sort_by_deps(pkgs, .install) or { panic('unexpected error: ${err}') }
	assert result.len == 1
	assert result[0].name == 'A'
}

fn test_sort_by_deps_provides() {
	// A depends on 'libfoo', C provides 'libfoo'
	// Install: C must come before A
	a := make_pkg('A', ['libfoo'])
	b := make_pkg('B', [])
	c := make_pkg_provides('C', [], ['libfoo'])
	pkgs := [a, b, c]
	result := sort_by_deps(pkgs, .install) or { panic('unexpected error: ${err}') }
	assert result.len == 3
	// C must be before A
	mut c_pos := -1
	mut a_pos := -1
	for i, p in result {
		if p.name == 'C' {
			c_pos = i
		}
		if p.name == 'A' {
			a_pos = i
		}
	}
	assert c_pos >= 0, 'provides: C not found in result'
	assert a_pos >= 0, 'provides: A not found in result'
	assert c_pos < a_pos, 'provides: C (pos ${c_pos}) must be before A (pos ${a_pos})'
}

fn test_sort_by_deps_remove_cycle() {
	// A→B→C→A with remove mode
	// Should warn and break, all packages present
	a := make_pkg('A', ['B'])
	b := make_pkg('B', ['C'])
	c := make_pkg('C', ['A'])
	pkgs := [a, b, c]
	result := sort_by_deps(pkgs, .remove) or { panic('unexpected error: ${err}') }
	assert result.len == 3
	mut names := map[string]bool{}
	for p in result {
		names[p.name] = true
	}
	assert names['A'] && names['B'] && names['C']
	// No duplicates
	mut seen := map[string]int{}
	for p in result {
		seen[p.name]++
	}
	for name, count in seen {
		assert count == 1, 'remove cycle: duplicate ${name} appears ${count} times'
	}
}

// ---------------------------------------------------------------------------
// dep_satisfies
// ---------------------------------------------------------------------------

fn test_dep_satisfies_direct_match() {
	pkg := make_pkg('glibc', [])
	dep := db.Dependency{
		name:      'glibc'
		modifier:  .any
		name_hash: db.compute_name_hash('glibc')
	}
	assert dep_satisfies(pkg, dep)
}

fn test_dep_satisfies_direct_name_mismatch() {
	pkg := make_pkg('glibc', [])
	dep := db.Dependency{
		name:      'systemd'
		modifier:  .any
		name_hash: db.compute_name_hash('systemd')
	}
	assert !dep_satisfies(pkg, dep)
}

fn test_dep_satisfies_provides_match() {
	pkg := make_pkg_provides('myapp', [], ['libfoo'])
	dep := db.Dependency{
		name:      'libfoo'
		modifier:  .any
		name_hash: db.compute_name_hash('libfoo')
	}
	assert dep_satisfies(pkg, dep)
}

fn test_dep_satisfies_version_eq() {
	pkg := make_pkg_with_ver('glibc', '2.35', [])
	dep := db.Dependency{
		name:      'glibc'
		version:   '2.35'
		modifier:  .eq
		name_hash: db.compute_name_hash('glibc')
	}
	assert dep_satisfies(pkg, dep)

	dep_wrong := db.Dependency{
		name:      'glibc'
		version:   '2.36'
		modifier:  .eq
		name_hash: db.compute_name_hash('glibc')
	}
	assert !dep_satisfies(pkg, dep_wrong)
}

fn test_dep_satisfies_version_ge() {
	pkg := make_pkg_with_ver('glibc', '2.35', [])
	// 2.35 >= 2.35 ✓
	dep := db.Dependency{
		name:      'glibc'
		version:   '2.35'
		modifier:  .ge
		name_hash: db.compute_name_hash('glibc')
	}
	assert dep_satisfies(pkg, dep)

	// 2.35 >= 2.34 ✓
	dep_lower := db.Dependency{
		name:      'glibc'
		version:   '2.34'
		modifier:  .ge
		name_hash: db.compute_name_hash('glibc')
	}
	assert dep_satisfies(pkg, dep_lower)

	// 2.35 >= 2.36 ✗
	dep_higher := db.Dependency{
		name:      'glibc'
		version:   '2.36'
		modifier:  .ge
		name_hash: db.compute_name_hash('glibc')
	}
	assert !dep_satisfies(pkg, dep_higher)
}

fn test_dep_satisfies_provides_version() {
	pkg := &db.Package{
		name:      'myapp'
		version:   '1.0'
		provides:  [db.Dependency{name: 'libfoo', version: '1.5', modifier: .eq, name_hash: db.compute_name_hash('libfoo')}]
		name_hash: db.compute_name_hash('myapp')
	}
	// Version constraint on the provides
	dep := db.Dependency{
		name:      'libfoo'
		version:   '1.5'
		modifier:  .eq
		name_hash: db.compute_name_hash('libfoo')
	}
	assert dep_satisfies(pkg, dep)

	dep_wrong := db.Dependency{
		name:      'libfoo'
		version:   '2.0'
		modifier:  .eq
		name_hash: db.compute_name_hash('libfoo')
	}
	assert !dep_satisfies(pkg, dep_wrong)
}

fn test_dep_satisfies_any_version() {
	pkg := make_pkg_with_ver('glibc', '2.35', [])
	// any modifier + empty version means any version is OK
	dep := db.Dependency{
		name:      'glibc'
		version:   ''
		modifier:  .any
		name_hash: db.compute_name_hash('glibc')
	}
	assert dep_satisfies(pkg, dep)
}

// ---------------------------------------------------------------------------
// Helpers for resolve_deps tests
// ---------------------------------------------------------------------------

fn make_db_with(pkgs []&db.Package) &db.Database {
	mut pkgcache := map[string]&db.Package{}
	for p in pkgs {
		pkgcache[p.name] = p
	}
	return &db.Database{
		pkgcache: pkgcache
		grpcache: map[string]db.Group{}
	}
}

fn new_handle() &ResolveHandle {
	return &ResolveHandle{}
}

fn make_simple_dep(name string) db.Dependency {
	return db.Dependency{
		name:      name
		modifier:  .any
		name_hash: db.compute_name_hash(name)
	}
}

fn make_ver_dep(name string, modifier db.DepMod, version string) db.Dependency {
	return db.Dependency{
		name:      name
		version:   version
		modifier:  modifier
		name_hash: db.compute_name_hash(name)
	}
}

// ---------------------------------------------------------------------------
// resolve_deps — basic resolution
// ---------------------------------------------------------------------------

fn test_resolve_deps_basic() {
	// Build: pkg-A depends on pkg-B>=1.0 and pkg-C
	//        pkg-B depends on pkg-D
	//        pkg-C and pkg-D have no deps
	// Expected topological order (leaves first): pkg-D, pkg-B, pkg-C, pkg-A
	pkg_d := &db.Package{
		name:      'pkg-D'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-D')
	}
	pkg_b := &db.Package{
		name:      'pkg-B'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-B')
		depends:   [make_simple_dep('pkg-D')]
	}
	pkg_c := &db.Package{
		name:      'pkg-C'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-C')
	}
	pkg_a := &db.Package{
		name:      'pkg-A'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-A')
		depends:   [make_ver_dep('pkg-B', .ge, '1.0'), make_simple_dep('pkg-C')]
	}

	sdb := make_db_with([pkg_a, pkg_b, pkg_c, pkg_d])
	localdb := make_db_with([])
	handle := new_handle()

	result := resolve_deps(handle, ['pkg-A'], [sdb], localdb) or {
		assert false, 'resolve_deps failed: ${err}'
		return
	}

	// Check topological order: leaves first
	got := result.resolved
	assert got.len == 4, 'expected 4 resolved, got ${got.len}'

	// Verify all expected names present
	mut names := []string{}
	for p in got {
		names << p.name
	}
	assert 'pkg-D' in names
	assert 'pkg-B' in names
	assert 'pkg-C' in names
	assert 'pkg-A' in names

	// Verify topological invariants:
	// pkg-D before pkg-B  (B depends on D)
	// pkg-B before pkg-A  (A depends on B)
	// pkg-C before pkg-A  (A depends on C)
	mut d_pos := -1
	mut b_pos := -1
	mut c_pos := -1
	mut a_pos := -1
	for i, p in got {
		match p.name {
			'pkg-D' { d_pos = i }
			'pkg-B' { b_pos = i }
			'pkg-C' { c_pos = i }
			'pkg-A' { a_pos = i }
			else {}
		}
	}
	assert d_pos < b_pos, 'pkg-D should be before pkg-B'
	assert b_pos < a_pos, 'pkg-B should be before pkg-A'
	assert c_pos < a_pos, 'pkg-C should be before pkg-A'

	assert result.unresolved.len == 0, 'expected no unresolved, got ${result.unresolved}'
}

fn test_resolve_deps_multiple_targets() {
	// Resolving both pkg-A and pkg-D directly should produce a complete set
	// without duplicates.
	pkg_d := &db.Package{
		name:      'pkg-D'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-D')
	}
	pkg_b := &db.Package{
		name:      'pkg-B'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-B')
		depends:   [make_simple_dep('pkg-D')]
	}
	pkg_c := &db.Package{
		name:      'pkg-C'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-C')
	}
	pkg_a := &db.Package{
		name:      'pkg-A'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-A')
		depends:   [make_simple_dep('pkg-B'), make_simple_dep('pkg-C')]
	}

	sdb := make_db_with([pkg_a, pkg_b, pkg_c, pkg_d])
	localdb := make_db_with([])
	handle := new_handle()

	result := resolve_deps(handle, ['pkg-A', 'pkg-D'], [sdb], localdb) or {
		assert false, 'resolve_deps failed: ${err}'
		return
	}

	// No duplicates — pkg-D should appear only once.
	mut seen := map[string]int{}
	for p in result.resolved {
		seen[p.name]++
	}
	for name, count in seen {
		assert count == 1, 'duplicate ${name} appears ${count} times'
	}

	assert result.unresolved.len == 0
}

fn test_resolve_deps_leaf_target() {
	// Resolving a leaf package (no deps) returns just that package.
	pkg_d := &db.Package{
		name:      'pkg-D'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-D')
	}

	sdb := make_db_with([pkg_d])
	localdb := make_db_with([])
	handle := new_handle()

	result := resolve_deps(handle, ['pkg-D'], [sdb], localdb) or {
		assert false, 'resolve_deps failed: ${err}'
		return
	}

	assert result.resolved.len == 1
	assert result.resolved[0].name == 'pkg-D'
	assert result.unresolved.len == 0
}

// ---------------------------------------------------------------------------
// resolve_deps — unresolved targets
// ---------------------------------------------------------------------------

fn test_resolve_deps_target_not_found() {
	sdb := make_db_with([])
	localdb := make_db_with([])
	handle := new_handle()

	result := resolve_deps(handle, ['nonexistent'], [sdb], localdb) or {
		assert false, 'resolve_deps failed: ${err}'
		return
	}

	assert result.resolved.len == 0
	assert result.unresolved.len == 1
	assert result.unresolved[0] == 'nonexistent'
}

// ---------------------------------------------------------------------------
// resolve_deps — IgnorePkg
// ---------------------------------------------------------------------------

fn test_resolve_deps_ignore_pkg() {
	pkg_a := &db.Package{
		name:      'pkg-A'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-A')
	}

	sdb := make_db_with([pkg_a])
	localdb := make_db_with([])
	handle := &ResolveHandle{
		ignorepkgs: ['pkg-A']
	}

	result := resolve_deps(handle, ['pkg-A'], [sdb], localdb) or {
		assert false, 'resolve_deps failed: ${err}'
		return
	}

	// pkg-A is in IgnorePkg, so it should appear in unresolved.
	assert result.resolved.len == 0, 'expected 0 resolved, got ${result.resolved.len}'
	assert result.unresolved.len == 1, 'expected 1 unresolved, got ${result.unresolved.len}'
	assert result.unresolved[0] == 'pkg-A'
}

fn test_resolve_deps_ignore_pkg_on_dep() {
	// pkg-A depends on pkg-B which is ignored.
	pkg_b := &db.Package{
		name:      'pkg-B'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-B')
	}
	pkg_a := &db.Package{
		name:      'pkg-A'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-A')
		depends:   [make_simple_dep('pkg-B')]
	}

	sdb := make_db_with([pkg_a, pkg_b])
	localdb := make_db_with([])
	handle := &ResolveHandle{
		ignorepkgs: ['pkg-B']
	}

	result := resolve_deps(handle, ['pkg-A'], [sdb], localdb) or {
		assert false, 'resolve_deps failed: ${err}'
		return
	}

	// pkg-A should still be resolved (it itself is not ignored),
	// but pkg-B's dep should be unresolved.
	assert result.resolved.len == 1
	assert result.resolved[0].name == 'pkg-A'
	assert result.unresolved.len == 1
	assert result.unresolved[0] == 'pkg-B'
}

fn test_resolve_deps_ignore_group() {
	pkg_a := &db.Package{
		name:      'pkg-A'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-A')
	}

	mut sdb := &db.Database{
		pkgcache: map[string]&db.Package{}
		grpcache: map[string]db.Group{}
	}
	sdb.pkgcache['pkg-A'] = pkg_a
	// Group 'test-group' contains pkg-A.
	sdb.grpcache['test-group'] = db.Group{
		name:     'test-group'
		packages: ['pkg-A']
	}

	localdb := make_db_with([])
	handle := &ResolveHandle{
		ignoregroups: ['test-group']
	}

	result := resolve_deps(handle, ['pkg-A'], [sdb], localdb) or {
		assert false, 'resolve_deps failed: ${err}'
		return
	}

	assert result.resolved.len == 0, 'expected 0 resolved, got ${result.resolved.len}'
	assert result.unresolved.len == 1, 'expected 1 unresolved, got ${result.unresolved.len}'
	assert result.unresolved[0] == 'pkg-A'
}

// ---------------------------------------------------------------------------
// resolve_deps — AssumeInstalled
// ---------------------------------------------------------------------------

fn test_resolve_deps_assume_installed_target() {
	// pkg-A is in AssumeInstalled -- should be treated as satisfied with
	// no need to search databases.
	sdb := make_db_with([])
	localdb := make_db_with([])
	handle := &ResolveHandle{
		assume_installed: ['pkg-A']
	}

	result := resolve_deps(handle, ['pkg-A'], [sdb], localdb) or {
		assert false, 'resolve_deps failed: ${err}'
		return
	}

	assert result.resolved.len == 0
	assert result.unresolved.len == 0
}

fn test_resolve_deps_assume_installed_dep() {
	// pkg-A depends on pkg-B which is in AssumeInstalled.
	pkg_a := &db.Package{
		name:      'pkg-A'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-A')
		depends:   [make_simple_dep('pkg-B')]
	}

	sdb := make_db_with([pkg_a])
	localdb := make_db_with([])
	handle := &ResolveHandle{
		assume_installed: ['pkg-B']
	}

	result := resolve_deps(handle, ['pkg-A'], [sdb], localdb) or {
		assert false, 'resolve_deps failed: ${err}'
		return
	}

	// pkg-A resolved, pkg-B assumed -- no unresolved deps.
	assert result.resolved.len == 1
	assert result.resolved[0].name == 'pkg-A'
	assert result.unresolved.len == 0
}

// ---------------------------------------------------------------------------
// resolve_deps — providers
// ---------------------------------------------------------------------------

fn test_resolve_deps_provider_selection() {
	// pkg-A depends on 'virtual-pkg'.
	// Both pkg-X and pkg-Y provide 'virtual-pkg'.
	// First in DB order (pkg-X) should be selected.
	pkg_x := &db.Package{
		name:      'pkg-X'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-X')
		provides:  [make_simple_dep('virtual-pkg')]
	}
	pkg_y := &db.Package{
		name:      'pkg-Y'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-Y')
		provides:  [make_simple_dep('virtual-pkg')]
	}
	pkg_a := &db.Package{
		name:      'pkg-A'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-A')
		depends:   [make_simple_dep('virtual-pkg')]
	}

	sdb := make_db_with([pkg_x, pkg_y, pkg_a])
	localdb := make_db_with([])
	handle := new_handle()

	result := resolve_deps(handle, ['pkg-A'], [sdb], localdb) or {
		assert false, 'resolve_deps failed: ${err}'
		return
	}

	// pkg-X should be selected (first in DB order).
	assert result.resolved.len == 2, 'expected 2 resolved, got ${result.resolved.len}'
	assert result.resolved[0].name == 'pkg-X', 'first resolved should be pkg-X, got ${result.resolved[0].name}'
	assert result.resolved[1].name == 'pkg-A', 'second resolved should be pkg-A, got ${result.resolved[1].name}'

	// Provider choice should be recorded.
	assert result.provider_choices.len == 1, 'expected 1 provider choice, got ${result.provider_choices.len}'
	assert result.provider_choices[0].dep.name == 'virtual-pkg'
	assert result.provider_choices[0].provider.name == 'pkg-X'
}

fn test_resolve_deps_provider_already_installed() {
	// pkg-A depends on 'virtual-pkg'.
	// Both pkg-X and pkg-Y provide it, but pkg-Y is installed.
	// pkg-Y should be preferred.
	pkg_x := &db.Package{
		name:      'pkg-X'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-X')
		provides:  [make_simple_dep('virtual-pkg')]
	}
	pkg_y := &db.Package{
		name:      'pkg-Y'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-Y')
		provides:  [make_simple_dep('virtual-pkg')]
	}
	pkg_a := &db.Package{
		name:      'pkg-A'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-A')
		depends:   [make_simple_dep('virtual-pkg')]
	}

	sdb := make_db_with([pkg_x, pkg_y, pkg_a])
	localdb := make_db_with([pkg_y])
	handle := new_handle()

	result := resolve_deps(handle, ['pkg-A'], [sdb], localdb) or {
		assert false, 'resolve_deps failed: ${err}'
		return
	}

	// pkg-Y should be preferred because it's installed.
	// Since pkg-Y is already installed (satisfied in localdb),
	// it should not be added as a dependency to resolve.
	assert result.resolved.len == 1, 'expected 1 resolved (only pkg-A), got ${result.resolved.len}'
	assert result.resolved[0].name == 'pkg-A'
}

fn test_resolve_deps_no_provider_choice_for_literal() {
	// When a dep is satisfied by a literal name match (not via provides),
	// no ProviderChoice is recorded.
	pkg_b := &db.Package{
		name:      'pkg-B'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-B')
	}
	pkg_a := &db.Package{
		name:      'pkg-A'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-A')
		depends:   [make_simple_dep('pkg-B')]
	}

	sdb := make_db_with([pkg_a, pkg_b])
	localdb := make_db_with([])
	handle := new_handle()

	result := resolve_deps(handle, ['pkg-A'], [sdb], localdb) or {
		assert false, 'resolve_deps failed: ${err}'
		return
	}

	assert result.provider_choices.len == 0, 'expected 0 provider choices for literal match, got ${result.provider_choices.len}'
}

// ---------------------------------------------------------------------------
// resolve_deps — version constraints
// ---------------------------------------------------------------------------

fn test_resolve_deps_version_ge() {
	pkg_b := &db.Package{
		name:      'pkg-B'
		version:   '2.0'
		name_hash: db.compute_name_hash('pkg-B')
	}
	pkg_a := &db.Package{
		name:      'pkg-A'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-A')
		depends:   [make_ver_dep('pkg-B', .ge, '1.0')]
	}

	sdb := make_db_with([pkg_a, pkg_b])
	localdb := make_db_with([])
	handle := new_handle()

	result := resolve_deps(handle, ['pkg-A'], [sdb], localdb) or {
		assert false, 'resolve_deps failed: ${err}'
		return
	}

	assert result.resolved.len == 2
	assert result.unresolved.len == 0
}

fn test_resolve_deps_version_too_low() {
	pkg_b := &db.Package{
		name:      'pkg-B'
		version:   '0.5'
		name_hash: db.compute_name_hash('pkg-B')
	}
	pkg_a := &db.Package{
		name:      'pkg-A'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-A')
		depends:   [make_ver_dep('pkg-B', .ge, '1.0')]
	}

	sdb := make_db_with([pkg_a, pkg_b])
	localdb := make_db_with([])
	handle := new_handle()

	result := resolve_deps(handle, ['pkg-A'], [sdb], localdb) or {
		assert false, 'resolve_deps failed: ${err}'
		return
	}

	// pkg-A resolved, but pkg-B's version (0.5) is too low → unresolved.
	assert result.unresolved.len == 1, 'expected 1 unresolved, got ${result.unresolved}'
	assert result.resolved.len == 1, 'expected 1 resolved (pkg-A), got ${result.resolved.len}'
}

// ---------------------------------------------------------------------------
// resolve_deps — already satisfied by local db
// ---------------------------------------------------------------------------

fn test_resolve_deps_satisfied_by_localdb() {
	// pkg-A depends on pkg-B, but pkg-B is already installed.
	pkg_b_installed := &db.Package{
		name:      'pkg-B'
		version:   '2.0'
		name_hash: db.compute_name_hash('pkg-B')
	}
	pkg_a := &db.Package{
		name:      'pkg-A'
		version:   '1.0'
		name_hash: db.compute_name_hash('pkg-A')
		depends:   [make_ver_dep('pkg-B', .ge, '1.0')]
	}

	sdb := make_db_with([pkg_a, pkg_b_installed])
	localdb := make_db_with([pkg_b_installed])
	handle := new_handle()

	result := resolve_deps(handle, ['pkg-A'], [sdb], localdb) or {
		assert false, 'resolve_deps failed: ${err}'
		return
	}

	// Only pkg-A should be in resolved (pkg-B is already installed).
	assert result.resolved.len == 1
	assert result.resolved[0].name == 'pkg-A'
	assert result.unresolved.len == 0
}

// ===========================================================================
// fnmatch tests
// ===========================================================================

fn test_fnmatch_exact() {
	assert fnmatch('glibc', 'glibc')
}

fn test_fnmatch_star() {
	assert fnmatch('glibc*', 'glibc-2.35')
	assert fnmatch('*glibc', 'my-glibc')
	assert fnmatch('*foo*', 'libfoo-dev')
	assert !fnmatch('bar*', 'foo')
}

fn test_fnmatch_question() {
	assert fnmatch('glibc-?.35', 'glibc-2.35')
	assert !fnmatch('glibc-?.35', 'glibc-2.35-1')
}

fn test_fnmatch_no_match() {
	assert !fnmatch('glibc', 'systemd')
	assert !fnmatch('foo*', 'bar')
}

fn test_fnmatch_empty_pattern() {
	assert fnmatch('', '')
	assert !fnmatch('', 'anything')
}

// ===========================================================================
// find_satisfier tests
// ===========================================================================

fn test_find_satisfier_found() {
	pkgs := [
		make_pkg('pkg-A', []),
		make_pkg('pkg-B', []),
	]
	result := find_satisfier(pkgs, 'pkg-A') or {
		assert false, 'expected to find pkg-A'
		return
	}
	assert result.name == 'pkg-A'
}

fn test_find_satisfier_not_found() {
	pkgs := [make_pkg('pkg-A', [])]
	if _ := find_satisfier(pkgs, 'pkg-C') {
		assert false, 'expected not to find pkg-C'
	}
}

fn test_find_satisfier_empty_list() {
	if _ := find_satisfier([], 'pkg-A') {
		assert false, 'expected not to find in empty list'
	}
}

fn test_find_satisfier_version_match() {
	pkgs := [make_pkg_with_ver('pkg-A', '2.0', [])]
	result := find_satisfier(pkgs, 'pkg-A>=1.0') or {
		assert false, 'expected to find pkg-A>=1.0'
		return
	}
	assert result.name == 'pkg-A'
}

fn test_find_satisfier_version_mismatch() {
	pkgs := [make_pkg_with_ver('pkg-A', '1.0', [])]
	if _ := find_satisfier(pkgs, 'pkg-A>=2.0') {
		assert false, 'expected not to match version 1.0 >= 2.0'
	}
}

fn test_find_satisfier_provides_match() {
	pkgs := [make_pkg_provides('provider', [], ['libfoo=1.5'])]
	result := find_satisfier(pkgs, 'libfoo>=1.0') or {
		assert false, 'expected to find via provides'
		return
	}
	assert result.name == 'provider'
}

fn test_find_satisfier_invalid_dep_str() {
	pkgs := [make_pkg('pkg-A', [])]
	if _ := find_satisfier(pkgs, '') {
		assert false, 'expected not to find with empty dep string'
	}
}

// ===========================================================================
// find_dbs_satisfier tests
// ===========================================================================

fn test_find_dbs_satisfier_literal_match() {
	db1 := make_db_with([make_pkg('pkg-A', [])])
	result := find_dbs_satisfier([db1], 'pkg-A') or {
		assert false, 'expected to find pkg-A'
		return
	}
	assert result.name == 'pkg-A'
}

fn test_find_dbs_satisfier_provides_match() {
	provider := make_pkg_provides('provider', [], ['libfoo'])
	db1 := make_db_with([provider])
	result := find_dbs_satisfier([db1], 'libfoo') or {
		assert false, 'expected to find via provides'
		return
	}
	assert result.name == 'provider'
}

fn test_find_dbs_satisfier_not_found() {
	db1 := make_db_with([make_pkg('pkg-A', [])])
	if _ := find_dbs_satisfier([db1], 'pkg-C') {
		assert false, 'expected not to find pkg-C'
	}
}

fn test_find_dbs_satisfier_multiple_dbs() {
	db1 := make_db_with([make_pkg('pkg-A', [])])
	db2 := make_db_with([make_pkg('pkg-B', [])])
	result := find_dbs_satisfier([db1, db2], 'pkg-B') or {
		assert false, 'expected to find pkg-B in second db'
		return
	}
	assert result.name == 'pkg-B'
}

fn test_find_dbs_satisfier_first_db_wins() {
	db1 := make_db_with([make_pkg_with_ver('pkg-A', '1.0', [])])
	db2 := make_db_with([make_pkg_with_ver('pkg-A', '2.0', [])])
	result := find_dbs_satisfier([db1, db2], 'pkg-A') or {
		assert false, 'expected to find pkg-A'
		return
	}
	assert result.name == 'pkg-A'
	assert result.version == '1.0' // first db wins
}

fn test_find_dbs_satisfier_empty_dbs() {
	if _ := find_dbs_satisfier([], 'pkg-A') {
		assert false, 'expected not to find in empty dbs'
	}
}

fn test_find_dbs_satisfier_invalid_dep_str() {
	db1 := make_db_with([make_pkg('pkg-A', [])])
	if _ := find_dbs_satisfier([db1], '') {
		assert false, 'expected not to find with empty dep string'
	}
}

// ===========================================================================
// check_deps tests
// ===========================================================================

fn test_check_deps_all_satisfied() {
	handle := &util.Handle{}
	a := make_pkg_with_ver('pkg-A', '1.0', ['pkg-B'])
	b := make_pkg_with_ver('pkg-B', '1.0', [])
	local_pkgs := [a, b]
	remove := []&db.Package{}
	upgrade := [a, b]
	result := check_deps(handle, local_pkgs, remove, upgrade, false) or {
		assert false, 'unexpected error: ${err}'
		return
	}
	assert result.len == 0, 'expected 0 missing deps, got ${result.len}'
}

fn test_check_deps_missing_dep() {
	handle := &util.Handle{}
	a := make_pkg_with_ver('pkg-A', '1.0', ['pkg-C'])
	// pkg-C is NOT in any list
	local_pkgs := [a]
	remove := []&db.Package{}
	upgrade := [a]
	result := check_deps(handle, local_pkgs, remove, upgrade, false) or {
		assert false, 'unexpected error: ${err}'
		return
	}
	assert result.len == 1, 'expected 1 missing dep, got ${result.len}'
	assert result[0].target == 'pkg-A'
}

fn test_check_deps_satisfied_by_dblist() {
	handle := &util.Handle{}
	a := make_pkg_with_ver('pkg-A', '1.0', ['pkg-B'])
	b := make_pkg_with_ver('pkg-B', '1.0', [])
	// pkg-B is in local_pkgs but NOT in upgrade → it's in dblist
	local_pkgs := [a, b]
	remove := []&db.Package{}
	upgrade := [a]
	result := check_deps(handle, local_pkgs, remove, upgrade, false) or {
		assert false, 'unexpected error: ${err}'
		return
	}
	assert result.len == 0, 'expected 0 missing deps (B is in dblist), got ${result.len}'
}

fn test_check_deps_reversedeps_break() {
	handle := &util.Handle{}
	b := make_pkg_with_ver('pkg-B', '1.0', ['pkg-A'])
	a := make_pkg_with_ver('pkg-A', '1.0', [])
	// pkg-B (dblist) depends on pkg-A, and we're removing pkg-A
	local_pkgs := [a, b]
	remove := [a]
	upgrade := []&db.Package{}
	result := check_deps(handle, local_pkgs, remove, upgrade, true) or {
		assert false, 'unexpected error: ${err}'
		return
	}
	assert result.len == 1, 'expected 1 broken dep, got ${result.len}'
	assert result[0].target == 'pkg-B'
	assert result[0].causing_pkg == 'pkg-A'
}

fn test_check_deps_reversedeps_no_break_dblist() {
	handle := &util.Handle{}
	b := make_pkg_with_ver('pkg-B', '2.0', ['pkg-A'])
	a := make_pkg_with_ver('pkg-A', '1.0', [])
	c := make_pkg_with_ver('pkg-C', '1.0', [])
	// pkg-B (dblist) depends on pkg-A, we're removing pkg-A
	// but pkg-C is also in dblist and satisfies the dep
	local_pkgs := [a, b, c]
	remove := [a]
	// pkg-C also satisfies 'pkg-A' via provides? No, that's unusual.
	// Instead: b depends on A, we remove A but C provides A.
	// Actually let's keep it simple: no break because pkg-A is also in dblist.
	// Actually if we remove A and A is also in dblist... that can't happen since
	// A is in remove, so A is modified, not dblist.
	// For this test, B depends on A, but we're upgrading A (not removing).
	// pkg-A stays in upgrade, so the dep is still satisfied.
	b2 := make_pkg_with_ver('pkg-B', '2.0', ['pkg-A'])
	a2 := make_pkg_with_ver('pkg-A', '2.0', [])
	local_pkgs2 := [a2, b2]
	remove2 := []&db.Package{}
	upgrade2 := [a2]
	result := check_deps(handle, local_pkgs2, remove2, upgrade2, true) or {
		assert false, 'unexpected error: ${err}'
		return
	}
	// pkg-A is being upgraded, so B's dep on A should still be satisfied by
	// the upgrade list
	assert result.len == 0, 'expected 0 broken deps (A is upgraded), got ${result.len}'
}

fn test_check_deps_reversedeps_with_upgrade_satisfier() {
	handle := &util.Handle{}
	a_old := make_pkg_with_ver('pkg-A', '1.0', [])
	a_new := make_pkg_with_ver('pkg-A', '2.0', [])
	b := make_pkg_with_ver('pkg-B', '1.0', ['pkg-A'])
	// B (dblist) depends on A. A is upgraded from 1.0 to 2.0.
	// The upgrade list contains the new A, so B's dep is satisfied.
	local_pkgs := [a_old, b]
	remove := []&db.Package{}
	upgrade := [a_new]
	result := check_deps(handle, local_pkgs, remove, upgrade, true) or {
		assert false, 'unexpected error: ${err}'
		return
	}
	assert result.len == 0, 'expected 0 broken deps (A is in upgrade), got ${result.len}'
}

fn test_check_deps_empty_lists() {
	handle := &util.Handle{}
	result := check_deps(handle, [], [], [], false) or {
		assert false, 'unexpected error: ${err}'
		return
	}
	assert result.len == 0, 'expected 0 missing deps for empty lists'
}

fn test_check_deps_no_reversedeps() {
	handle := &util.Handle{}
	b := make_pkg_with_ver('pkg-B', '1.0', ['pkg-A'])
	a := make_pkg_with_ver('pkg-A', '1.0', [])
	// B depends on A, A is being removed, but reversedeps=false
	local_pkgs := [a, b]
	remove := [a]
	upgrade := []&db.Package{}
	result := check_deps(handle, local_pkgs, remove, upgrade, false) or {
		assert false, 'unexpected error: ${err}'
		return
	}
	// Without reversedeps, we don't check that B's deps are broken
	assert result.len == 0, 'expected 0 missing deps (reversedeps=false), got ${result.len}'
}

// ===========================================================================
// pkg_should_ignore tests
// ===========================================================================

fn test_pkg_should_ignore_ignorepkg_match() {
	pkg := make_pkg('glibc', [])
	assert pkg_should_ignore(pkg, ['glibc'], [])
}

fn test_pkg_should_ignore_ignorepkg_glob() {
	pkg := make_pkg('linux-firmware', [])
	assert pkg_should_ignore(pkg, ['linux-*'], [])
}

fn test_pkg_should_ignore_ignorepkg_no_match() {
	pkg := make_pkg('glibc', [])
	assert !pkg_should_ignore(pkg, ['systemd'], [])
}

fn test_pkg_should_ignore_ignoregroup_match() {
	mut pkg := make_pkg('myapp', [])
	pkg.groups = ['base-devel']
	assert pkg_should_ignore(pkg, [], ['base-devel'])
}

fn test_pkg_should_ignore_ignoregroup_no_match() {
	pkg := make_pkg('myapp', [])
	assert !pkg_should_ignore(pkg, [], ['base-devel'])
}

fn test_pkg_should_ignore_ignoregroup_glob() {
	mut pkg := make_pkg('myapp', [])
	pkg.groups = ['base-devel']
	assert pkg_should_ignore(pkg, [], ['base-*'])
}

fn test_pkg_should_ignore_neither_matches() {
	mut pkg := make_pkg('myapp', [])
	pkg.groups = ['base-devel']
	assert !pkg_should_ignore(pkg, ['other'], ['other-group'])
}

fn test_pkg_should_ignore_empty_lists() {
	pkg := make_pkg('myapp', [])
	assert !pkg_should_ignore(pkg, [], [])
}
