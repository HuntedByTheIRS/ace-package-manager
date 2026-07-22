// cli/display.v — CLI callback system for transaction events, questions,
// progress bars, and multi-file download display.
//
// Reference:
//   pacman/src/pacman/callback.c
//
// Provides five public callbacks consumed by the transaction engine:
//   cb_log        — log messages with level-based coloring
//   cb_event      — 37 lifecycle event types from alpm.h
//   cb_question   — 7 interactive question types with --noconfirm support
//   cb_progress   — single-package progress bar (--noprogressbar suppression)
//   cb_download   — multi-bar download display for concurrent fetches
module cli

import os
import util

// ===========================================================================
// Color support
// ===========================================================================

// ANSI escape sequences for terminal color output.
const color_red = '\033[1;31m'
const color_green = '\033[1;32m'
const color_yellow = '\033[1;33m'
const color_blue = '\033[1;34m'
const color_magenta = '\033[1;35m'
const color_cyan = '\033[1;36m'
const color_dark_gray = '\033[38;5;240m'
const color_reset = '\033[0m'
const bar_width = 35

// use_color returns true if terminal color output is supported.
// Follows the NO_COLOR convention (https://no-color.org/).
fn use_color() bool {
	// NO_COLOR environment variable — if set to any non-empty value, disable
	// color regardless of terminal capabilities.
	if os.getenv('NO_COLOR') != '' {
		return false
	}
	term := os.getenv('TERM')
	return term != '' && term != 'dumb'
}

// colorize wraps text in ANSI color codes if color output is enabled.
fn colorize(text string, c string) string {
	if use_color() {
		return c + text + color_reset
	}
	return text
}

// ===========================================================================
// Helpers
// ===========================================================================

// progress_bar renders a colored text progress bar like "[#######----] 73%".
// The filled portion uses green, the empty portion uses dark gray.
fn progress_bar(pct int, width int) string {
	mut filled := pct
	if filled < 0 {
		filled = 0
	}
	if filled > 100 {
		filled = 100
	}
	n := filled * width / 100
	mut bar := '['
	for i in 0 .. width {
		if i < n {
			bar += colorize('#', color_green)
		} else {
			bar += colorize('-', color_dark_gray)
		}
	}
	bar += ']'
	if pct >= 0 {
		bar += ' ' + colorize('${filled:3d}%', color_green)
	}
	return bar
}

// format_size converts a byte count to a human-readable string (KiB/MiB/GiB).
fn format_size(bytes u64) string {
	if bytes >= 1073741824 {
		gib := f64(bytes) / 1073741824.0
		return '${gib:.1f} GiB'
	} else if bytes >= 1048576 {
		mib := f64(bytes) / 1048576.0
		return '${mib:.1f} MiB'
	} else if bytes >= 1024 {
		kib := f64(bytes) / 1024.0
		return '${kib:.0f} KiB'
	}
	return '${bytes} B'
}

// print_human_size prints a byte count as a human-readable size to stdout.
fn print_human_size(bytes i64) {
	if bytes <= 0 {
		print('0 B')
	} else {
		print(format_size(u64(bytes)))
	}
}

// ===========================================================================
// cb_log — display log messages (mirrors pacman's cb_log).
// ===========================================================================

// cb_log writes a level-prefixed message to stderr.
// Error messages are printed in red, warnings in yellow, debug in blue,
// function traces in cyan.
pub fn cb_log(_handle &util.Handle, level util.LogLevel, msg string) {
	prefix := match level {
		.error_val { colorize('error:', color_red) }
		.warning { colorize('warning:', color_yellow) }
		.debug { colorize('debug:', color_blue) }
		.function { colorize('function:', color_cyan) }
	}
	eprintln('${prefix} ${msg}')
}

// ===========================================================================
// cb_event — handle all 37 ALPM lifecycle events.
// ===========================================================================

// cb_event dispatches on event.typ and prints an appropriate message.
// Uses payload fields (pkg_name, filename, hook_name, etc.) where relevant.
pub fn cb_event(_handle &util.Handle, event &util.Event) {
	msg := match event.typ {
		.add_start {
			colorize('installing ${event.pkg_name} (${event.pkg_version})...', color_green)
		}
		.add_done {
			colorize('    installed ${event.pkg_name} (${event.pkg_version})', color_green)
		}
		.remove_start {
			colorize('removing ${event.pkg_name}...', color_magenta)
		}
		.remove_done {
			colorize('    removed ${event.pkg_name}', color_magenta)
		}
		.upgrade_start {
			colorize('upgrading ${event.pkg_name} (${event.pkg_old_version} -> ${event.pkg_version})...',
				color_cyan)
		}
		.upgrade_done {
			colorize('    upgraded ${event.pkg_name} (${event.pkg_version})', color_cyan)
		}
		.integrity_start {
			'checking package integrity...'
		}
		.integrity_done {
			'    integrity check done'
		}
		.keyring_start {
			'checking keys...'
		}
		.keyring_done {
			'    keyring checked'
		}
		.config_start {
			'checking config files...'
		}
		.config_done {
			'    config files checked'
		}
		.diskspace_start {
			'checking disk space...'
		}
		.diskspace_done {
			'    disk space checked'
		}
		.start {
			':: Transaction started'
		}
		.done {
			colorize(':: Transaction finished successfully', color_green)
		}
		.download_start {
			'downloading ${event.filename}...'
		}
		.download_done {
			'    downloaded ${event.filename}'
		}
		.download_db_start {
			'    downloading ${event.filename}...'
		}
		.download_db_done {
			'    downloaded ${event.filename}'
		}
		.hook_start {
			':: Running hooks...'
		}
		.hook_done {
			'    hooks done'
		}
		.hook_run_start {
			colorize('  :: Running hook [${event.hook_name}]...', color_yellow)
		}
		.hook_run_done {
			'    hook [${event.hook_name}] done'
		}
		.optdep_removal_start {
			'checking optional dependencies...'
		}
		.optdep_removal_done {
			'    optional deps checked'
		}
		.database_locked {
			colorize(':: Database locked', color_blue)
		}
		.database_unlocked {
			':: Database unlocked'
		}
		.pacnew_created {
			colorize('${event.from_path} -> ${event.to_path}', color_yellow) +
				': new config file created'
		}
		.pacsave_created {
			colorize('${event.from_path} -> ${event.to_path}', color_yellow) +
				': config file saved'
		}
		.scriptlet_info {
			event.line
		}
		.retrieve_start {
			'retrieving ${event.filename}...'
		}
		.retrieve_done {
			'    retrieved ${event.filename}'
		}
		.pkg_retrieve_done {
			'    retrieved ${event.filename}'
		}
		.pkg_retrieve_failed {
			colorize('    failed to retrieve ${event.filename}', color_red)
		}
		.searching_start {
			'searching...'
		}
		.searching_done {
			'    done'
		}
		else {
			''
		}
	}
	if msg != '' {
		println(msg)
	}
}

// ===========================================================================
// cb_question — handle all 7 interactive question types.
//
// Supports --noconfirm (handle.no_confirm == true), which auto-answers:
//   install_ignorepkg → no   (keep ignoring)
//   replace_pkg       → yes  (do replace)
//   conflict_pkg      → no   (don't remove)
//   corrupted_pkg     → no   (abort)
//   remove_pkgs       → yes  (do remove)
//   select_provider   → no   (reject all)
//   import_key        → no   (don't import)
// ===========================================================================

pub fn cb_question(handle &util.Handle, mut question &util.Question) {
	// ---- auto-answer for --noconfirm ----
	if handle.no_confirm {
		question.answer = match question.typ {
			.replace_pkg, .remove_pkgs { true }
			else { false }
		}
		return
	}

	// ---- interactive prompt ----
	match question.typ {
		.install_ignorepkg {
			prompt := ':: ${question.pkg_name} is in IgnorePkg. Install anyway? [y/N] '
			resp := os.input(prompt).trim_space().to_lower()
			question.answer = resp == 'y' || resp == 'yes'
		}
		.replace_pkg {
			prompt := ':: Replace ${question.old_pkg_name} with ${question.new_pkg_name}? [Y/n] '
			resp := os.input(prompt).trim_space().to_lower()
			question.answer = resp == '' || resp == 'y' || resp == 'yes'
		}
		.conflict_pkg {
			prompt := ':: ${question.conflict_target} and ${question.conflict_pkg} conflict. Remove ${question.conflict_target}? [y/N] '
			resp := os.input(prompt).trim_space().to_lower()
			question.answer = resp == 'y' || resp == 'yes'
		}
		.corrupted_pkg {
			prompt := ':: ${question.corrupted_file} is corrupted. Continue? [y/N] '
			resp := os.input(prompt).trim_space().to_lower()
			question.answer = resp == 'y' || resp == 'yes'
		}
		.remove_pkgs {
			targets := question.remove_targets.join(', ')
			prompt := ':: Remove ${targets}? [Y/n] '
			resp := os.input(prompt).trim_space().to_lower()
			question.answer = resp == '' || resp == 'y' || resp == 'yes'
		}
		.select_provider {
			println(':: Provider for ${question.dep_name}:')
			for i, prov in question.providers {
				println('  ${i + 1}) ${prov}')
			}
			prompt := ':: Select a provider [1..${question.providers.len}] (or 0 to cancel): '
			resp := os.input(prompt).trim_space()
			sel := resp.int()
			// If the user selected a valid option, we set answer=true and the
			// caller (transaction engine) retrieves the selected index from
			// the question's payload. For this stub we accept any valid index.
			if sel >= 1 && sel <= question.providers.len {
				question.answer = true
			} else {
				question.answer = false
			}
		}
		.import_key {
			prompt := ':: Import PGP key ${question.key_id} ("${question.key_owner}")? [y/N] '
			resp := os.input(prompt).trim_space().to_lower()
			question.answer = resp == 'y' || resp == 'yes'
		}
		else {
			question.answer = false
		}
	}
}

// ===========================================================================
// cb_progress — single transaction progress bar.
//
// Shows a progress bar with package name, current/total count, and
// completion percentage.  Suppressed when handle.noprogressbar is true.
// Reference: pacman's cb_progress in callback.c
// ===========================================================================

pub fn cb_progress(handle &util.Handle, pkgname string, percent int, howmany int, current int) {
	if handle.noprogressbar {
		return
	}

	bar := progress_bar(percent, bar_width)

	// Build status line
	mut line := '(${current}/${howmany}) ${bar} ${pkgname}'

	if use_color() {
		mut pct_color := color_green
		if percent < 30 {
			pct_color = color_red
		} else if percent < 70 {
			pct_color = color_yellow
		}
		line = colorize(line, pct_color)
	}

	if percent == 100 {
		println('\r\033[K${line}')
	} else {
		print('\r\033[K${line}')
	}
}

// ===========================================================================
// cb_download — multi-file download display.
//
// Manages concurrent download progress bars using a global tracker.
// On each callback the entire active-download region is redrawn using
// ANSI cursor-up escape sequences (multi-bar display).
//
// When handle.noprogressbar is true, only a single-line download message
// is printed instead of the multi-bar display.
// ===========================================================================

// ---------------------------------------------------------------------------
// Global download display state
// ---------------------------------------------------------------------------

struct DownloadState {
	filename string
mut:
	pct    int
	xfered u64
	total  u64
}

__global (
	dl_active  []DownloadState // currently downloading files
	dl_prev_ln int            // lines used in previous redraw
)

fn init() {
	dl_active = []DownloadState{}
	dl_prev_ln = 0
}

// ---------------------------------------------------------------------------
// Public callback
// ---------------------------------------------------------------------------

// cb_download handles per-file download progress.
// event.typ discriminates init / progress / completed.
//
// In multi-bar mode (default):
//
//	Shows a compact progress bar per file, redrawing the entire download
//	region on every callback.  Multi-line display via \033[A.
//
// With --noprogressbar:
//
//	Prints basic one-line messages (download start / done / failure).
pub fn cb_download(handle &util.Handle, de &util.DownloadEvent) {
	if handle.noprogressbar {
		cb_download_simple(de)
		return
	}
	cb_download_multibar(de)
}

// ---------------------------------------------------------------------------
// Simple mode (--noprogressbar)
// ---------------------------------------------------------------------------

fn cb_download_simple(de &util.DownloadEvent) {
	match de.typ {
		.init {
			println('  downloading ${de.filename}...')
		}
		.completed {
			if de.total > 0 && de.xfered < de.total {
				println('    ${de.filename}: failed')
			} else {
				println('    ${de.filename}: done')
			}
		}
		.progress {
			// no output in simple mode
		}
	}
}

// ---------------------------------------------------------------------------
// Multi-bar mode
// ---------------------------------------------------------------------------

fn cb_download_multibar(de &util.DownloadEvent) {
	match de.typ {
		.init {
			// Add new download to the active list
			dl_active << DownloadState{
				filename: de.filename
				pct:      0
				xfered:   0
				total:    de.total
			}
		}
		.progress {
			// Update progress for an existing download
			for mut d in dl_active {
				if d.filename == de.filename {
					// Avoid division by zero
					if de.total > 0 {
						d.pct = int(de.xfered * 100 / de.total)
					} else {
						d.pct = -1
					}
					d.xfered = de.xfered
					d.total = de.total
					break
				}
			}
		}
		.completed {
			// Remove completed download from the active list
			for i, d in dl_active {
				if d.filename == de.filename {
					dl_active.delete(i)
					break
				}
			}
		}
	}

	redraw_downloads()
}

// ---------------------------------------------------------------------------
// Redraw engine
// ---------------------------------------------------------------------------

// redraw_downloads clears and re-renders the entire multi-bar download region.
fn redraw_downloads() {
	n := dl_active.len

	// If there are no active downloads, clear the display region and return.
	if n == 0 {
		if dl_prev_ln > 0 {
			// Move cursor up to the first download line and clear each line
			for i in 0 .. dl_prev_ln {
				print('\r\033[K')
				if i < dl_prev_ln - 1 {
					print('\n')
				}
			}
			// Move cursor back to the original position
			if dl_prev_ln > 1 {
				print('\033[${dl_prev_ln - 1}A')
			}
			dl_prev_ln = 0
		}
		return
	}

	// Move cursor up to the first download line (only if we had rendered before)
	if dl_prev_ln > 0 {
		print('\033[${dl_prev_ln}A')
	}

	// Redraw each active download
	for i, d in dl_active {
		bar := progress_bar(d.pct, bar_width)

		mut line := ''
		if d.total > 0 {
			line = '${bar} ${d.filename} (${format_size(d.xfered)}/${format_size(d.total)})'
		} else {
			line = '${bar} ${d.filename}'
		}

		print('\r\033[K${line}')
		if i < n - 1 {
			print('\n')
		}
	}

	// If the line count decreased, clear leftover lines from the previous render
	if n < dl_prev_ln {
		for _ in n .. dl_prev_ln {
			print('\n\033[K')
		}
		// Move cursor back up past the cleared lines
		print('\033[${dl_prev_ln - n}A')
	}

	// Move cursor back to the first download line for the next redraw
	if n > 1 {
		print('\033[${n - 1}A')
	}

	dl_prev_ln = n
}
