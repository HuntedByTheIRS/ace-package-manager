// --deptree — display a recursive dependency tree for a package.
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

	println(pkg_name_str(p))
	mut visited := map[string]bool{}
	print_tree(p, &local_db, '', true, mut visited, 0)
}

fn print_tree(pkg &db.Package, local_db &db.LocalDB, prefix string, is_last bool, mut visited map[string]bool, depth int) {
	if depth > 10 {
		return
	}
	if pkg.name in visited {
		println('${prefix}${if is_last { '└── ' } else { '├── ' }}${dim_str('${pkg.name} (circular)')}')
		return
	}
	visited[pkg.name] = true

	deps := pkg.depends
	for i, dep in deps {
		last := i == deps.len - 1
		connector := if last { '└── ' } else { '├── ' }
		child_prefix := prefix + if is_last { '    ' } else { '│   ' }

		mut dep_str := format_dep(dep)
		if child := local_db.pkgcache[dep.name] {
			println('${prefix}${connector}${dep_str}')
			mut cv := visited.clone()
			print_tree(child, local_db, child_prefix, last, mut cv, depth + 1)
		} else {
			println('${prefix}${connector}${dim_str(dep_str + ' (not installed)')}')
		}
	}
}

fn format_dep(dep db.Dependency) string {
	op := match dep.modifier {
		.any { '' }
		.eq { '=' }
		.ge { '>=' }
		.le { '<=' }
		.gt { '>' }
		.lt { '<' }
	}
	if op == '' || dep.version == '' {
		return red_str(dep.name)
	}
	return '${red_str(dep.name)}${ver_str('${op}${dep.version}')}'
}

fn pkg_name_str(pkg &db.Package) string {
	return '${red_str(pkg.name)} ${ver_str(pkg.version)}'
}

fn red_str(s string) string { return '\033[1m\033[38;5;160m${s}\033[0m' }
fn ver_str(s string) string { return '\033[38;5;160m${s}\033[0m' }
fn dim_str(s string) string { return '\033[38;5;245m${s}\033[0m' }
