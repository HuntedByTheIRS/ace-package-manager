module main

import cli

fn main() {
	// Parse command-line arguments.
	mut args := cli.parse_args()

	// Load config and initialise Handle with CLI overrides.
	// (Config is loaded at startup per pacman's parsearg_global pattern.)
	init_res := cli.init_from_args(mut args) or {
		eprintln('error: ${err}')
		exit(1)
	}

	// --transfer: migrate pacman data to ace native directories, then exit.
	if args.transfer {
		cli.run_transfer(&args, &init_res.handle) or {
			eprintln('error: ${err}')
			exit(1)
		}
		exit(0)
	}

	// --deptree: display dependency tree, then exit.
	if args.deptree {
		cli.run_deptree(&args, &init_res.handle) or {
			eprintln('error: ${err}')
			exit(1)
		}
		exit(0)
	}

	// --history: display transaction history, then exit.
	if args.show_history {
		cli.run_history(&args, &init_res.handle) or {
			eprintln('error: ${err}')
			exit(1)
		}
		exit(0)
	}

	// --keyring-init: initialize GPG keyring, then exit.
	if args.keyring_init {
		cli.run_keyring_init(&init_res.handle) or {
			eprintln('error: ${err}')
			exit(1)
		}
		exit(0)
	}

	// --keyring-populate: import keyring keys, then exit.
	if args.keyring_populate != '' {
		cli.run_keyring_populate(&init_res.handle, args.keyring_populate) or {
			eprintln('error: ${err}')
			exit(1)
		}
		exit(0)
	}

	// Dispatch operation.
	mut error_occurred := false

	match args.operation {
		.query {
			cli.run_query(&args, &init_res.cfg, &init_res.handle) or {
				eprintln('error: ${err}')
				error_occurred = true
			}
		}
		.deptest {
			cli.run_deptest(&args, &init_res.cfg, &init_res.handle) or {
				eprintln('error: ${err}')
				error_occurred = true
			}
		}
		.remove {
			cli.run_remove(&args, &init_res.cfg, &init_res.handle) or {
				eprintln('error: ${err}')
				error_occurred = true
			}
		}
		.upgrade {
			cli.run_upgrade(&args, &init_res.cfg, &init_res.handle) or {
				eprintln('error: ${err}')
				error_occurred = true
			}
		}
		.sync {
			cli.run_sync(&args, &init_res.cfg, &init_res.handle) or {
				eprintln('error: ${err}')
				error_occurred = true
			}
		}
		.database {
			cli.run_database(&args) or {
				eprintln('error: ${err}')
				error_occurred = true
			}
		}
		.files {
			cli.run_files(&args) or {
				eprintln('error: ${err}')
				error_occurred = true
			}
		}
		.main {
			cli.print_usage()
			exit(0)
		}
	}

	if error_occurred {
		exit(1)
	}
}
