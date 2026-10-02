module trans

import os

// Architecture matching decides whether a package may be installed at all:
// prepare() rejects the whole transaction on a mismatch, and release() then
// empties the package list, so a wrong answer here shows up as a silent
// "nothing to do".
fn test_arch_is_supported_auto_accepts_the_machine_family() {
	machine := os.uname().machine
	assert arch_is_supported(machine, ['auto']) == true
	// psABI variant of the machine's own architecture (CachyOS x86_64_v4 on
	// an x86_64 host): pacman accepts these under Architecture = auto.
	assert arch_is_supported(machine + '_v4', ['auto']) == true
	assert arch_is_supported(machine + '_v3', ['auto']) == true
	// Any architecture and an empty arch field are always installable.
	assert arch_is_supported('any', []) == true
	assert arch_is_supported('', []) == true
}

fn test_arch_is_supported_rejects_other_families_under_auto() {
	machine := os.uname().machine
	other := if machine == 'x86_64' { 'aarch64' } else { 'x86_64' }
	assert arch_is_supported(other, ['auto']) == false
	assert arch_is_supported(other + '_v4', ['auto']) == false
}

fn test_arch_is_supported_explicit_configuration_is_exact() {
	machine := os.uname().machine
	assert arch_is_supported(machine, [machine]) == true
	// An explicitly configured architecture is a restriction, not a family
	// wildcard: naming x86_64 does not admit x86_64_v4 builds.
	assert arch_is_supported(machine + '_v4', [machine]) == false
	assert arch_is_supported(machine + '_v4', [machine, machine + '_v4']) == true
	assert arch_is_supported('noarch', ['auto']) == false
}

fn test_arch_family_strips_only_psabi_levels() {
	assert arch_family('x86_64_v4') == 'x86_64'
	assert arch_family('x86_64_v2') == 'x86_64'
	assert arch_family('x86_64') == 'x86_64'
	assert arch_family('aarch64') == 'aarch64'
	// Not a level suffix — leave non-numeric tails alone.
	assert arch_family('armv7h') == 'armv7h'
	assert arch_family('x86_64_vanilla') == 'x86_64_vanilla'
}
