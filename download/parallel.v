// Module: download — parallel file download orchestration.
//
// download_parallel uses V go coroutines and synchronous channels
// (chan) to download multiple files concurrently, mirroring the
// curl_multi integration in pacman/lib/libalpm/dload.c.
//
// Each payload is downloaded by a lightweight go‑coroutine worker.
// A buffered semaphore channel limits concurrency.  The orchestrator
// collects results and calls an optional shared ProgressCallback once
// per completed file.
//
// Reference:
//   pacman/lib/libalpm/dload.c   — curl_download_internal()
//   pacman/lib/libalpm/alpm.h:2288-2300  — parallel_downloads
module download

import net.http
import os
import util

// ===========================================================================
// DownloadPayload
// ===========================================================================

// DownloadPayload describes a single file to download.
//
// At minimum the caller must set url, filename and dest_path.
// If temp_path is left empty the worker writes to dest_path + '.part'
// and renames it atomically on success.
pub struct DownloadPayload {
pub:
	url       string // full remote URL
	filename  string // display / log name
	dest_path string // final local path for the completed file
pub mut:
	temp_path      string // optional partial-download path (default: dest_path + '.part')
	max_size       u64    // size limit in bytes (0 = unlimited)
	force          bool   // download even if dest_path already exists
	allow_resume   bool   // allow resuming partial downloads via Range header
	errors_ok      bool   // if true, download failure is non-fatal for this file
	sig_download   bool   // auto-download accompanion .sig file (url + '.sig')
	sig_optional   bool   // .sig file download is optional (non-fatal failure)
}

// ===========================================================================
// download_parallel
// ===========================================================================

// download_parallel downloads every payload concurrently.
//
// At most max_concurrent downloads run simultaneously (clamped ≥ 1).
// progress_cb is called once per completed file with an overall
// completion percentage (0–100).  Pass unsafe { nil } to skip.
//
// Failures are aggregated into a single util.AceError (.retrieve).
// Payloads with errors_ok=true never cause the overall operation to
// fail; they are silently skipped.
pub fn download_parallel(handle &util.Handle, payloads []DownloadPayload,
	max_concurrent int, progress_cb util.ProgressCallback) ! {
	// --- clamp max_concurrent -----------------------------------------------
	mut n := if max_concurrent < 1 { 1 } else { max_concurrent }
	if n > payloads.len {
		n = if payloads.len > 0 { payloads.len } else { 1 }
	}

	if payloads.len == 0 {
		return
	}

	// --- set up channels ----------------------------------------------------
	sem := chan int{cap: n}       // semaphore: limits concurrent workers
	result_ch := chan DownloadResult{
		cap: payloads.len
	} // buffered for all results

	// --- spawn workers ------------------------------------------------------
	// The sem push blocks when we already have n workers in flight,
	// giving us back-pressure without an explicit dispatch loop.
	for idx, _ in payloads {
		sem <- 1
		go download_worker(payloads[idx], sem, result_ch)
	}

	// --- collect results ----------------------------------------------------
	mut errs := []string{}
	mut completed := 0

	for _ in 0 .. payloads.len {
		res := <-result_ch
		completed++
		if !res.success {
			err_msg := if res.err_msg != '' { res.err_msg } else { 'download failed' }
			errs << '${res.filename}: ${err_msg}'
		}
		if progress_cb != unsafe { nil } {
			pct := int(f32(completed) / f32(payloads.len) * 100.0)
			progress_cb(pct, res.filename)
		}
	}

	if errs.len > 0 {
		return util.AceError{
			code:    .retrieve
			message: 'downloaded ${completed - errs.len}/${payloads.len} files; ' +
				'${errs.len} failure(s) — ${errs[0]}'
		}
	}
}

// ===========================================================================
// internal types / helpers
// ===========================================================================

// DownloadResult is sent from a worker back to the orchestrator.
struct DownloadResult {
	filename string
	success  bool
	err_msg  string
}

// download_worker executes a single download and reports the result.
fn download_worker(payload DownloadPayload, sem chan int,
	result_ch chan DownloadResult) {
	// release the semaphore slot when we finish
	defer {
		_ = <-sem
	}

	// --- short-circuit if the file already exists (and !force) --------------
	if !payload.force && os.exists(payload.dest_path) {
		result_ch <- DownloadResult{
			filename: payload.filename
			success:  true
		}
		return
	}

	// --- determine temporary path -------------------------------------------
	temp_path := if payload.temp_path != '' {
		payload.temp_path
	} else {
		payload.dest_path + '.part'
	}

	// --- HTTP GET -----------------------------------------------------------
	resp := http.get(payload.url) or {
		if !payload.errors_ok {
			result_ch <- DownloadResult{
				filename: payload.filename
				success:  false
				err_msg:  err.msg()
			}
		} else {
			result_ch <- DownloadResult{
				filename: payload.filename
				success:  true
			}
		}
		return
	}

	if resp.status_code != 200 {
		msg := 'HTTP ${resp.status_code}'
		if !payload.errors_ok {
			result_ch <- DownloadResult{
				filename: payload.filename
				success:  false
				err_msg:  msg
			}
		} else {
			result_ch <- DownloadResult{
				filename: payload.filename
				success:  true
			}
		}
		return
	}

	body := resp.body

	// --- enforce max_size ---------------------------------------------------
	if payload.max_size > 0 && u64(body.len) > payload.max_size {
		msg := 'file exceeds ${payload.max_size} byte limit (got ${body.len})'
		if !payload.errors_ok {
			result_ch <- DownloadResult{
				filename: payload.filename
				success:  false
				err_msg:  msg
			}
		} else {
			result_ch <- DownloadResult{
				filename: payload.filename
				success:  true
			}
		}
		return
	}

	// --- write temp file ----------------------------------------------------
	os.write_file(temp_path, body) or {
		if !payload.errors_ok {
			result_ch <- DownloadResult{
				filename: payload.filename
				success:  false
				err_msg:  err.msg()
			}
		} else {
			result_ch <- DownloadResult{
				filename: payload.filename
				success:  true
			}
		}
		return
	}

	// --- atomically rename temp → dest --------------------------------------
	os.mv(temp_path, payload.dest_path) or {
		os.rm(temp_path) or {}
		if !payload.errors_ok {
			result_ch <- DownloadResult{
				filename: payload.filename
				success:  false
				err_msg:  err.msg()
			}
		} else {
			result_ch <- DownloadResult{
				filename: payload.filename
				success:  true
			}
		}
		return
	}

	result_ch <- DownloadResult{
		filename: payload.filename
		success:  true
	}
}
