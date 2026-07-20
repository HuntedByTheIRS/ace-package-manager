module download

// max_server_errors is the number of soft errors allowed before a main server
// is skipped for the remainder of the transaction.  This matches pacman's
// server_error_limit = 3.  Cache servers tolerate any number of soft errors
// and are only skipped after a hard error.
const max_server_errors = 3

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

// ServerState tracks the error state of a single mirror server.
struct ServerState {
	url string // resolved URL (after $repo / $arch substitution)
mut:
	errors int // -1 = permanent hard error; >=0 = soft error count
}

// MirrorList manages ordered failover across cache servers and main servers.
//
// Cache servers are always preferred over main servers.  A server that
// accumulates max_server_errors soft errors, or a single hard error, is
// skipped on subsequent calls to next_url().
//
// Usage:
// ```v
// mut ml := MirrorList{}
// ml.init('core', 'x86_64', cache_urls, [
//     'https://mirror.example.com/\$repo/os/\$arch',
//     'https://backup.example.com/\$repo/os/\$arch',
// ])
//
// for {
//     server := ml.next_url() or { break }
//     if try_download(server) {
//         break // success
//     }
//     ml.mark_failed(false) // soft error — try next server
// }
// ```
pub struct MirrorList {
mut:
	cache_servers []ServerState
	servers       []ServerState
	cache_cursor  int // next index to examine in cache_servers
	server_cursor int // next index to examine in servers
	last_tier     int // 0=cache, 1=server, -1=not set
	last_idx      int // index within the selected tier
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// init populates the MirrorList by substituting $repo and $arch in the
// provided server URL templates.  cache_urls are tried before server_urls.
//
// Both parameters may contain the placeholders $repo (repository name) and
// $arch (architecture), which are replaced with the supplied values.
pub fn (mut ml MirrorList) init(repo_name string, arch string, cache_urls []string, server_urls []string) {
	ml.cache_servers = []ServerState{}
	ml.servers = []ServerState{}
	ml.cache_cursor = 0
	ml.server_cursor = 0
	ml.last_tier = -1
	ml.last_idx = -1

	for raw in cache_urls {
		ml.cache_servers << ServerState{
			url:    substitute_vars(raw, repo_name, arch)
			errors: 0
		}
	}
	for raw in server_urls {
		ml.servers << ServerState{
			url:    substitute_vars(raw, repo_name, arch)
			errors: 0
		}
	}
}

// next_url returns the next available server URL, advancing the internal
// cursor past it.
//
// Cache servers are returned before main servers.  A cache server is skipped
// only on hard error (mark_failed(true)).  A main server is skipped on hard
// error or after max_server_errors soft errors.  Returns none when all
// servers have been exhausted.
pub fn (mut ml MirrorList) next_url() ?string {
	// Cache servers: skip only hard errors (-1).
	for ml.cache_cursor < ml.cache_servers.len {
		s := ml.cache_servers[ml.cache_cursor]
		if s.errors != -1 {
			ml.last_tier = 0
			ml.last_idx = ml.cache_cursor
			ml.cache_cursor++
			return s.url
		}
		ml.cache_cursor++
	}

	// Main servers: skip hard errors (-1) and servers at/above the limit.
	for ml.server_cursor < ml.servers.len {
		s := ml.servers[ml.server_cursor]
		if s.errors != -1 && s.errors < max_server_errors {
			ml.last_tier = 1
			ml.last_idx = ml.server_cursor
			ml.server_cursor++
			return s.url
		}
		ml.server_cursor++
	}

	return none
}

// mark_failed records an error for the most recently returned server.
//
// hard=true  — permanent skip (host resolution failure, bad URL).  The server
//              is skipped for the remainder of the transaction in all tiers.
// hard=false — soft error.  Main servers are skipped after max_server_errors
//              soft errors.  Cache servers are never skipped on soft errors.
pub fn (mut ml MirrorList) mark_failed(hard bool) {
	if ml.last_tier == -1 || ml.last_idx < 0 {
		return
	}
	match ml.last_tier {
		0 {
			if ml.last_idx < ml.cache_servers.len {
				if hard {
					ml.cache_servers[ml.last_idx].errors = -1
				} else if ml.cache_servers[ml.last_idx].errors >= 0 {
					ml.cache_servers[ml.last_idx].errors++
				}
			}
		}
		1 {
			if ml.last_idx < ml.servers.len {
				if hard {
					ml.servers[ml.last_idx].errors = -1
				} else if ml.servers[ml.last_idx].errors >= 0 {
					ml.servers[ml.last_idx].errors++
				}
			}
		}
		else {}
	}
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// substitute_vars replaces $repo and $arch placeholders in a URL string.
fn substitute_vars(url string, repo_name string, arch string) string {
	mut result := url.replace('\$repo', repo_name)
	result = result.replace('\$arch', arch)
	return result
}
