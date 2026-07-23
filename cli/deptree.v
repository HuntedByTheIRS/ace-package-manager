// --deptree — display a recursive dependency tree for a package.
// Shows architecture, install reason, description, version constraints,
// satisfaction status, and optional/build-time dependency subtrees.
module cli

import db
import os
import util

pub fn run_deptree(args &CliArgs, handle &util.Handle) ! {
	if args.targets.len == 0 {
		return error('--deptree requires a package name')
	}

	dbpath := if args.root != '' {
		os.join_path(args.root, if args.dbpath != '' { args.dbpath } else { 'var/lib/ace' })
	} else if args.dbpath != '' {
		args.dbpath
	} else {
		handle.resolved_dbpath()
	}

	mut local_db := db.init(dbpath)!
	local_db.populate()!

	pkgname := args.targets[0]
	p := local_db.pkgcache[pkgname] or {
		return error('package "${pkgname}" is not installed')
	}

	// Root package header.
	println(header_str(p))
	mut visited := map[string]bool{}
	// Required dependencies.
	if p.depends.len > 0 {
		println('  ${dim_str('Required dependencies:')}')
		print_dep_tree(p.depends, &local_db, '    ', mut visited, 0)
	}
	// Optional dependencies.
	if p.optdepends.len > 0 {
		println('  ${dim_str('Optional dependencies:')}')
		print_dep_tree(p.optdepends, &local_db, '    ', mut visited, 0)
	}
	// Build-time dependencies.
	if p.makedepends.len > 0 {
		println('  ${dim_str('Build dependencies:')}')
		print_dep_tree(p.makedepends, &local_db, '    ', mut visited, 0)
	}
}

// print_dep_tree recursively renders a dependency list with tree connectors.
fn print_dep_tree(deps []db.Dependency, local_db &db.LocalDB, prefix string, mut visited map[string]bool, depth int) {
	if depth > 10 {
		println('${prefix}${dim_str('... (max depth)')}')
		return
	}
	for i, dep in deps {
		last := i == deps.len - 1
		connector := if last { '└── ' } else { '├── ' }
		child_prefix := prefix + if last { '    ' } else { '│   ' }

		dep_str := format_dep_verbose(dep)
		if child := local_db.pkgcache[dep.name] {
			// Check version satisfaction.
			sat := dep_satisfied_by(child, dep)
			sat_str := if sat { ok_str(' [satisfied]') } else { warn_str(' [installed ${child.version} does not satisfy]') }
			println('${prefix}${connector}${dep_str}${sat_str} ${info_str(child)}')
			if !(dep.name in visited) {
				visited[dep.name] = true
				// Recurse into child's required deps only.
				if child.depends.len > 0 && !sat {
					print_dep_tree(child.depends, local_db, child_prefix, mut visited, depth + 1)
				}
			}
		} else {
			println('${prefix}${connector}${dep_str} ${dim_str('[not installed]')}')
		}
	}
}

// header_str formats the root package header with name, version, arch,
// install reason, and description.
fn header_str(pkg &db.Package) string {
	mut out := '${bold_red_str(pkg.name)} ${ver_str(pkg.version)}'
	if pkg.arch != '' {
		out += ' ${arch_str(pkg.arch)}'
	}
	reason := match pkg.reason {
		.explicit { ok_str('[explicit]') }
		.depend { dim_str('[auto]') }
		.unknown { '' }
	}
	out += ' ${reason}'
	if pkg.desc != '' {
		out += '\n  ${dim_str(pkg.desc)}'
	}
	return out
}

// info_str formats architecture and auto/explicit marker for tree children.
fn info_str(pkg &db.Package) string {
	mut out := ''
	if pkg.arch != '' {
		out += '${arch_str(pkg.arch)} '
	}
	match pkg.reason {
		.explicit { out += ok_str('[explicit]') }
		.depend { out += dim_str('[auto]') }
		.unknown {}
	}
	return out
}

// dep_satisfied_by checks whether an installed package satisfies a dependency's
// version constraint.
fn dep_satisfied_by(pkg &db.Package, dep db.Dependency) bool {
	if dep.modifier == .any || dep.version == '' {
		return true
	}
	cmp := util.vercmp(pkg.version, dep.version)
	return match dep.modifier {
		.eq { cmp == 0 }
		.ge { cmp >= 0 }
		.le { cmp <= 0 }
		.gt { cmp > 0 }
		.lt { cmp < 0 }
		.any { true }
	}
}

// format_dep_verbose formats a dependency with name, version constraint,
// and description (for optdepends).
fn format_dep_verbose(dep db.Dependency) string {
	mut out := bold_red_str(dep.name)
	op := match dep.modifier {
		.any { '' }
		.eq { '=' }
		.ge { '>=' }
		.le { '<=' }
		.gt { '>' }
		.lt { '<' }
	}
	if op != '' && dep.version != '' {
		out += ver_str('${op}${dep.version}')
	}
	return out
}

// ---- ANSI helpers ----
fn bold_red_str(s string) string { if !use_color() { return s } return '\033[1m\033[38;5;160m${s}\033[0m' }
fn ver_str(s string) string { if !use_color() { return s } return '\033[38;5;160m${s}\033[0m' }
fn dim_str(s string) string { if !use_color() { return s } return '\033[38;5;245m${s}\033[0m' }
fn arch_str(s string) string { if !use_color() { return s } return '\033[38;5;35m${s}\033[0m' }
fn ok_str(s string) string { if !use_color() { return s } return '\033[38;5;76m${s}\033[0m' }
fn warn_str(s string) string { if !use_color() { return s } return '\033[38;5;208m${s}\033[0m' }
