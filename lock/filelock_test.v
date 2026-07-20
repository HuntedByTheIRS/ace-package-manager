module lock

import os

fn test_lock_lifecycle() {
	tmpdir := os.join_path(os.temp_dir(), 'ace-lock-test')
	os.rmdir_all(tmpdir) or {}
	os.mkdir_all(tmpdir)!
	defer {
		os.rmdir_all(tmpdir) or {}
	}

	// Test acquire
	mut lf := LockFile{}
	lf.acquire(tmpdir)!
	assert is_locked(tmpdir)

	// Test double-acquire fails
	mut lf2 := LockFile{}
	mut lock_fail := false
	lf2.acquire(tmpdir) or {
		lock_fail = true
	}
	assert lock_fail

	// Test release
	lf.release()
	assert !is_locked(tmpdir)

	// Test stale lock: write dead PID, should be acquirable
	os.write_file(os.join_path(tmpdir, 'db.lck'), '999999')!
	mut lf3 := LockFile{}
	lf3.acquire(tmpdir)!
	assert is_locked(tmpdir)
	lf3.release()
}
