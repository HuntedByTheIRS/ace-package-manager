// Tests for the --deptree dependency display helpers.
module cli

import db
import os
import rand

// make_provider_fixture builds a local database holding a package that
// satisfies a dependency through its provides list, the way readline
// satisfies "libreadline.so=8-64".  Returns the db path and a cleanup fn.
fn make_provider_fixture() (string, fn ()) {
	tmp_root := os.join_path(os.temp_dir(), 'ace-deptree-test-${rand.u32():x}')
	db_path := os.join_path(tmp_root, 'var', 'lib', 'ace')
	pkg_dir := os.join_path(db_path, 'local', 'readline-8.3.6-1.1')
	os.mkdir_all(pkg_dir) or { panic('mkdir failed: ${err}') }
	os.write_file(os.join_path(db_path, 'local', 'ALPM_DB_VERSION'), '9\n') or {
		panic('write failed: ${err}')
	}

	mut desc := '%NAME%\nreadline\n%VERSION%\n8.3.6-1.1\n%ARCH%\nx86_64_v4\n'
	desc += '%PROVIDES%\nlibhistory.so=8-64\nlibreadline.so=8-64\n'
	os.write_file(os.join_path(pkg_dir, 'desc'), desc) or { panic('write failed: ${err}') }
	os.write_file(os.join_path(pkg_dir, 'files'), '%FILES%\nusr/lib/libreadline.so.8\n') or {
		panic('write failed: ${err}')
	}

	return db_path, fn [tmp_root] () {
		os.rmdir_all(tmp_root) or {}
	}
}

fn test_find_installed_satisfier_through_provides() {
	db_path, cleanup := make_provider_fixture()
	defer { cleanup() }

	mut local_db := db.init(db_path) or { panic('init failed: ${err}') }
	local_db.populate() or { panic('populate failed: ${err}') }

	// A library dependency is not a package name, so it can only be matched
	// through the provider list.  --deptree used to print "[not installed]"
	// for these.
	dep := db.Dependency.from_string('libreadline.so=8-64') or {
		assert false, 'parse failed: ${err}'
		return
	}
	satisfier := find_installed_satisfier(&local_db, dep) or {
		assert false, 'no provider found for ${dep.name}'
		return
	}
	assert satisfier.name == 'readline'
	assert dep_satisfied_by(satisfier, dep)

	provider := find_installed_provider(&local_db, dep) or {
		assert false, 'no provider found: ${err}'
		return
	}
	assert provider.name == 'readline'

	// A name match still wins, and an unknown library stays unresolved.
	by_name := db.Dependency.from_string('readline') or { panic('parse failed: ${err}') }
	name_match := find_installed_satisfier(&local_db, by_name) or {
		assert false, 'name match not found'
		return
	}
	assert name_match.name == 'readline'
	missing := db.Dependency.from_string('libnope.so=1-64') or { panic('parse failed: ${err}') }
	if _ := find_installed_satisfier(&local_db, missing) {
		assert false, 'unknown library must not resolve'
	}
}
