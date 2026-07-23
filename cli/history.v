// --history — display human-readable transaction history.
module cli

import os
import util

pub fn run_history(args &CliArgs, handle &util.Handle) ! {
	logfile := if args.logfile != '' {
		args.logfile
	} else if handle.logfile != '' {
		handle.logfile
	} else {
		'/var/log/ace.log'
	}

	if !os.exists(logfile) {
		println(hist_dim('No transaction history found at ${logfile}.'))
		println(hist_dim('Transactions will be logged once ace performs installs or removals.'))
		return
	}

	content := os.read_file(logfile) or {
		return error('cannot read log file: ${err}')
	}

	lines := content.split('\n')
	if lines.len == 0 || (lines.len == 1 && lines[0] == '') {
		println(hist_dim('Transaction log is empty.'))
		return
	}

	println(hist_head('Transaction History'))
	println(hist_dim('─'.repeat(70)))
	println('')

	mut count := 0
	for line in lines {
		if line == '' { continue }
		formatted := format_log_line(line)
		if formatted != '' {
			println(formatted)
			count++
		}
	}

	if count == 0 {
		println(hist_dim('No recognizable transactions found.'))
	} else {
		println('')
		println(hist_dim('${count} transaction(s) logged.'))
	}
}

fn format_log_line(line string) string {
	if !line.starts_with('[') { return '' }
	bracket_end := line.index(']') or { return '' }
	ts := line[1..bracket_end]
	rest := line[bracket_end + 1..].trim_space()
	if !rest.starts_with('[') { return '' }
	rest2 := rest[1..]
	op_end := rest2.index(']') or { return '' }
	op := rest2[..op_end]
	msg := rest2[op_end + 1..].trim_space()
	date_str := format_ts(ts)
	op_str := format_op(op)
	return '${hist_dim(date_str)}  ${op_str} ${msg}'
}

fn format_ts(ts string) string {
	if ts.len < 16 { return ts }
	return '${ts[..10]} ${ts[11..16]}'
}

fn format_op(op string) string {
	return match op {
		'INSTALL' { hist_green('[INSTALL]') }
		'REMOVE'  { hist_yellow('[REMOVE]') }
		'UPGRADE' { hist_red('[UPGRADE]') }
		else { hist_dim('[${op}]') }
	}
}

fn hist_red(s string) string { if !use_color() { return s } return '\033[1m\033[38;5;160m${s}\033[0m' }
fn hist_dim(s string) string { if !use_color() { return s } return '\033[38;5;245m${s}\033[0m' }
fn hist_head(s string) string { if !use_color() { return ':: ${s}' } return '\033[1m\033[38;5;160m::\033[0m \033[1m${s}\033[0m' }
fn hist_green(s string) string { if !use_color() { return s } return '\033[38;5;76m${s}\033[0m' }
fn hist_yellow(s string) string { if !use_color() { return s } return '\033[1m\033[38;5;220m${s}\033[0m' }
