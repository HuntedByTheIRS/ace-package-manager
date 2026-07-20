// bench_db_load.v — benchmarks for database loading (init, populate, write).
//
// Usage: v -enable-globals run tests/bench/bench_db_load.v

import os
import time
import db
import vibarchive.archive

const pkg_count = 50

fn bench_init_local_db(iterations int) i64 {
	tmpdir := os.join_path(os.temp_dir(), 'ace_bench_init')
	os.mkdir_all(os.join_path(tmpdir, 'local'), os.MkdirParams{}) or { panic('mkdir: ${err}') }
	os.write_file(os.join_path(tmpdir, 'local', 'ALPM_DB_VERSION'), '9\n') or { panic('write: ${err}') }

	start := time.now()
	for _ in 0 .. iterations {
		mut ldb := db.init(tmpdir) or { panic('init: ${err}') }
		_ = ldb
	}
	return time.since(start).milliseconds()
}

fn bench_populate_local_db(n int) i64 {
	tmpdir := os.join_path(os.temp_dir(), 'ace_bench_populate')
	os.mkdir_all(os.join_path(tmpdir, 'local'), os.MkdirParams{}) or { panic('mkdir: ${err}') }
	os.write_file(os.join_path(tmpdir, 'local', 'ALPM_DB_VERSION'), '9\n') or { panic('write: ${err}') }

	for i in 0 .. n {
		pkg := &db.Package{
			name:      'bench-pkg-${i}'
			version:   '${i}.0-1'
			desc:      'Benchmark package ${i}'
			arch:      'x86_64'
			reason:    .explicit
			name_hash: db.compute_name_hash('bench-pkg-${i}')
		}
		db.write_pkg(tmpdir, pkg, db.infrq_desc) or { panic('write: ${err}') }
	}

	start := time.now()
	mut ldb := db.init(tmpdir) or { panic('init: ${err}') }
	ldb.populate() or { panic('populate: ${err}') }
	elapsed := time.since(start).milliseconds()
	_ = ldb
	return elapsed
}

fn bench_write_pkg(n int) i64 {
	tmpdir := os.join_path(os.temp_dir(), 'ace_bench_write')
	os.mkdir_all(os.join_path(tmpdir, 'local'), os.MkdirParams{}) or { panic('mkdir: ${err}') }
	os.write_file(os.join_path(tmpdir, 'local', 'ALPM_DB_VERSION'), '9\n') or { panic('write: ${err}') }

	start := time.now()
	for i in 0 .. n {
		pkg := &db.Package{
			name:      'write-pkg-${i}'
			version:   '1.0-${i}'
			desc:      'Write benchmark package'
			arch:      'x86_64'
			reason:    .explicit
			name_hash: db.compute_name_hash('write-pkg-${i}')
		}
		db.write_pkg(tmpdir, pkg, db.infrq_desc) or { panic('write: ${err}') }
	}
	return time.since(start).milliseconds()
}

fn bench_sync_db_parse(n int) i64 {
	tmpdir := os.join_path(os.temp_dir(), 'ace_bench_sync_${n}')
	os.mkdir_all(tmpdir, os.MkdirParams{}) or { panic('mkdir: ${err}') }
	db_path := os.join_path(tmpdir, 'bench.db.tar')

	mut w := archive.new_writer()
	w.set_format_pax_restricted() or { panic('set_format: ${err}') }
	w.add_filter_none() or { panic('add_filter: ${err}') }
	w.open_file(db_path) or { panic('open_file: ${err}') }

	for i in 0 .. n {
		dir := 'pkg-${i}-1.0-1'
		w.add_directory(dir) or { panic('add_dir: ${err}') }
		desc := '%NAME%\npkg-${i}\n%VERSION%\n1.0-1\n%DESC%\nBench pkg ${i}\n%ARCH%\nx86_64\n\n'
		w.add_bytes('${dir}/desc', desc.bytes()) or { panic('add_bytes: ${err}') }
	}
	w.free()

	start := time.now()
	mut sdb := db.new_sync_db()
	db.populate(mut sdb, db_path) or { panic('populate: ${err}') }
	elapsed := time.since(start).milliseconds()
	_ = sdb
	return elapsed
}

fn main() {
	println('=== Database load benchmarks ===')
	println('')

	mut ms := bench_init_local_db(500)
	println('  db/init (500x):      ${ms:5} ms')

	ms = bench_populate_local_db(pkg_count)
	println('  db/populate (${pkg_count} pkgs): ${ms:5} ms')

	ms = bench_write_pkg(pkg_count)
	println('  db/write (${pkg_count} pkgs):  ${ms:5} ms')

	ms = bench_sync_db_parse(pkg_count)
	println('  db/sync_parse (${pkg_count}): ${ms:5} ms')

	ms = bench_sync_db_parse(pkg_count * 2)
	println('  db/sync_parse (${pkg_count * 2}): ${ms:5} ms')

	println('')
	println('Done.')
}
