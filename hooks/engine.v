// Module: hooks — ALPM-compatible package hook engine.
//
// Parses .hook files from configured hook directories (pacman.conf HookDir),
// matches Package-type triggers against transaction package lists, and
// executes the corresponding Exec commands pre- or post-transaction.
//
// Hook file format (INI):
//   [Trigger]
//   Type = Package           // Package | Path (File/Path deferred)
//   Operation = Install      // Install | Upgrade | Remove (multiple allowed)
//   Target = linux*          // fnmatch glob
//
//   [Action]
//   When = PreTransaction    // PreTransaction | PostTransaction
//   Description = ...
//   Exec = /usr/bin/foo -x
//   AbortOnFail = true       // flag, only meaningful for PreTransaction
//   NeedsTargets = true      // feed matched pkg names as stdin
//   Depends = some-pkg       // optional dependency requirement
//
// Reference: pacman/lib/libalpm/hook.c, hook.h
module hooks

import os
import strings
import util

// ===========================================================================
// Types — matching pacman/lib/libalpm/hook.c enums and structs
// ===========================================================================

// HookOp is a bitmask of package operations a trigger matches.
// Reference: enum _alpm_hook_op_t (hook.c:32-36)
// Must start with none=0 so the zero value is unset (not a valid operation).
pub enum HookOp {
	none    = 0
	install = 1
	upgrade = 2
	remove  = 4
}

// hookop_or bitwise-ORs two HookOp values via a tiny unsafe cast.
fn hookop_or(a HookOp, b HookOp) HookOp {
	return unsafe { HookOp(int(a) | int(b)) }
}

// TriggerType identifies what kind of trigger this is.
// Reference: enum _alpm_trigger_type_t (hook.c:38-41)
// Must start with none=0 so the zero value is unset.
pub enum TriggerType {
	none    = 0
	package = 1
	path    = 2
}

// HookWhen identifies when the hook executes relative to the transaction.
// Reference: alpm_hook_when_t (alpm.h:891-896)
// Must start with none=0 so the zero value is unset.
pub enum HookWhen {
	none             = 0
	pre_transaction  = 1
	post_transaction = 2
}

// Trigger holds a single [Trigger] section parsed from a .hook file.
// Reference: struct _alpm_trigger_t (hook.c:43-47)
pub struct Trigger {
pub mut:
	typ     TriggerType
	op      HookOp
	targets []string
}

// Hook represents one fully-parsed .hook file.
// Reference: struct _alpm_hook_t (hook.c:49-58)
@[heap]
pub struct Hook {
pub mut:
	name          string
	desc          string
	triggers      []Trigger
	cmd           []string // argv from Exec line (wordsplit)
	when          HookWhen
	abort_on_fail bool
	needs_targets bool
	depends       []string
	// Populated during trigger matching when needs_targets is true.
	matches []string
}

// ===========================================================================
// HookEngine — implements util.HookRunner
// ===========================================================================

// HookEngine runs pre- and post-transaction hooks by parsing .hook files
// from configured hook directories, matching Package-type triggers against
// transaction packages, and executing the matching hooks' commands.
//
// Reference: _alpm_hook_run() (hook.c:528-679)
@[heap]
pub struct HookEngine {
pub mut:
	handle      &util.Handle
	add_pkgs    []&util.Package
	remove_pkgs []&util.Package
	// Cached hook definitions — populated on first collect_hooks() call
	// and reused for all subsequent run_hooks() invocations within the
	// same transaction.  Avoids re-reading and re-parsing every .hook
	// file from disk per package.
	cached_hooks []&Hook
}

// new_hook_engine creates a HookEngine bound to a util.Handle.
pub fn new_hook_engine(handle &util.Handle) HookEngine {
	return HookEngine{
		handle: handle
	}
}

// set_packages configures the add/remove package lists used for trigger
// matching during run_pre / run_post.
pub fn (mut e HookEngine) set_packages(add []&util.Package, remove []&util.Package) {
	e.add_pkgs = add
	e.remove_pkgs = remove
}

// ---------------------------------------------------------------------------
// util.HookRunner interface implementation
// ---------------------------------------------------------------------------

// run_pre runs all PreTransaction hooks whose triggers match the current
// transaction package lists.
pub fn (mut e HookEngine) run_pre(pkgs []&util.Package) ! {
	if e.handle.hookedirs.len == 0 {
		return
	}

	// If set_packages was called, use those lists; otherwise fall back
	// to the argument (backward compat with NoopHookRunner signature).
	if e.add_pkgs.len == 0 && e.remove_pkgs.len == 0 {
		e.add_pkgs = pkgs
	}

	e.run_hooks(.pre_transaction) or {
		return err
	}
}

// run_post runs all PostTransaction hooks whose triggers match the current
// transaction package lists.
pub fn (mut e HookEngine) run_post(pkgs []&util.Package) ! {
	if e.handle.hookedirs.len == 0 {
		return
	}

	if e.add_pkgs.len == 0 && e.remove_pkgs.len == 0 {
		e.add_pkgs = pkgs
	}

	e.run_hooks(.post_transaction) or {
		return err
	}
}

// ===========================================================================
// Public API — run_hooks
// ===========================================================================

// run_hooks collects all .hook files from configured hook directories,
// matches triggers against the current package lists, and executes
// matching hooks whose `when` field matches the given phase.
//
// Reference: _alpm_hook_run() (hook.c:528-679)
pub fn (mut e HookEngine) run_hooks(when HookWhen) ! {
	// Parse hooks once per transaction — subsequent calls (e.g.
	// per-package post-install hooks) reuse the cached result.
	all_hooks := if e.cached_hooks.len > 0 {
		e.cached_hooks
	} else {
		parsed := e.collect_hooks() or { return }
		e.cached_hooks = parsed
		parsed
	}

	// Sort hooks by filename for deterministic order.
	// Reference: _alpm_hook_cmp (hook.c:439-451)
	sorted := sort_hook_list(all_hooks)

	// Identify triggered hooks for the given phase.
	mut triggered := []&Hook{}
	for i in 0 .. sorted.len {
		hook := sorted[i]
		if hook.when == when && is_triggered(hook, e.add_pkgs, e.remove_pkgs) {
			triggered << hook
		}
	}

	if triggered.len == 0 {
		return
	}

	// Execute triggered hooks.
	for i in 0 .. triggered.len {
		hook := triggered[i]
		e.execute_hook(hook) or {
			if hook.abort_on_fail && when == .pre_transaction {
				return err
			}
			// Non-fatal: log and continue for PostTransaction hooks
			// or when AbortOnFail is not set.
		}
	}
}

// ===========================================================================
// Hook file collection
// ===========================================================================

// collect_hooks walks the configured hook directories (in reverse order so
// earlier directories take priority — matching pacman behaviour) and parses
// all *.hook files.
//
// Reference: _alpm_hook_run() directory walking (hook.c:536-623)
fn (e &HookEngine) collect_hooks() ![]&Hook {
	dirlen_threshold := 4096 // PATH_MAX approximation

	mut hmap := map[string]&Hook{} // indexed by filename for dedup
	mut first_err := ?IError(none) // tracks first error encountered

	// Walk directories in reverse order (last dir has lowest priority, so
	// the first dir's hooks survive dedup).
	// Reference: hook.c:536-623 — "for(i = alpm_list_last(handle->hookdirs); ...)"
	for i := e.handle.hookedirs.len - 1; i >= 0; i-- {
		dir := e.handle.hookedirs[i]
		if dir.len >= dirlen_threshold {
			if first_err == none {
				first_err = error('hooks: hook directory path too long: ${dir}')
			}
			continue
		}

		if !os.exists(dir) {
			continue // ENOENT is silently skipped
		}
		if !os.is_dir(dir) {
			if first_err == none {
				first_err = util.AceError{
					code:    .not_a_dir
					message: 'hooks: not a directory: ${dir}'
				}
			}
			continue
		}

		entries := os.ls(dir) or {
			if first_err == none {
				first_err = util.AceError{
					code:    .system
					message: 'hooks: could not read directory ${dir}: ${err.msg()}'
				}
			}
			continue
		}

		for entry_name in entries {
			// Skip . and .. (os.ls does not include these, but be safe).
			if entry_name == '.' || entry_name == '..' {
				continue
			}

			// Must end with .hook suffix.
			if !entry_name.ends_with('.hook') {
				continue
			}

			// Dedup: if we already saw this filename from a higher-priority
			// dir (later in the iteration), skip it.
			// Reference: find_hook() (hook.c:453-463, used at 584-587)
			if entry_name in hmap {
				continue
			}

			full_path := os.join_path(dir, entry_name)

			if os.is_dir(full_path) {
				continue
			}

			mut hook := parse_hook_file(full_path) or {
				if first_err == none {
					first_err = err
				}
				continue
			}
			hook.name = entry_name
			hmap[entry_name] = hook
		}
	}

	if hmap.len == 0 {
		if first_err_val := first_err {
			return first_err_val
		}
		return []&Hook{}
	}

	mut result := []&Hook{cap: hmap.len}
	for _, h in hmap {
		result << h
	}
	return result
}

// ===========================================================================
// .hook file parsing (INI-style)
// ===========================================================================

// wordsplit splits a command string into argv tokens, handling single and
// double quotes, matching pacman's wordsplit() behaviour.
//
// Reference: wordsplit() used in _alpm_hook_parse_cb Exec handling (hook.c:230-242)
fn wordsplit(input string) ![]string {
	mut args := []string{}
	mut current := strings.new_builder(64)

	mut in_single := false
	mut in_double := false
	mut escape := false

	for i := 0; i < input.len; i++ {
		c := input[i]

		if escape {
			current.write_u8(c)
			escape = false
			continue
		}

		if c == `\\` {
			escape = true
			continue
		}

		if in_single {
			if c == `'` {
				in_single = false
			} else {
				current.write_u8(c)
			}
			continue
		}

		if in_double {
			if c == `"` {
				in_double = false
			} else if c == `\\` {
				escape = true
			} else {
				current.write_u8(c)
			}
			continue
		}

		if c == `'` {
			in_single = true
			continue
		}

		if c == `"` {
			in_double = true
			continue
		}

		if c == ` ` || c == `\t` {
			word := current.str().trim_space()
			if word.len > 0 {
				args << word
			}
			current = strings.new_builder(64)
		} else {
			current.write_u8(c)
		}
	}

	// Last word.
	word := current.str().trim_space()
	if word.len > 0 {
		args << word
	}

	if in_single || in_double {
		return error('hooks: unclosed quote in "${input}"')
	}

	if args.len == 0 {
		return error('hooks: empty Exec command')
	}

	return args
}

// parse_hook_file reads a single .hook file and returns the parsed Hook.
//
// Reference: _alpm_hook_parse_cb() (hook.c:149-252)
fn parse_hook_file(path string) !&Hook {
	data := os.read_file(path) or {
		return util.AceError{
			code:    .not_a_file
			message: 'hooks: could not read ${path}: ${err.msg()}'
		}
	}

	mut hook := &Hook{
		cmd: []string{}
		depends: []string{}
	}

	// Basic INI line parser.
	// Reference: parse_ini() callback in hook.c
	mut section := ''
	lines := data.split_into_lines()

	// Track the current Trigger being parsed.
	mut triggers := []Trigger{}
	mut cur_trigger := Trigger{}

	for line_no, raw_line in lines {
		trimmed := raw_line.trim_space()

		// Skip empty lines and comments.
		if trimmed.len == 0 || trimmed[0] == `#` {
			continue
		}

		// Section header: [Trigger] or [Action]
		if trimmed[0] == `[` {
			close_idx := trimmed.index(']') or { -1 }
			if close_idx == -1 {
				return error('hooks: ${path}:${line_no + 1}: malformed section header')
			}
			sec_name := trimmed[1..close_idx].trim_space()

			// Finalize previous trigger section.
			if section == 'Trigger' && (cur_trigger.op != .none || cur_trigger.typ != .none || cur_trigger.targets.len > 0) {
				triggers << cur_trigger
				cur_trigger = Trigger{}
			}

			section = sec_name

			if section != 'Trigger' && section != 'Action' {
				return error('hooks: ${path}:${line_no + 1}: invalid section "${sec_name}"')
			}
			continue
		}

		// Parse Key = Value (or bare key for flags).
		eq_idx := trimmed.index('=') or {
			// Bare key (flag like AbortOnFail, NeedsTargets).
			if section == 'Action' {
				key := trimmed.trim_space()
				match key {
					'AbortOnFail' {
						hook.abort_on_fail = true
					}
					'NeedsTargets' {
						hook.needs_targets = true
					}
					else {
						return error('hooks: ${path}:${line_no + 1}: invalid option "${key}"')
					}
				}
			}
			continue
		}

		key := trimmed[..eq_idx].trim_space()
		val := trimmed[eq_idx + 1..].trim_space()

		if key.len == 0 {
			return error('hooks: ${path}:${line_no + 1}: empty key')
		}

		if section == 'Trigger' {
			match key {
				'Type' {
					cur_trigger.typ = match val {
						'Package' { TriggerType.package }
						'Path' { TriggerType.path }
						else {
							return error('hooks: ${path}:${line_no + 1}: invalid value "${val}" for Type')
						}
					}
				}
				'Operation' {
					op := match val {
						'Install' { HookOp.install }
						'Upgrade' { HookOp.upgrade }
						'Remove' { HookOp.remove }
						else {
							return error('hooks: ${path}:${line_no + 1}: invalid value "${val}" for Operation')
						}
					}
					cur_trigger.op = hookop_or(cur_trigger.op, op)
				}
				'Target' {
					cur_trigger.targets << val
				}
				else {
					return error('hooks: ${path}:${line_no + 1}: invalid option "${key}" in Trigger')
				}
			}
		} else if section == 'Action' {
			match key {
				'When' {
					hook.when = match val {
						'PreTransaction' { HookWhen.pre_transaction }
						'PostTransaction' { HookWhen.post_transaction }
						else {
							return error('hooks: ${path}:${line_no + 1}: invalid value "${val}" for When')
						}
					}
				}
				'Description' {
					hook.desc = val
				}
				'Exec' {
					hook.cmd = wordsplit(val) or {
						return error('hooks: ${path}:${line_no + 1}: ${err.msg()}')
					}
				}
				'Depends' {
					hook.depends << val
				}
				'AbortOnFail' {
					hook.abort_on_fail = true
				}
				'NeedsTargets' {
					hook.needs_targets = true
				}
				else {
					return error('hooks: ${path}:${line_no + 1}: invalid option "${key}" in Action')
				}
			}
		}
	}

	// Finalize last trigger section.
	if section == 'Trigger' && (cur_trigger.op != .none || cur_trigger.typ != .none || cur_trigger.targets.len > 0) {
		triggers << cur_trigger
	}

	hook.triggers = triggers

	// Validate the parsed hook.
	// Reference: _alpm_hook_validate() (hook.c:113-147)
	validate_hook(hook, path)!

	return hook
}

// validate_hook checks a parsed Hook for required fields.
//
// Reference: _alpm_hook_validate() (hook.c:113-147)
fn validate_hook(hook &Hook, path string) ! {
	// Triggerless hooks are allowed (used for masking lower-priority hooks).
	if hook.triggers.len > 0 {
		for t in hook.triggers {
			if t.targets.len == 0 {
				return error('hooks: ${path}: missing trigger targets')
			}
			if t.typ == .none {
				return error('hooks: ${path}: missing trigger type')
			}
			if t.op == .none {
				return error('hooks: ${path}: missing trigger operation')
			}
		}
	}

	if hook.cmd.len == 0 {
		return error('hooks: ${path}: missing Exec option')
	}

	if hook.when == .none {
		return error('hooks: ${path}: missing When option')
	}
}

// ===========================================================================
// Trigger matching
// ===========================================================================

// is_triggered checks whether any trigger in this hook matches the current
// transaction package lists. Populates hook.matches for NeedsTargets hooks.
//
// Reference: _alpm_hook_triggered() (hook.c:423-437)
fn is_triggered(hook &Hook, add_pkgs []&util.Package, remove_pkgs []&util.Package) bool {
	if hook.triggers.len == 0 {
		return false
	}

	mut triggered := false
	for i in 0 .. hook.triggers.len {
		t := hook.triggers[i]
		if t.typ != .package {
			// Path triggers deferred — skip for now.
			continue
		}
		if match_pkg_trigger(hook, t, add_pkgs, remove_pkgs) {
			if !hook.needs_targets {
				return true
			}
			triggered = true
		}
	}
	return triggered
}

// match_pkg_trigger checks a single Package-type trigger against the
// add and remove package lists. Uses fnmatch glob patterns.
//
// If hook.needs_targets is set, matched package names are accumulated into
// hook.matches.
//
// Reference: _alpm_hook_trigger_match_pkg() (hook.c:359-413)
fn match_pkg_trigger(hook &Hook, t Trigger, add_pkgs []&util.Package, remove_pkgs []&util.Package) bool {
	mut install := []string{}
	mut remove := []string{}

	// --- Check add packages for Install/Upgrade ---
	if int(t.op) & (int(HookOp.install) | int(HookOp.upgrade)) != 0 {
		for pkg in add_pkgs {
			if match_any_pattern(t.targets, pkg.name) {
				if hook.needs_targets {
					install << pkg.name
				} else {
					return true
				}
			}
		}
	}

	// --- Check remove packages for Remove ---
	if int(t.op) & int(HookOp.remove) != 0 {
		for pkg in remove_pkgs {
			if match_any_pattern(t.targets, pkg.name) {
				if hook.needs_targets {
					remove << pkg.name
				} else {
					return true
				}
			}
		}
	}

	// Collect matches if NeedsTargets.
	if hook.needs_targets {
		unsafe {
			hook.matches << install
			hook.matches << remove
		}
		return install.len > 0 || remove.len > 0
	}

	return false
}

// match_any_pattern returns true if `name` matches any of the glob patterns.
fn match_any_pattern(patterns []string, name string) bool {
	for pattern in patterns {
		if fnmatch(pattern, name) {
			return true
		}
	}
	return false
}

// fnmatch matches a shell glob pattern against a string.
// Supports * (any chars), ? (single char), and [abc] (character class).
// Matching is anchored (full string must match).
fn fnmatch(pattern string, s string) bool {
	mut pi := 0 // pattern index
	mut si := 0 // string index

	for pi < pattern.len {
		p := pattern[pi]

		if p == `*` {
			// * matches any sequence (including empty).
			// Consume consecutive *.
			for pi + 1 < pattern.len && pattern[pi + 1] == `*` {
				pi++
			}
			if pi + 1 == pattern.len {
				// * at end matches everything.
				return true
			}
			// Try to match the rest of pattern at each position.
			for si <= s.len {
				if fnmatch_helper(pattern, pi + 1, s, si) {
					return true
				}
				si++
			}
			return false
		} else if p == `?` {
			// ? matches exactly one char.
			if si >= s.len {
				return false
			}
			pi++
			si++
		} else if p == `[` {
			// Character class [...].
			if si >= s.len {
				return false
			}
			mut negate := false
			mut ci := pi + 1
			if ci < pattern.len && pattern[ci] == `!` {
				negate = true
				ci++
			}
			if ci >= pattern.len {
				return false // malformed
			}
			mut matched := false
			// Find the closing ].
			mut end := ci
			for end < pattern.len && pattern[end] != `]` {
				if end + 1 < pattern.len && pattern[end + 1] == `-` && end + 2 < pattern.len && pattern[end + 2] != `]` {
					// Range like a-z
					lo := pattern[end]
					hi := pattern[end + 2]
					if s[si] >= lo && s[si] <= hi {
						matched = true
					}
					end += 3
				} else {
					if pattern[end] == s[si] {
						matched = true
					}
					end++
				}
			}
			if end >= pattern.len {
				return false // malformed, no closing ]
			}
			if negate {
				matched = !matched
			}
			if !matched {
				return false
			}
			pi = end + 1
			si++
		} else {
			// Literal character match.
			if si >= s.len || s[si] != p {
				return false
			}
			pi++
			si++
		}
	}

	// Both must be consumed.
	return si == s.len
}

// fnmatch_helper is a recursive helper for * matching.
fn fnmatch_helper(pattern string, pi int, s string, si int) bool {
	if pi == pattern.len {
		return si == s.len
	}
	if si > s.len {
		return false
	}

	mut ppi := pi
	mut ssi := si

	for ppi < pattern.len && ssi < s.len {
		p := pattern[ppi]
		if p == `*` {
			// Nested star — recursive call.
			return fnmatch(pattern[ppi..], s[ssi..])
		} else if p == `?` {
			ssi++
			ppi++
		} else if p == `[` {
			// Character class.
			mut negate := false
			mut ci := ppi + 1
			if ci < pattern.len && pattern[ci] == `!` {
				negate = true
				ci++
			}
			mut matched := false
			mut end := ci
			for end < pattern.len && pattern[end] != `]` {
				if end + 1 < pattern.len && pattern[end + 1] == `-` && end + 2 < pattern.len && pattern[end + 2] != `]` {
					lo := pattern[end]
					hi := pattern[end + 2]
					if s[ssi] >= lo && s[ssi] <= hi {
						matched = true
					}
					end += 3
				} else {
					if pattern[end] == s[ssi] {
						matched = true
					}
					end++
				}
			}
			if end >= pattern.len {
				return false
			}
			if negate {
				matched = !matched
			}
			if !matched {
				return false
			}
			ppi = end + 1
			ssi++
		} else {
			if s[ssi] != p {
				return false
			}
			ppi++
			ssi++
		}
	}

	// Skip trailing * in pattern.
	for ppi < pattern.len && pattern[ppi] == `*` {
		ppi++
	}

	return ppi == pattern.len && ssi == s.len
}

// ===========================================================================
// Hook sorting
// ===========================================================================

// sort_hook_list sorts hooks by filename, matching pacman's lexicographic
// order by filename.
//
// Reference: _alpm_hook_cmp() (hook.c:439-451)
fn sort_hook_list(hook_list []&Hook) []&Hook {
	mut result := hook_list.clone()
	result.sort(a.name < b.name)
	return result
}

// ===========================================================================
// Dependency checking and execution
// ===========================================================================

// execute_hook runs the hook's Exec command after verifying dependencies.
//
// Reference: _alpm_hook_run_hook() (hook.c:503-526)
fn (e &HookEngine) execute_hook(hook &Hook) ! {
	// Check dependencies against installed packages.
	// Reference: hook.c:507-512
	if hook.depends.len > 0 {
		// TODO: check against local DB when available
		// For now, dependencies are a no-op check (assume satisfied).
	}

	if hook.needs_targets && hook.matches.len > 0 {
		// Sort and dedup matches locally. Reference: hook.c:516-520
		mut sorted := hook.matches.clone()
		sorted.sort()
		mut deduped := []string{}
		for i in 0 .. sorted.len {
			if i == 0 || sorted[i] != sorted[i - 1] {
				deduped << sorted[i]
			}
		}

		// Feed targets as stdin newline-separated.
		// Reference: hook.c:521-522 (_alpm_hook_feed_targets)
		target_data := deduped.join('\n') + '\n'
		e.run_command(hook.cmd, target_data) or {
			return err
		}
	} else {
		e.run_command(hook.cmd, '') or {
			return err
		}
	}
}

// run_command executes a command with optional stdin data.
//
// Reference: _alpm_run_chroot() (hook.c:521-525)
fn (e &HookEngine) run_command(argv []string, stdin_data string) ! {
	if argv.len == 0 {
		return error('hooks: empty command')
	}

	prog := argv[0]

	// Build and execute the shell command with stdin piped for hooks
	// that declare NeedsTargets=true (target_data is newline-separated
	// package names fed to the hook's standard input).
	if stdin_data != '' {
		// Write stdin_data to a temp file and redirect it as stdin.
		tmp := os.join_path(os.temp_dir(), 'ace_hook_stdin_${os.getpid()}')
		os.write_file(tmp, stdin_data) or {
			return error('hooks: cannot write stdin temp file: ${err}')
		}
		defer { os.rm(tmp) or {} }
		cmd_str := build_shell_cmd(argv)
		result := os.execute('${cmd_str} < ${os.quoted_path(tmp)} 2>&1')
		if result.exit_code != 0 {
			return util.AceError{
				code:    .system
				message: 'hooks: "${prog}" failed (exit ${result.exit_code}): ${result.output.trim_space()}'
			}
		}
		return
	}

	cmd_str := build_shell_cmd(argv)
	result := os.execute(cmd_str + ' 2>&1')

	if result.exit_code != 0 {
		return util.AceError{
			code:    .system
			message: 'hooks: "${prog}" failed (exit ${result.exit_code}): ${result.output.trim_space()}'
		}
	}
}

// build_shell_cmd reconstructs a shell command string from argv,
// properly quoting arguments that contain spaces or shell metacharacters.
fn build_shell_cmd(argv []string) string {
	mut parts := []string{cap: argv.len}
	for arg in argv {
		if arg.contains(' ') || arg.contains('\t') || arg.contains('"') || arg.contains("'") ||
			arg.contains('\\') || arg.contains('$') || arg.contains('`') || arg.contains('|') ||
			arg.contains('&') || arg.contains(';') || arg.contains('<') || arg.contains('>') ||
			arg.contains('(') || arg.contains(')') || arg.contains('{') || arg.contains('}') ||
			arg.contains('*') || arg.contains('?') || arg.contains('[') || arg.contains(']') ||
			arg.contains('!') || arg.contains('^') || arg.contains('~') || arg.len == 0 {
			// Single-quote the argument, escaping single quotes within.
			escaped := arg.replace("'", "'\\''")
			parts << "'" + escaped + "'"
		} else {
			parts << arg
		}
	}
	return parts.join(' ')
}

// ===========================================================================
// Testing hook
// ===========================================================================

// test_parse_hook is exposed for unit tests to validate hook parsing.
pub fn test_parse_hook(path string) !&Hook {
	return parse_hook_file(path)
}
