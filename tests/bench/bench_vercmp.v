// bench_vercmp.v — benchmarks for util.vercmp version comparison.
//
// Usage: v -enable-globals run tests/bench/bench_vercmp.v

import time
import util

const iterations = 100_000

struct BenchCase {
	name string
	a    string
	b    string
}

fn bench_vercmp(cases []BenchCase, label string) {
	start := time.now()
	mut total := 0

	for _ in 0 .. iterations {
		for c in cases {
			total += util.vercmp(c.a, c.b)
		}
	}

	elapsed := time.since(start)
	ms := elapsed.milliseconds()
	println('  ${label}: ${ms:5} ms')
	_ = total
}

fn main() {
	println('=== vercmp benchmarks (${iterations} iterations each) ===')
	println('')

	bench_vercmp([
		BenchCase{'identical', '1.0', '1.0'},
	], 'vercmp/baseline')

	bench_vercmp([
		BenchCase{'epoch >', '2:1.0', '1:9.9.9'},
		BenchCase{'epoch <', '1:9.9.9', '2:1.0'},
		BenchCase{'epoch same', '3:5.0-1', '3:5.0-1'},
		BenchCase{'epoch 0 = none', '0:1.0', '1.0'},
	], 'vercmp/epoch')

	bench_vercmp([
		BenchCase{'simple >', '2.0', '1.0'},
		BenchCase{'simple <', '1.0', '2.0'},
		BenchCase{'pkgrel >', '1.0-2', '1.0-1'},
		BenchCase{'pkgrel <', '1.0-1', '1.0-2'},
		BenchCase{'dotted >', '1.2.3', '1.2.2'},
		BenchCase{'dotted <', '1.2.2', '1.2.3'},
		BenchCase{'alphanum >', '1.0a', '1.0'},
		BenchCase{'alphanum <', '1.0', '1.0a'},
	], 'vercmp/real-world')

	bench_vercmp([
		BenchCase{'tilde <', '1.0~rc1', '1.0'},
		BenchCase{'tilde >', '1.0', '1.0~rc1'},
		BenchCase{'tilde equal', '1.0~rc1', '1.0~rc1'},
		BenchCase{'tilde +ver', '2:1.0~rc1', '2:1.0'},
		BenchCase{'tilde nested', '1.0~rc1~beta', '1.0~rc1'},
	], 'vercmp/tilde')

	bench_vercmp([
		BenchCase{'complex1', '2:1.2.3+r45+gabcdef1-2', '2:1.2.3+r44+gdeadbeef-1'},
		BenchCase{'complex2', '6.0.1-2', '6.0.1-1'},
		BenchCase{'complex3', '2.43+r22+g8362e8ce10b2-4', '2.43+r21+g1234567-3'},
		BenchCase{'complex4', '1.0_alpha', '1.0_beta'},
		BenchCase{'complex5', '2.0.0-1', '2.0.0_rc1-1'},
	], 'vercmp/complex')

	bench_vercmp([
		BenchCase{'epoch large', '999999:1.0', '999998:999.0'},
		BenchCase{'epoch mixed', '5:1.0-1', '4:2.0-1'},
		BenchCase{'epoch edge', '0:0', '0:0'},
		BenchCase{'epoch large-v', '99999:99999-99999', '99999:99998-99999'},
	], 'vercmp/large-epoch')

	println('')
	println('Done.')
}
