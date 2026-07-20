// Module: download — streaming HTTP download engine.
//
// Provides Downloader with init/download that streams response data
// directly to a temp file, supports resume via Range headers, reports
// progress via a callback, and auto-downloads .sig files.
//
// Reference:
//   pacman/lib/libalpm/dload.c  — curl_add_payload, curl_check_finished_download
//   pacman/lib/libalpm/alpm.h   — alpm_download_event_progress_t
module download

import net.http
import os
import time

// ===========================================================================
// ProgressCallback
// ===========================================================================

// ProgressCallback is called during download with completion percentage
// (0–100, -1 when unknown) and a human-readable message (typically the URL).
pub type ProgressCallback = fn (percent int, message string)

// ===========================================================================
// Downloader
// ===========================================================================

// Downloader performs single-file HTTP downloads with streaming, range-request
// resume, progress reporting, and optional .sig file auto-download.
//
// Usage:
//   mut dl := download.Downloader{}
//   dl.init('Ace/1.0', 30000, fn (pct int, msg string) {
//       println('${pct}% — ${msg}')
//   })
//   dl.download(DownloadPayload{
//       url:       'https://mirror.example.com/pkg.pkg.tar.zst'
//       dest_path: '/var/cache/pacman/pkg/pkg.pkg.tar.zst'
//       allow_resume: true
//       sig_download: true
//       sig_optional: true
//   }) or { eprintln('failed: ${err}') }
//
pub struct Downloader {
mut:
	user_agent string
	timeout    i64 // read timeout in milliseconds
	cb         ProgressCallback = unsafe { nil }
}

// ---------- construction ----------

// init configures the user agent, read timeout (ms, 0 = default 30 s),
// and an optional ProgressCallback (pass unsafe { nil } to skip).
pub fn (mut d Downloader) init(user_agent string, timeout_ms i64, cb ProgressCallback) {
	d.user_agent = user_agent
	d.timeout = if timeout_ms > 0 { timeout_ms } else { 30000 }
	d.cb = cb
}

// ---------- single-file download ----------

// download streams a single file described by payload to disk.
//
// Behaviour (mirroring pacman's dload.c):
//   • Writes to a temporary file first (dest_path + '.part' unless
//     temp_path is set explicitly).
//   • If allow_resume == true and a partial temp file exists, sends a
//     Range header and opens the temp file in append mode.
//   • Calls the ProgressCallback (if set) as chunks arrive.
//   • Renames the temp file to dest_path on success.
//   • Cleans up the temp file on failure (unless allow_resume).
//   • If sig_download is set, auto-downloads url + '.sig' to
//     dest_path + '.sig' after the main file completes.
//
// On success the destination file is closed and moved into place.
// On failure the partial file is removed (unless allow_resume is true,
// which preserves it for a future retry).
pub fn (mut d Downloader) download(payload DownloadPayload) ! {
	// --- resolve temp path --------------------------------------------------
	mut temp_path := payload.temp_path
	if temp_path == '' {
		temp_path = payload.dest_path + '.part'
	}

	// --- resume setup -------------------------------------------------------
	// When allow_resume is set and a partial file exists, we instruct the
	// server to send only the missing bytes via a Range header and open
	// the temp file in append mode.  This mirrors dload.c lines 426–434
	// where CURLOPT_RESUME_FROM_LARGE is used with tempfile_openmode = "ab".
	mut offset := u64(0)
	mut open_mode := 'wb'

	if payload.allow_resume && !payload.force {
		if os.exists(temp_path) {
			st := os.stat(temp_path) or { os.Stat{} }
			if st.size > 0 {
				offset = u64(st.size)
				open_mode = 'ab'
			}
		}
	}

	// --- build HTTP request -------------------------------------------------
	mut req := http.new_request(.get, payload.url, '')
	req.user_agent = d.user_agent
	req.allow_redirect = true
	req.read_timeout = d.timeout * time.millisecond
	// Stream to file via on_progress_body — do not accumulate the entire
	// response body in memory (mirrors curl's CURLOPT_WRITEDATA approach
	// where the callback writes straight to a FILE*).
	req.stop_copying_limit = 0

	if offset > 0 {
		req.add_header(.range, 'bytes=${offset}-')
	}

	// --- open temporary file ------------------------------------------------
	mut f := os.open_file(temp_path, open_mode, 0o644) or {
		return error('failed to open temp file "${temp_path}": ${err.msg()}')
	}

	// --- progress / streaming callback --------------------------------------
	// Capture the callback so the closure does not reach into the receiver.
	cb := d.cb
	mut total_expected := u64(0)
	mut last_reported_pct := -1

	req.on_progress_body = fn [mut f, cb, mut total_expected, mut last_reported_pct, offset] (
		req_ &http.Request,
		chunk []u8,
		read_so_far u64,
		expected u64,
		status_code int,
	) ! {
		// Only stream body data for successful responses (200 / 206).
		// status_code == 0 means headers not yet parsed — skip.
		if status_code != 200 && status_code != 206 && status_code != 0 {
			return
		}

		// Write data chunk straight to the temp file.
		if chunk.len > 0 {
			f.write(chunk) or {
				return error('write to temp file failed: ${err.msg()}')
			}
		}

		// Track the total expected content length.
		if expected > 0 {
			total_expected = expected
		}

		// Report progress if a callback is registered.
		mut pct := -1
		if total_expected > 0 {
			total_bytes := offset + read_so_far
			pct = int(total_bytes * 100 / (offset + total_expected))
		}
		if pct != last_reported_pct && cb != unsafe { nil } {
			last_reported_pct = pct
			cb(pct, '')
		}
	}

	// --- send request and stream response body to file ----------------------
	resp := req.do() or {
		f.close()
		// On failure remove the temp file unless it can be resumed later.
		if !payload.allow_resume {
			os.rm(temp_path) or {}
		}
		return error('HTTP request for "${payload.url}" failed: ${err.msg()}')
	}

	f.close()

	if resp.status_code != 200 && resp.status_code != 206 {
		if !payload.allow_resume {
			os.rm(temp_path) or {}
		}
		return error('HTTP ${resp.status_code} ${resp.status_msg} for "${payload.url}"')
	}

	// If we requested a resume (Range header) but the server ignored it
	// and sent a 200 (full file), our temp file is corrupted: the original
	// partial content plus the full file appended after it.  Re-download
	// from scratch without Range to get a clean copy.
	if resp.status_code == 200 && offset > 0 {
		os.rm(temp_path) or {}
		// Retry without Range — fresh download, write mode.
		mut retry_req := http.new_request(.get, payload.url, '')
		retry_req.user_agent = d.user_agent
		retry_req.allow_redirect = true
		retry_req.read_timeout = d.timeout * time.millisecond
		retry_req.stop_copying_limit = 0

		retry_resp := retry_req.do() or {
			return error('retry download for "${payload.url}" failed: ${err.msg()}')
		}
		if retry_resp.status_code != 200 {
			return error('retry download for "${payload.url}" failed: HTTP ${retry_resp.status_code}')
		}
		os.write_file(temp_path, retry_resp.body) or {
			return error('failed to write retry download: ${err.msg()}')
		}
	}

	// --- atomically rename temp → dest --------------------------------------
	os.mv(temp_path, payload.dest_path) or {
		os.rm(temp_path) or {}
		return error('failed to rename "${temp_path}" → "${payload.dest_path}": ${err.msg()}')
	}

	// --- auto-download .sig if requested ------------------------------------
	if payload.sig_download {
		d.download_sig(payload.dest_path, payload.url, payload.sig_optional) or {
			if !payload.sig_optional {
				return err
			}
		}
	}
}

// ===========================================================================
// signature file download (internal)
// ===========================================================================

// download_sig downloads url + '.sig' to dest + '.sig'.
// When optional is true a download failure is silently ignored.
fn (mut d Downloader) download_sig(dest_path string, url string, optional bool) ! {
	sig_url := url + '.sig'
	sig_dest := dest_path + '.sig'
	sig_temp := sig_dest + '.part'

	mut req := http.new_request(.get, sig_url, '')
	req.user_agent = d.user_agent
	req.allow_redirect = true
	req.read_timeout = d.timeout * time.millisecond
	req.stop_copying_limit = 0

	// --- open sig temp file -------------------------------------------------
	mut f := os.open_file(sig_temp, 'wb', 0o644) or {
		if optional {
			return
		}
		return error('failed to open sig temp file "${sig_temp}": ${err.msg()}')
	}

	// --- streaming callback for sig data ------------------------------------
	req.on_progress_body = fn [mut f] (_ &http.Request, chunk []u8, _ u64, _ u64,
		status_code int,
	) ! {
		if chunk.len > 0 && (status_code == 200 || status_code == 206 || status_code == 0) {
			f.write(chunk) or {
				return error('sig write failed: ${err.msg()}')
			}
		}
	}

	resp := req.do() or {
		f.close()
		os.rm(sig_temp) or {}
		if optional {
			return
		}
		return error('sig download for "${sig_url}" failed: ${err.msg()}')
	}

	f.close()

	if resp.status_code == 200 || resp.status_code == 206 {
		os.mv(sig_temp, sig_dest) or {
			os.rm(sig_temp) or {}
		}
	} else {
		os.rm(sig_temp) or {}
		if !optional {
			return error('sig download returned HTTP ${resp.status_code} for "${sig_url}"')
		}
	}
}
