module hooks

import os
import util

// Tests for the hooks engine module.

// ---------------------------------------------------------------------------
// fnmatch unit tests
// ---------------------------------------------------------------------------

fn test_fnmatch_exact_match() {
	assert fnmatch('linux', 'linux') == true
	assert fnmatch('mkinitcpio', 'mkinitcpio') == true
	assert fnmatch('', '') == true
}

fn test_fnmatch_wildcard_star() {
	assert fnmatch('linux*', 'linux') == true
	assert fnmatch('linux*', 'linux-6.8') == true
	assert fnmatch('linux*', 'linux-zen') == true
	assert fnmatch('*linux', 'linux') == true
	assert fnmatch('*linux', 'core-linux') == true
}

fn test_fnmatch_wildcard_star_no_match() {
	assert fnmatch('linux*', 'base') == false
	assert fnmatch('mkinitcpio', 'mkinitcpio-utils') == false
	assert fnmatch('*linux', 'linux-zen') == false
}

fn test_fnmatch_question_mark() {
	assert fnmatch('?abc', 'aabc') == true
	assert fnmatch('?bc', 'abc') == true
	assert fnmatch('???', 'abc') == true
	assert fnmatch('?abc', 'abc') == false
	assert fnmatch('??', 'a') == false
}

fn test_fnmatch_character_class() {
	assert fnmatch('[abc]', 'a') == true
	assert fnmatch('[abc]', 'b') == true
	assert fnmatch('[abc]', 'd') == false
}

fn test_fnmatch_negated_class() {
	assert fnmatch('[!abc]', 'd') == true
	assert fnmatch('[!abc]', 'a') == false
}

fn test_fnmatch_mixed_pattern() {
	assert fnmatch('linux*[0-9]', 'linux-6.8') == true
	assert fnmatch('???*', 'abc') == true
}

// ---------------------------------------------------------------------------
// wordsplit unit tests
// ---------------------------------------------------------------------------

fn test_wordsplit_simple() {
	argv := wordsplit('/usr/bin/mkinitcpio -P') or {
		assert false, 'wordsplit failed: ${err}'
		return
	}
	assert argv.len == 2
	assert argv[0] == '/usr/bin/mkinitcpio'
	assert argv[1] == '-P'
}

fn test_wordsplit_quoted() {
	argv := wordsplit("prog 'single quoted' \"double quoted\"") or {
		assert false, 'wordsplit failed: ${err}'
		return
	}
	assert argv.len == 3
	assert argv[0] == 'prog'
	assert argv[1] == 'single quoted'
	assert argv[2] == 'double quoted'
}

fn test_wordsplit_trailing_spaces() {
	argv := wordsplit('/usr/bin/true   ') or {
		assert false, 'wordsplit failed: ${err}'
		return
	}
	assert argv.len == 1
	assert argv[0] == '/usr/bin/true'
}

fn test_wordsplit_unclosed_quote() {
	if argv2 := wordsplit("prog 'unclosed") {
		assert false, 'expected error for unclosed quote, got: ${argv2}'
	}
}

// ---------------------------------------------------------------------------
// .hook file parsing tests
// ---------------------------------------------------------------------------

fn test_parse_hook_basic() {
	tmpdir := os.temp_dir()
	path := os.join_path(tmpdir, 'hook-test-basic.hook')
	content := '[Trigger]\n' +
		'Type = Package\n' +
		'Operation = Install\n' +
		'Operation = Upgrade\n' +
		'Target = linux*\n' +
		'Target = mkinitcpio\n' +
		'\n' +
		'[Action]\n' +
		'When = PostTransaction\n' +
		'Description = Regenerate initramfs\n' +
		'Exec = /usr/bin/mkinitcpio -P\n' +
		'AbortOnFail\n' +
		'NeedsTargets\n' +
		'Depends = mkinitcpio\n'
	os.write_file(path, content) or {
		assert false, 'failed to write temp file: ${err}'
		return
	}
	defer {
		os.rm(path) or {}
	}

	hook := test_parse_hook(path) or {
		assert false, 'parse failed: ${err}'
		return
	}

	assert hook.desc == 'Regenerate initramfs'
	assert hook.when == HookWhen.post_transaction
	assert hook.abort_on_fail == true
	assert hook.needs_targets == true
	assert hook.depends.len == 1
	assert hook.depends[0] == 'mkinitcpio'
	assert hook.cmd.len == 2
	assert hook.cmd[0] == '/usr/bin/mkinitcpio'
	assert hook.cmd[1] == '-P'

	assert hook.triggers.len == 1
	t := hook.triggers[0]
	assert t.typ == TriggerType.package
	assert int(t.op) & int(HookOp.install) != 0
	assert int(t.op) & int(HookOp.upgrade) != 0
	assert t.targets.len == 2
	assert t.targets[0] == 'linux*'
	assert t.targets[1] == 'mkinitcpio'
}

fn test_parse_hook_remove_operation() {
	tmpdir := os.temp_dir()
	path := os.join_path(tmpdir, 'hook-test-remove.hook')
	content := '[Trigger]\n' +
		'Type = Package\n' +
		'Operation = Remove\n' +
		'Target = nvidia*\n' +
		'\n' +
		'[Action]\n' +
		'When = PreTransaction\n' +
		'Exec = /usr/bin/true\n'
	os.write_file(path, content) or {
		assert false, 'failed to write temp file: ${err}'
		return
	}
	defer {
		os.rm(path) or {}
	}

	hook := test_parse_hook(path) or {
		assert false, 'parse failed: ${err}'
		return
	}

	assert hook.when == HookWhen.pre_transaction
	assert hook.triggers.len == 1
	t := hook.triggers[0]
	assert int(t.op) & int(HookOp.remove) != 0
	assert int(t.op) & int(HookOp.install) == 0
}

fn test_parse_hook_missing_exec_fails() {
	tmpdir := os.temp_dir()
	path := os.join_path(tmpdir, 'hook-bad-noexec.hook')
	content := '[Trigger]\n' +
		'Type = Package\n' +
		'Operation = Install\n' +
		'Target = foo\n' +
		'\n' +
		'[Action]\n' +
		'When = PreTransaction\n' +
		'Description = No exec\n'
	os.write_file(path, content) or {
		assert false, 'failed to write temp file: ${err}'
		return
	}
	defer {
		os.rm(path) or {}
	}

	if hook := test_parse_hook(path) {
		assert false, 'expected error for missing Exec, got hook: ${hook.name}'
	}
}

fn test_parse_hook_invalid_section() {
	tmpdir := os.temp_dir()
	path := os.join_path(tmpdir, 'hook-bad-section.hook')
	content := '[Invalid]\n' +
		'Foo = bar\n'
	os.write_file(path, content) or {
		assert false, 'failed to write temp file: ${err}'
		return
	}
	defer {
		os.rm(path) or {}
	}

	if hook := test_parse_hook(path) {
		assert false, 'expected error for invalid section, got: ${hook.name}'
	}
}

// ---------------------------------------------------------------------------
// Trigger matching tests
// ---------------------------------------------------------------------------

fn test_trigger_match_basic() {
	add_pkgs := [&util.Package{
		name:    'linux-6.8'
		version: '6.8.0'
	}]
	remove_pkgs := []&util.Package{}

	hook := &Hook{
		triggers: [
			Trigger{
				typ: .package
				op: HookOp.install
				targets: ['linux*']
			},
		]
	}

    assert is_triggered(hook, add_pkgs, remove_pkgs) == true
}

fn test_trigger_match_no_match() {
	add_pkgs := [&util.Package{
		name:    'base'
		version: '1.0'
	}]
	remove_pkgs := []&util.Package{}

	hook := &Hook{
		triggers: [
			Trigger{
				typ: .package
				op: HookOp.install
				targets: ['linux*']
			},
		]
	}

    assert is_triggered(hook, add_pkgs, remove_pkgs) == false
}

fn test_trigger_match_remove_operation() {
	add_pkgs := []&util.Package{}
	remove_pkgs := [&util.Package{
		name:    'nvidia-utils'
		version: '545.0'
	}]

	hook := &Hook{
		triggers: [
			Trigger{
				typ: .package
				op: HookOp.remove
				targets: ['nvidia*']
			},
		]
	}

    assert is_triggered(hook, add_pkgs, remove_pkgs) == true
}

fn test_trigger_match_remove_no_match() {
	add_pkgs := [&util.Package{
		name:    'nvidia-utils'
		version: '545.0'
	}]
	remove_pkgs := []&util.Package{}

	// Remove trigger should NOT match add_pkgs.
	hook := &Hook{
		triggers: [
			Trigger{
				typ: .package
				op: HookOp.remove
				targets: ['nvidia*']
			},
		]
	}

    assert is_triggered(hook, add_pkgs, remove_pkgs) == false
}

fn test_trigger_match_needs_targets() {
	add_pkgs := [&util.Package{name: 'linux-6.8'}, &util.Package{name: 'linux-firmware'}]
	remove_pkgs := []&util.Package{}

	hook := &Hook{
		needs_targets: true
		triggers: [
			Trigger{
				typ: .package
				op: HookOp.install
				targets: ['linux*']
			},
		]
	}

    assert is_triggered(hook, add_pkgs, remove_pkgs) == true
    assert hook.matches.len == 2
    assert 'linux-6.8' in hook.matches
    assert 'linux-firmware' in hook.matches
}
