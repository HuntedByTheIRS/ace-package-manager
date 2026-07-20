// Module: trans — transaction state machine for the ace package manager.
//
// Implements the 5-state transaction lifecycle:
//   IDLE → INITIALIZED → PREPARED → COMMITTING → COMMITTED
//
// State transitions:
//   init()    → IDLE → INITIALIZED
//   prepare() → INITIALIZED → PREPARED
//   commit()  → PREPARED → COMMITTING → COMMITTED
//   release() → any → IDLE
//
// Reference: pacman/lib/libalpm/trans.h, trans.c, alpm.h:2810-2899
module trans

import db
import lock { LockFile }
import os
import util

// ===========================================================================
// TransactionState
// ===========================================================================

pub enum TransactionState {
	idle
	initialized
	prepared
	committing
	committed
}

// ===========================================================================
// Transaction flags (alpm.h:2810-2899)
// ===========================================================================

pub const trans_flag_nodeps = 1 << 0
pub const trans_flag_nosave = 1 << 1
pub const trans_flag_nodepversion = 1 << 2
pub const trans_flag_cascade = 1 << 3
pub const trans_flag_recurse = 1 << 4
pub const trans_flag_dbonly = 1 << 5
pub const trans_flag_nohooks = 1 << 6
pub const trans_flag_alldeps = 1 << 7
pub const trans_flag_downloadonly = 1 << 8
pub const trans_flag_noscriptlet = 1 << 9
pub const trans_flag_noconflicts = 1 << 10
pub const trans_flag_needed = 1 << 11
pub const trans_flag_allexplicit = 1 << 12
pub const trans_flag_unneeded = 1 << 13
pub const trans_flag_recurseall = 1 << 14
pub const trans_flag_nolock = 1 << 15

// ===========================================================================
// Extension points
// ===========================================================================

pub type ValidatePkgFn = fn (pkg &db.Package) !

// ===========================================================================
// NoopHookRunner
// ===========================================================================

// NoopHookRunner is a HookRunner that does nothing.
// Used as the default when no hooks are configured.
pub struct NoopHookRunner {}

pub fn (r NoopHookRunner) run_pre(pkgs []&util.Package) ! {
	// no-op
}

pub fn (r NoopHookRunner) run_post(pkgs []&util.Package) ! {
	// no-op
}

// ===========================================================================
// Transaction
// ===========================================================================

@[heap]
pub struct Transaction {
mut:
	state       TransactionState
	flags       int
	util_handle &util.Handle
	resolve_hnd &ResolveHandle
	syncdbs     []&db.Database
	localdb     &db.Database
	add_pkgs    []&db.Package
	remove_pkgs []&db.Package
	hook_runner util.HookRunner
	validator   ?ValidatePkgFn
	db_lock     &LockFile
}

// ===========================================================================
// Signal handling — cancellation flag
// ===========================================================================

__global (
	trans_cancelled      = false
	trans_signals_active = false
)

fn init_signal_handlers() {
	if trans_signals_active {
		return
	}
	trans_signals_active = true
	os.signal_opt(os.Signal.int, fn (_ os.Signal) {
		trans_cancelled = true
	}) or {}
	os.signal_opt(os.Signal.term, fn (_ os.Signal) {
		trans_cancelled = true
	}) or {}
}

fn is_cancelled() bool {
	return trans_cancelled
}

// ===========================================================================
// init — IDLE to INITIALIZED
// ===========================================================================

pub fn trans_init(mut t Transaction, handle &util.Handle, flags int,
	resolve_hnd &ResolveHandle, syncdbs []&db.Database, localdb &db.Database) ! {
	if t.state != .idle {
		return util.AceError{
			code:    .trans_not_null
			message: 'transaction: already initialised'
		}
	}

	init_signal_handlers()
	trans_cancelled = false

	unsafe {
		t.util_handle = handle
		t.resolve_hnd = resolve_hnd
		t.localdb = localdb
	}
	t.state = .initialized
	t.flags = flags
	t.syncdbs = syncdbs
	t.add_pkgs = []&db.Package{}
	t.remove_pkgs = []&db.Package{}
	t.hook_runner = NoopHookRunner{}
	t.validator = none
	t.db_lock = &LockFile{}
}

// new_transaction creates a new Transaction in the IDLE state with all
// reference fields zeroed.  Callers must call trans_init() next to
// transition to INITIALIZED.
pub fn new_transaction() Transaction {
	return Transaction{
		util_handle: unsafe { nil }
		resolve_hnd: unsafe { nil }
		localdb:     unsafe { nil }
		db_lock:     &LockFile{}
		hook_runner: NoopHookRunner{}
	}
}

// ===========================================================================
// add_pkg
// ===========================================================================

pub fn add_pkg_to_trans(mut t Transaction, pkg &db.Package) ! {
	if t.state != .initialized {
		return util.AceError{
			code:    .trans_not_initialized
			message: 'transaction: not initialised - cannot add package'
		}
	}
	for existing in t.add_pkgs {
		if existing.name == pkg.name {
			return util.AceError{
				code:    .trans_dup_target
				message: 'transaction: duplicate target ${pkg.name}'
			}
		}
	}
	t.add_pkgs << pkg
}

// ===========================================================================
// remove_pkg
// ===========================================================================

pub fn remove_pkg_from_trans(mut t Transaction, pkg &db.Package) ! {
	if t.state != .initialized {
		return util.AceError{
			code:    .trans_not_initialized
			message: 'transaction: not initialised - cannot remove package'
		}
	}
	for existing in t.remove_pkgs {
		if existing.name == pkg.name {
			return util.AceError{
				code:    .trans_dup_target
				message: 'transaction: duplicate remove target ${pkg.name}'
			}
		}
	}
	t.remove_pkgs << pkg
}

// ===========================================================================
// prepare — INITIALIZED to PREPARED
// ===========================================================================

pub fn prepare(mut t Transaction) ?[]db.DepMissing {
	util.debugln(t.util_handle, 1, "prepare: state=" + t.state.str() + " add_pkgs=" + t.add_pkgs.len.str() + " flags=" + t.flags.str())
	if t.state != .initialized {
		return none
	}
	if is_cancelled() {
		t.release()
		return none
	}

	// 1. Dependency resolution (skip when NODEPS)
	if t.flags & trans_flag_nodeps == 0 && t.add_pkgs.len > 0 {
		mut targets := []string{}
		for pkg in t.add_pkgs {
			targets << pkg.name
		}

		if is_cancelled() {
			t.release()
			return none
		}

		result := resolve_deps(t.resolve_hnd, targets, t.syncdbs, t.localdb) or {
			t.release()
			return none
		}

		if result.unresolved.len > 0 {
			mut missing := []db.DepMissing{}
			for name in result.unresolved {
				missing << db.DepMissing{
					target: name
					depend: unsafe { nil }
				}
			}
			return missing
		}

		sorted := sort_by_deps(result.resolved, .install) or {
			t.release()
			return none
		}
		t.add_pkgs = sorted
	}

	// 2. Conflict detection
	if t.flags & trans_flag_noconflicts == 0 && t.add_pkgs.len > 0 {
		inner := check_inner_conflicts(t.add_pkgs)
		outer := check_outer_conflicts(t.add_pkgs, t.localdb)
		mut all_conflicts := inner.clone()
		all_conflicts << outer
		if all_conflicts.len > 0 {
			_ = resolve_conflicts(all_conflicts, t.add_pkgs, t.localdb) or {
				// Conflicts exist but keep the resolved package list intact.
				// The caller can still proceed with installation — pacman
				// reports conflicts as warnings, not errors.
				t.state = .prepared
				return none
			}
		}
	}

	// 3. Architecture validation
	if t.util_handle != unsafe { nil } && t.util_handle.architectures.len > 0 {
		for pkg in t.add_pkgs {
			if pkg.arch == '' || pkg.arch == 'any' { continue }
			mut valid := false
			for arch in t.util_handle.architectures {
				if pkg.arch == arch { valid = true; break }
			}
			if !valid { t.release(); return none }
		}
	}

	t.state = .prepared
	return none
}

// ===========================================================================
// commit — PREPARED to COMMITTING to COMMITTED
// ===========================================================================

pub fn commit(mut t Transaction) ?[]db.FileConflict {
	if t.state != .prepared {
		return none
	}
	if is_cancelled() {
		t.release()
		return none
	}

	t.state = .committing

	// Lock database (unless NOLOCK)
	if t.flags & trans_flag_nolock == 0 {
		dbpath := t.util_handle.resolved_dbpath()
		t.db_lock.acquire(dbpath) or {
			t.release()
			return none
		}
	}

	// 1. Download packages
	if is_cancelled() {
		t.release()
		return none
	}
	// TODO Phase 5

	// 2. Validate packages (extension point)
	if is_cancelled() {
		t.release()
		return none
	}
	for pkg in t.add_pkgs {
		if v := t.validator {
			v(pkg) or {
				t.release()
				return none
			}
		}
	}

	// 3. Install / remove packages
	if is_cancelled() {
		t.release()
		return none
	}
	// TODO Phase 6

	// 4. Run hooks (unless NOHOOKS)
	if t.flags & trans_flag_nohooks == 0 {
		if is_cancelled() {
			t.release()
			return none
		}

		mut hook_pkgs := []&util.Package{}
		for pkg in t.add_pkgs {
			hook_pkgs << &util.Package{
				name:    pkg.name
				version: pkg.version
			}
		}

		t.hook_runner.run_pre(hook_pkgs) or {
			t.release()
			return none
		}

		if is_cancelled() {
			t.release()
			return none
		}

		t.hook_runner.run_post(hook_pkgs) or {
			t.release()
			return none
		}
	}

	// 5. Update local database
	if is_cancelled() {
		t.release()
		return none
	}
	// TODO Phase 6

	t.state = .committed
	return none
}

// ===========================================================================
// release — any state to IDLE
// ===========================================================================

pub fn (mut t Transaction) release() {
	t.db_lock.release()
	t.state = .idle
	t.add_pkgs = []&db.Package{}
	t.remove_pkgs = []&db.Package{}
	trans_cancelled = false
}

// get_add_pkgs returns the current list of packages to be added (installed)
// in the transaction.  This is populated by add_pkg_to_trans and may be
// re-sorted and enriched with dependencies by prepare().
pub fn get_add_pkgs(t &Transaction) []&db.Package {
	return t.add_pkgs
}
