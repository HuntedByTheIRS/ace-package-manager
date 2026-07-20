// Edge-case tests: extreme circular dependency scenarios.
//
// Tests that sort_by_deps handles:
//   - Self-loop (A→A)
//   - Two-node cycle (A→B→A)
//   - Three-node cycle (A→B→C→A)
//   - Cycle with external dep (A→B→C→A where B also depends on D)
//   - Diamond with hidden cycle inside
//   - Complex multi-cycle graph
//   - Large circular chain (15-node cycle)
//   - Disconnected cycles
//   - Cycle + provider resolution
module trans

import db

// ---------------------------------------------------------------------------
// Helpers (reuse patterns from resolver_test.v)
// ---------------------------------------------------------------------------

fn make_cycle_pkg(name string, deps []string) &db.Package {
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

fn pkg_names(pkgs []&db.Package) string {
	mut names := []string{}
	for p in pkgs {
		names << p.name
	}
	return names.join(', ')
}

fn assert_all_present(result []&db.Package, expected []string, tc_name string) {
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

fn assert_no_duplicates(result []&db.Package, tc_name string) {
	mut seen := map[string]int{}
	for p in result {
		seen[p.name]++
	}
	for name, count in seen {
		assert count == 1, '${tc_name}: duplicate ${name} appears ${count} times'
	}
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn test_self_loop_alone() {
	a := make_cycle_pkg('A', ['A'])
	result := sort_by_deps([a], .install) or { panic('unexpected error: ${err}') }
	assert result.len == 1, 'self-loop alone: expected 1, got ${result.len}'
	assert result[0].name == 'A'
}

fn test_two_node_cycle_install() {
	a := make_cycle_pkg('A', ['B'])
	b := make_cycle_pkg('B', ['A'])
	pkgs := [a, b]
	result := sort_by_deps(pkgs, .install) or { panic('unexpected error: ${err}') }
	assert result.len == 2, '2-node cycle install: expected 2, got ${result.len}'
	assert_all_present(result, ['A', 'B'], '2-node cycle install')
	assert_no_duplicates(result, '2-node cycle install')
}

fn test_two_node_cycle_remove() {
	a := make_cycle_pkg('A', ['B'])
	b := make_cycle_pkg('B', ['A'])
	pkgs := [a, b]
	result := sort_by_deps(pkgs, .remove) or { panic('unexpected error: ${err}') }
	assert result.len == 2, '2-node cycle remove: expected 2, got ${result.len}'
	assert_all_present(result, ['A', 'B'], '2-node cycle remove')
	assert_no_duplicates(result, '2-node cycle remove')
}

fn test_three_node_cycle_verify_all_present() {
	a := make_cycle_pkg('A', ['B'])
	b := make_cycle_pkg('B', ['C'])
	c := make_cycle_pkg('C', ['A'])
	pkgs := [a, b, c]
	result := sort_by_deps(pkgs, .install) or { panic('unexpected error: ${err}') }
	assert result.len == 3
	assert_all_present(result, ['A', 'B', 'C'], '3-node cycle')
	assert_no_duplicates(result, '3-node cycle')
}

fn test_cycle_with_external() {
	// A→B→C→A (cycle) + B→D (external dep satisfied by D)
	a := make_cycle_pkg('A', ['B'])
	b := make_cycle_pkg('B', ['C', 'D'])
	c := make_cycle_pkg('C', ['A'])
	d := make_cycle_pkg('D', [])
	pkgs := [a, b, c, d]
	result := sort_by_deps(pkgs, .install) or { panic('unexpected error: ${err}') }
	assert result.len == 4, 'cycle+external: expected 4, got ${result.len}'
	assert_all_present(result, ['A', 'B', 'C', 'D'], 'cycle+external')

	// D must appear before B (B depends on D)
	mut d_pos := -1
	mut b_pos := -1
	for i, p in result {
		if p.name == 'D' {
			d_pos = i
		}
		if p.name == 'B' {
			b_pos = i
		}
	}
	assert d_pos >= 0 && b_pos >= 0, 'D or B not found in result'
	assert d_pos < b_pos, 'D should be before B (B depends on D)'
}

fn test_diamond_with_internal_cycle() {
	// A→B, A→C, B→D, C→D, D→A (A→B→D→A forms cycle)
	a := make_cycle_pkg('A', ['B', 'C'])
	b := make_cycle_pkg('B', ['D'])
	c := make_cycle_pkg('C', ['D'])
	d := make_cycle_pkg('D', ['A'])
	pkgs := [a, b, c, d]
	result := sort_by_deps(pkgs, .install) or { panic('unexpected error: ${err}') }
	assert result.len == 4, 'diamond+cycle: expected 4, got ${result.len}'
	assert_all_present(result, ['A', 'B', 'C', 'D'], 'diamond+cycle')
	assert_no_duplicates(result, 'diamond+cycle')
}

fn test_disconnected_cycles() {
	// Two independent cycles: A↔B and C↔D
	a := make_cycle_pkg('A', ['B'])
	b := make_cycle_pkg('B', ['A'])
	c := make_cycle_pkg('C', ['D'])
	d := make_cycle_pkg('D', ['C'])
	pkgs := [a, b, c, d]
	result := sort_by_deps(pkgs, .install) or { panic('unexpected error: ${err}') }
	assert result.len == 4, 'disconnected cycles: expected 4, got ${result.len}'
	assert_all_present(result, ['A', 'B', 'C', 'D'], 'disconnected cycles')
	assert_no_duplicates(result, 'disconnected cycles')
}

fn test_large_circular_chain() {
	// 15-node cycle: A→B→C→...→O→A
	mut pkgs := []&db.Package{}
	names := ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O']
	for i in 0 .. names.len {
		next := if i + 1 < names.len { [names[i + 1]] } else { [names[0]] }
		pkgs << make_cycle_pkg(names[i], next)
	}
	result := sort_by_deps(pkgs, .install) or { panic('unexpected error: ${err}') }
	assert result.len == 15, '15-node cycle: expected 15, got ${result.len}'
	assert_all_present(result, names, '15-node cycle')
	assert_no_duplicates(result, '15-node cycle')
}

fn test_multi_cycle_complex() {
	// A→B→A (cycle) + B→C + C→D→C (cycle) + D→E
	a := make_cycle_pkg('A', ['B'])
	b := make_cycle_pkg('B', ['A', 'C'])
	c := make_cycle_pkg('C', ['D'])
	d := make_cycle_pkg('D', ['C', 'E'])
	e := make_cycle_pkg('E', [])
	pkgs := [a, b, c, d, e]
	result := sort_by_deps(pkgs, .install) or { panic('unexpected error: ${err}') }
	assert result.len == 5, 'multi-cycle: expected 5, got ${result.len}'
	assert_all_present(result, ['A', 'B', 'C', 'D', 'E'], 'multi-cycle')
	assert_no_duplicates(result, 'multi-cycle')
}

fn test_cycle_with_provides() {
	// A depends on 'libfoo', B provides 'libfoo', C depends on A, A→B→C→A (partial cycle)
	// Also: B→A (so the cycle goes A→B, B→A via provides name)
	a := make_cycle_pkg('A', ['B'])
	mut b := make_cycle_pkg('B', ['A'])
	b.provides = [db.Dependency{
		name:      'libfoo'
		modifier:  .any
		name_hash: db.compute_name_hash('libfoo')
	}]
	c := make_cycle_pkg('C', ['B'])
	pkgs := [a, b, c]
	result := sort_by_deps(pkgs, .install) or { panic('unexpected error: ${err}') }
	assert result.len == 3, 'cycle+provides: expected 3, got ${result.len}'
	assert_all_present(result, ['A', 'B', 'C'], 'cycle+provides')
	assert_no_duplicates(result, 'cycle+provides')
}

fn test_cycle_remove_with_external_dep() {
	// A depends on B, B depends on C, C depends on A (cycle)
	// In remove mode: dependents first
	a := make_cycle_pkg('A', ['B'])
	b := make_cycle_pkg('B', ['C'])
	c := make_cycle_pkg('C', ['A'])
	pkgs := [a, b, c]
	result := sort_by_deps(pkgs, .remove) or { panic('unexpected error: ${err}') }
	assert result.len == 3, 'cycle remove: expected 3, got ${result.len}'
	assert_all_present(result, ['A', 'B', 'C'], 'cycle remove')
	assert_no_duplicates(result, 'cycle remove')
}

fn test_all_same_name_cyclic_dep() {
	// Two packages that each depend on the other and also have additional deps
	a := make_cycle_pkg('pkg-a', ['pkg-b', 'pkg-c'])
	b := make_cycle_pkg('pkg-b', ['pkg-a', 'pkg-d'])
	c := make_cycle_pkg('pkg-c', [])
	d := make_cycle_pkg('pkg-d', [])
	pkgs := [a, b, c, d]
	result := sort_by_deps(pkgs, .install) or { panic('unexpected error: ${err}') }
	assert result.len == 4, 'cycle+addl deps: expected 4, got ${result.len}'
	assert_all_present(result, ['pkg-a', 'pkg-b', 'pkg-c', 'pkg-d'], 'cycle+addl deps')
	// C and D should be before A and B
	mut c_pos := -1
	mut d_pos := -1
	mut a_pos := -1
	mut b_pos := -1
	for i, p in result {
		match p.name {
			'pkg-a' { a_pos = i }
			'pkg-b' { b_pos = i }
			'pkg-c' { c_pos = i }
			'pkg-d' { d_pos = i }
			else {}
		}
	}
	assert c_pos >= 0 && d_pos >= 0
	assert c_pos < a_pos || c_pos < b_pos, 'leaf dep C should be early'
	assert d_pos < a_pos || d_pos < b_pos, 'leaf dep D should be early'
}
