module util

import os

// ------------------------------------------------------------
// LogLevel mirrors alpm_loglevel_t from libalpm/alpm.h.
// ------------------------------------------------------------

pub enum LogLevel {
	error_val = 1
	warning   = 2
	debug     = 4
	function  = 8
}

// ------------------------------------------------------------
// Event types — mirror alpm_event_type_t from libalpm/alpm.h.
// Total: 37 event kinds plus unknown sentinel.
// ------------------------------------------------------------

pub enum EventType {
	unknown = 0
	add_done          // ALPM_EVENT_ADD_DONE = 1
	add_start         // ALPM_EVENT_ADD_START
	remove_done       // ALPM_EVENT_REMOVE_DONE
	remove_start      // ALPM_EVENT_REMOVE_START
	upgrade_done      // ALPM_EVENT_UPGRADE_DONE
	upgrade_start     // ALPM_EVENT_UPGRADE_START
	integrity_done    // ALPM_EVENT_INTEGRITY_DONE
	integrity_start   // ALPM_EVENT_INTEGRITY_START
	keyring_done      // ALPM_EVENT_KEYRING_DONE
	keyring_start     // ALPM_EVENT_KEYRING_START
	config_done       // ALPM_EVENT_CONFIG_DONE
	config_start      // ALPM_EVENT_CONFIG_START
	diskspace_start   // ALPM_EVENT_DISKSPACE_START
	diskspace_done    // ALPM_EVENT_DISKSPACE_DONE
	done              // ALPM_EVENT_DONE
	start             // ALPM_EVENT_START
	download_done     // ALPM_EVENT_DOWNLOAD_DONE
	download_start    // ALPM_EVENT_DOWNLOAD_START
	download_db_start // ALPM_EVENT_DOWNLOAD_DB_START
	download_db_done  // ALPM_EVENT_DOWNLOAD_DB_DONE
	hook_start        // ALPM_EVENT_HOOK_START
	hook_done         // ALPM_EVENT_HOOK_DONE
	hook_run_start    // ALPM_EVENT_HOOK_RUN_START
	hook_run_done     // ALPM_EVENT_HOOK_RUN_DONE
	optdep_removal_start  // ALPM_EVENT_OPTDEP_REMOVAL_START
	optdep_removal_done   // ALPM_EVENT_OPTDEP_REMOVAL_DONE
	database_locked   // ALPM_EVENT_DATABASE_LOCKED
	database_unlocked // ALPM_EVENT_DATABASE_UNLOCKED
	pacnew_created    // ALPM_EVENT_PACNEW_CREATED
	pacsave_created   // ALPM_EVENT_PACSAVE_CREATED
	scriptlet_info    // ALPM_EVENT_SCRIPTLET_INFO
	retrieve_start    // ALPM_EVENT_RETRIEVE_START
	retrieve_done     // ALPM_EVENT_RETRIEVE_DONE
	pkg_retrieve_done     // ALPM_EVENT_PKG_RETRIEVE_DONE
	pkg_retrieve_failed   // ALPM_EVENT_PKG_RETRIEVE_FAILED
	searching_start   // ALPM_EVENT_SEARCHING_START
	searching_done    // ALPM_EVENT_SEARCHING_DONE
}

// ------------------------------------------------------------
// Question types — mirror alpm_question_type_t.
// 7 question kinds.
// ------------------------------------------------------------

pub enum QuestionType {
	unknown = 0
	install_ignorepkg // ALPM_QUESTION_INSTALL_IGNOREPKG = 1
	replace_pkg       // ALPM_QUESTION_REPLACE_PKG
	conflict_pkg      // ALPM_QUESTION_CONFLICT_PKG
	corrupted_pkg     // ALPM_QUESTION_CORRUPTED_PKG
	remove_pkgs       // ALPM_QUESTION_REMOVE_PKGS
	select_provider   // ALPM_QUESTION_SELECT_PROVIDER
	import_key        // ALPM_QUESTION_IMPORT_KEY
}

// ------------------------------------------------------------
// Download event types — mirror alpm_download_event_type_t.
// ------------------------------------------------------------

pub enum DownloadEventType {
	init = 1      // ALPM_DOWNLOAD_INIT
	progress      // ALPM_DOWNLOAD_PROGRESS
	completed     // ALPM_DOWNLOAD_COMPLETED
}

// ------------------------------------------------------------
// Event — lifecycle event with typed payload fields.
// For each EventType variant only a subset of fields carries
// meaningful data; unused fields are zero-valued.
// ------------------------------------------------------------

pub struct Event {
pub:
	typ EventType
	// Package-identity fields (add / remove / upgrade)
	pkg_name    string
	pkg_version string
	pkg_old_version string
	// Hook events
	hook_name string
	hook_desc string
	// Download events (filename, transfer progress)
	filename    string
	total_bytes i64
	xfered_bytes i64
	// Scriptlet output line
	line string
	// File path events (pacnew / pacsave)
	from_path string
	to_path   string
	// Optional-dependency removal
	optdep_name string
	optdep_pkg  string
}

// ------------------------------------------------------------
// Question — interactive prompt with typed payload fields.
// The callback sets .answer to communicate the user's decision
// back to the transaction engine.
// ------------------------------------------------------------

pub struct Question {
pub:
	typ QuestionType
	// Install ignorepkg
	pkg_name    string
	pkg_version string
	// Replace
	old_pkg_name string
	new_pkg_name string
	// Conflict
	conflict_target string
	conflict_pkg    string
	conflict_file   string
	// Corrupted package
	corrupted_file string
	// Remove packages
	remove_targets []string
	// Provider selection
	dep_name   string
	providers  []string
	// Import key
	key_id       string
	fingerprint  string
	key_owner    string
	// The callback sets this to true (yes/proceed) or false (no/cancel).
	// --noconfirm auto-sets a safe default based on question type.
pub mut:
	answer bool
}

// ------------------------------------------------------------
// DownloadEvent — per-file download progress notification.
// ------------------------------------------------------------

pub struct DownloadEvent {
pub:
	typ      DownloadEventType
	filename string
	xfered   u64
	total    u64
}

// ------------------------------------------------------------
// Callback function types
// ------------------------------------------------------------

pub type ProgressCallback = fn (percent int, message string)

pub type EventCallback = fn (event &Event)

pub type QuestionCallback = fn (question &Question)

// ------------------------------------------------------------
// Package — stub; actual fields filled in by Phase 4.
// ------------------------------------------------------------

pub struct Package {
pub:
	name    string
	version string
	release string
	arch    string
	sha256sum string // expected SHA256 hash (from sync DB)
}

// ------------------------------------------------------------
// HookRunner — called before/after a transaction.
// Phase 4 provides a no-op implementation.
// ------------------------------------------------------------

pub interface HookRunner {
	run_pre(pkgs []&Package) !
	run_post(pkgs []&Package) !
}

// ------------------------------------------------------------
// Handle — shared configuration handle (analogous to
// alpm_handle_t, but V-native and phase 1–8 compatible).
// ------------------------------------------------------------

pub struct Handle {
pub mut:
	root               string   // install root (--root)
	dbpath             string   // database path (--dbpath)
	cachedirs          []string // package cache directories (--cachedir)
	logfile            string   // log file path (--logfile) — NOT root-relative
	gpgdir             string   // GPG home directory (--gpgdir)
	hookedirs          []string // hook directories (--hookdir)
	architectures      []string // target architectures
	siglevel           int      // default signature verification level
	parallel_downloads int      // parallel download streams (min 1)
	lockfile_path      string   // resolved lock file path
	no_confirm         bool     // --noconfirm / --confirm
	noprogressbar      bool     // --noprogressbar — suppress progress bars
	debug_level        int      // --debug level (0=none, 1=basic, 2=verbose)
	checkspace         bool     // CheckSpace — enable disk space checking
	overwrite_files    []string // glob patterns for files that may be overwritten (--overwrite)
	noextract          []string // glob patterns for files to never extract (NoExtract)
	noupgrade          []string // glob patterns for files to save as .pacnew (NoUpgrade)
	download_user      string   // user to drop privileges to for downloads
	disable_sandbox    bool     // disable all sandboxing
	disable_sandbox_fs bool     // disable filesystem sandboxing only
	disable_sandbox_sys bool    // disable syscall sandboxing only
}

// resolved_dbpath returns root + dbpath.
// DBPath, CacheDir, HookDir, and GPGDir are root-relative.
// LogFile is NOT root-relative (it is an absolute path normally).
pub fn (h &Handle) resolved_dbpath() string {
	return os.join_path(h.root, h.dbpath)
}

// resolved_cachedirs returns each cachedir joined with root.
pub fn (h &Handle) resolved_cachedirs() []string {
	mut result := []string{}
	for dir in h.cachedirs {
		result << os.join_path(h.root, dir)
	}
	return result
}

// resolved_gpgdir returns root + gpgdir.
pub fn (h &Handle) resolved_gpgdir() string {
	return os.join_path(h.root, h.gpgdir)
}

// resolved_hookedirs returns each hookdir joined with root.
pub fn (h &Handle) resolved_hookedirs() []string {
	mut result := []string{}
	for dir in h.hookedirs {
		result << os.join_path(h.root, dir)
	}
	return result
}
