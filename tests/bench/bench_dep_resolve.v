// bench_dep_resolve.v — benchmarks for dependency resolution and sorting.
//
// Usage:
//   v run tests/bench/bench_dep_resolve.v

import time
import db
import trans

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

// ---------------------------------------------------------------------------
// Build a hierarchical dependency tree
// ---------------------------------------------------------------------------

fn build_dep_tree(depth int, width int) []&db.Package {
	mut pkgs := []&db.Package{}
	// Create leaf packages first, then build up
	// Each level i has 'width' packages, depending on packages from level i-1
	mut level_names := [][]string{}

	for l := 0; l < depth; l++ {
		mut names := []string{}
		for w := 0; w < width; w++ {
			name := 'pkg-L${l}-W${w}'
			names << name

			mut deps := []string{}
			if l > 0 {
				// Depend on all packages from the previous level
				for _, pn in level_names[l - 1] {
					deps << pn
				}
			}

			pkgs << make_pkg(name, deps)
		}
		level_names << names
	}
	return pkgs
}

fn build_diamond_deps(count int) []&db.Package {
	mut pkgs := []&db.Package{}
	// Root depends on 'count' independent leaf packages
	mut leaves := []string{}
	for i := 0; i < count; i++ {
		name := 'leaf-${i}'
		leaves << name
		pkgs << make_pkg(name, [])
	}
	pkgs << make_pkg('root', leaves)
	return pkgs
}

fn build_wide_deps(count int) []&db.Package {
	mut pkgs := []&db.Package{}
	// Chain: pkg-0 → pkg-1 → pkg-2 → ... → pkg-N
	for i := 0; i < count; i++ {
		mut deps := []string{}
		if i > 0 {
			deps << 'pkg-${i - 1}'
		}
		pkgs << make_pkg('pkg-${i}', deps)
	}
	return pkgs
}

// ---------------------------------------------------------------------------
// Benchmarks
// ---------------------------------------------------------------------------

fn bench_sort_install(count int) i64 {
	pkgs := build_wide_deps(count)
	start := time.now()
	result := trans.sort_by_deps(pkgs, .install) or { panic('sort: ${err}') }
	ms := time.since(start).milliseconds()
	_ = result
	return ms
}

fn bench_sort_remove(count int) i64 {
	pkgs := build_wide_deps(count)
	start := time.now()
	result := trans.sort_by_deps(pkgs, .remove) or { panic('sort: ${err}') }
	ms := time.since(start).milliseconds()
	_ = result
	return ms
}

fn bench_resolve_basic(target_count int, db_size int) i64 {
	mut pkgs := []&db.Package{}
	// Create db_size packages with a chain dependency structure
	for i := 0; i < db_size; i++ {
		mut deps := []string{}
		if i > 0 {
			deps << 'pkg-${i - 1}'
		}
		pkgs << make_pkg('pkg-${i}', deps)
	}
	sdb := make_db_with(pkgs)
	localdb := make_db_with([])
	handle := &trans.ResolveHandle{}

	mut targets := []string{}
	for i := 0; i < target_count && i < db_size; i++ {
		targets << 'pkg-${i}'
	}

	start := time.now()
	result := trans.resolve_deps(handle, targets, [sdb], localdb) or { panic('resolve: ${err}') }
	ms := time.since(start).milliseconds()
	_ = result
	return ms
}

fn bench_sort_diamond(count int) i64 {
	pkgs := build_diamond_deps(count)
	start := time.now()
	result := trans.sort_by_deps(pkgs, .install) or { panic('sort: ${err}') }
	ms := time.since(start).milliseconds()
	_ = result
	return ms
}

fn bench_sort_tree(depth int, width int) i64 {
	pkgs := build_dep_tree(depth, width)
	start := time.now()
	result := trans.sort_by_deps(pkgs, .install) or { panic('sort: ${err}') }
	ms := time.since(start).milliseconds()
	_ = result
	return ms
}

fn main() {
	println('=== Dependency resolution benchmarks ===')
	println('')

	// Sort benchmarks
    mut ms := bench_sort_install(100)
	println('  sort/install (100 linear):  ${ms:5} ms')

	ms = bench_sort_remove(100)
	println('  sort/remove (100 linear):   ${ms:5} ms')

	ms = bench_sort_install(500)
	println('  sort/install (500 linear):  ${ms:5} ms')

	ms = bench_sort_diamond(100)
	println('  sort/diamond (100 leaves):  ${ms:5} ms')

	ms = bench_sort_tree(5, 4)
	println('  sort/tree (depth=5,w=4):    ${ms:5} ms (${5*4} pkgs)')

	ms = bench_sort_tree(10, 5)
	println('  sort/tree (depth=10,w=5):   ${ms:5} ms (${10*5} pkgs)')

	// Resolve benchmarks
	ms = bench_resolve_basic(10, 100)
	println('  resolve/basic (10/100):     ${ms:5} ms')

	ms = bench_resolve_basic(10, 500)
	println('  resolve/basic (10/500):     ${ms:5} ms')

	ms = bench_resolve_basic(50, 200)
	println('  resolve/basic (50/200):     ${ms:5} ms')

	println('')
	println('Done.')
}
